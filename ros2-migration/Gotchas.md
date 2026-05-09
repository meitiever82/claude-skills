# Gotchas: ROS1 → ROS2 Migration Pitfalls

> **TL;DR**: This is the most valuable file in this skill. Each gotcha represents a specific
> pattern that has cost real engineers real days. Learn the symptom; learn the fix.

---

## Core Principle

> **Migrate one package at a time, one phase at a time, one node at a time. Compile after every
> meaningful change.** Big-bang migrations always fail and are nearly impossible to bisect.

---

## Gotcha #1: Wrong message header path

### Symptom
```
fatal error: sensor_msgs/Imu.h: No such file or directory
   #include <sensor_msgs/Imu.h>
```

### Cause
ROS1 message headers follow `<pkg/Type.h>` (`<sensor_msgs/Imu.h>`).
ROS2 uses `<pkg/msg/snake_case_type.hpp>` (`<sensor_msgs/msg/imu.hpp>`).

### Fix
Run `helpers/rewrite_headers.sh src/<pkg>` then verify:
```bash
grep -rn '<.*_msgs/[A-Z][a-zA-Z]*\.h>' src/<pkg>          # should be empty
```

### Additional patterns
| ROS1 | ROS2 |
|---|---|
| `<std_msgs/Header.h>` | `<std_msgs/msg/header.hpp>` |
| `<geometry_msgs/Pose.h>` | `<geometry_msgs/msg/pose.hpp>` |
| `<my_pkg/AddTwoInts.h>` (service) | `<my_pkg/srv/add_two_ints.hpp>` |
| `<my_pkg/FooAction.h>` (action) | `<my_pkg/action/foo.hpp>` |

**Note**: snake_case conversion is **CamelCase → snake_case**. `MultiArrayDimension` → `multi_array_dimension`.

---

## Gotcha #2: Forgetting `::msg::` namespace

### Symptom
```cpp
sensor_msgs::Imu msg;
//             ^^^ error: 'Imu' is not a member of 'sensor_msgs'
```

### Cause
Including `<sensor_msgs/msg/imu.hpp>` declares `sensor_msgs::msg::Imu`, not `sensor_msgs::Imu`.

### Fix
```cpp
sensor_msgs::msg::Imu msg;
```

For services and actions: `pkg::srv::Type`, `pkg::action::Type`. The same applies to
`Request`/`Response`/`Goal`/`Result`/`Feedback` subtypes.

### Quick check
```bash
grep -rE '\b(std_msgs|sensor_msgs|geometry_msgs|nav_msgs)::[A-Z]' src/ | grep -v '::msg::'
```
Any hit not on a comment is suspect.

---

## Gotcha #3: `n.param<T>` vs `declare_parameter` semantics

### Symptom
- Parameter always reads its default value, never the one you set in YAML.
- `RuntimeError: parameter 'foo' has not been declared`.

### Cause
ROS2 requires every parameter to be **declared** before it can be **gotten** or set
(unless `automatically_declare_parameters_from_overrides` is enabled, which we discourage).

### Fix
```cpp
// ROS1
double cov;
n.param<double>("Odometry/cov_gyr", cov, 0.1);

// ROS2 - declare exactly once (idiomatically in the constructor)
this->declare_parameter<double>("Odometry.cov_gyr", 0.1);
double cov = this->get_parameter("Odometry.cov_gyr").as_double();
```

### Subtle traps
1. **Path separator**. ROS2 uses `.` for nested params, not `/`. The parameter name `"a/b"` is
   a literal name with a slash, not a hierarchy.
2. **Type pinning**. `declare_parameter<int>("x", 1)` makes `x` an integer forever; trying to set
   it to `1.0` from YAML will be rejected. Match types carefully.
3. **`std::string` vs `const char*`**. `declare_parameter("name", "/livox/imu")` may instantiate
   the wrong overload. Use `declare_parameter<std::string>("name", "/livox/imu")`.

---

## Gotcha #4: QoS mismatch — pub and sub never connect

### Symptom
- `ros2 topic list` shows the topic.
- `ros2 topic echo` from a separate terminal works.
- But your subscriber never receives a message.

### Cause
DDS QoS mismatch. Common cases:
- Publisher uses **best-effort**, subscriber uses **reliable** → no match.
- Publisher uses **transient_local**, subscriber uses **volatile** → match, but if you missed
  the first message, you never get it.

### Fix
```cpp
// Match QoS profiles between pub and sub
auto qos = rclcpp::SensorDataQoS();           // best-effort, depth 5
auto pub = create_publisher<sensor_msgs::msg::Imu>("imu", qos);
auto sub = create_subscription<sensor_msgs::msg::Imu>("imu", qos, cb);
```

### Quick check
```bash
ros2 topic info /imu/data --verbose          # shows QoS of every endpoint
```

### Default mapping for ROS1 mental model
| ROS1 transport | ROS2 QoS |
|---|---|
| TCP, queue=1 | `rclcpp::QoS(1)` (reliable, volatile) |
| TCP, queue=100 | `rclcpp::QoS(100)` |
| UDP / "best effort" | `rclcpp::SensorDataQoS()` |
| Latched (`latch=true`) | `rclcpp::QoS(1).transient_local()` |

---

## Gotcha #5: Latched topics don't replay automatically

### Symptom
You set `latched=true` in ROS1 and clients always got the last value on connect. In ROS2 you
configured `transient_local`, but new subscribers still see nothing.

### Cause
**Both publisher and subscriber must use transient_local.** A `volatile` subscriber will not
receive the cached message even from a `transient_local` publisher.

### Fix
```cpp
auto qos = rclcpp::QoS(1).transient_local().reliable();
auto pub = create_publisher<...>("/static_map", qos);
// On the consumer side:
auto sub = create_subscription<...>("/static_map", qos, cb);
```

---

## Gotcha #6: `tf::*` types do not convert silently

### Symptom
```cpp
tf::Quaternion q;
geometry_msgs::msg::Quaternion m;
m = q;                                  // error: no conversion
```

### Cause
ROS2 deprecated `tf` (the ROS1 wrapper). All transforms go through `tf2::*` types, and
`tf2::*` ↔ `geometry_msgs::msg::*` conversion uses dedicated headers.

### Fix
```cpp
#include <tf2/LinearMath/Quaternion.h>
#include <tf2_geometry_msgs/tf2_geometry_msgs.hpp>

tf2::Quaternion q;
geometry_msgs::msg::Quaternion m = tf2::toMsg(q);
tf2::fromMsg(m, q);                       // round-trip
```

For `Eigen` ↔ `tf2`: `#include <tf2_eigen/tf2_eigen.hpp>`.

---

## Gotcha #7: `tf::TransformBroadcaster` constructor signature changed

### Symptom
```cpp
tf2_ros::TransformBroadcaster br;
//                            ^ error: no default constructor
```

### Cause
ROS2's `tf2_ros::TransformBroadcaster` requires a `Node` to bind to (so it can create a
publisher on `/tf`).

### Fix
```cpp
class MyNode : public rclcpp::Node {
  tf2_ros::TransformBroadcaster br_{*this};       // member init list
  // OR
  std::shared_ptr<tf2_ros::TransformBroadcaster> br2_;
public:
  MyNode() : Node("my_node") {
    br2_ = std::make_shared<tf2_ros::TransformBroadcaster>(this);
  }
};
```

For static transforms use `tf2_ros::StaticTransformBroadcaster`.

---

## Gotcha #8: `ros::Time::now()` from a free function

### Symptom
```cpp
double t = ros::Time::now().toSec();
//         ^^^^^^^^^^^^^^^ no longer exists
```

### Cause
`ros::Time::now()` in ROS1 used a global clock. In ROS2 there is no global clock by
design — each Node owns its clock so simulation time can be applied per-node.

### Fix
```cpp
// Inside a Node method:
auto t = this->now();                          // rclcpp::Time
double tsec = t.seconds();

// In a free function, accept a clock or node ref:
double get_now(rclcpp::Clock & c) { return c.now().seconds(); }
```

If you really need a wall clock, `rclcpp::Clock(RCL_SYSTEM_TIME).now()` is the equivalent of
`std::chrono::system_clock::now()`. Use sparingly — it ignores `/clock`.

---

## Gotcha #9: `pcl_ros::transformPointCloud` is gone

### Symptom
```
error: ‘pcl_ros’ has not been declared
```

### Cause
`pcl_ros` exists in some ROS2 distros (Humble has it via `perception_pcl` overlay) but the
namespace and header layout are different.

### Fix
For most cases, prefer `pcl::transformPointCloud` directly with an `Eigen::Affine3f`:

```cpp
#include <pcl_conversions/pcl_conversions.h>
#include <pcl/common/transforms.h>

Eigen::Affine3f T = ...;                     // from tf2_eigen or your own state
pcl::PointCloud<pcl::PointXYZ> out;
pcl::transformPointCloud(in, out, T);
```

For `sensor_msgs::msg::PointCloud2` ↔ `pcl::PointCloud<T>`, `pcl_conversions::moveFromROSMsg`
and `pcl::toROSMsg` still work as in ROS1.

---

## Gotcha #10: `nodelet` → component, but the API is different

### Symptom
You ported a nodelet by renaming `Nodelet::onInit` to a constructor body — and it crashes on
load, or never loads.

### Cause
Nodelets use `pluginlib`, components use `class_loader` registration via
`RCLCPP_COMPONENTS_REGISTER_NODE`. The "load into a node container" is also different.

### Fix
1. Convert the nodelet to a `rclcpp::Node` subclass.
2. Add `RCLCPP_COMPONENTS_REGISTER_NODE(my_pkg::MyComponent)` at the end of the .cpp.
3. In `CMakeLists.txt`:
   ```cmake
   add_library(my_component SHARED src/my_component.cpp)
   ament_target_dependencies(my_component rclcpp rclcpp_components ...)
   rclcpp_components_register_nodes(my_component "my_pkg::MyComponent")
   install(TARGETS my_component
           ARCHIVE DESTINATION lib
           LIBRARY DESTINATION lib
           RUNTIME DESTINATION bin)
   ```
4. Load via `ros2 component load /component_container my_pkg my_pkg::MyComponent`.

---

## Gotcha #11: `dynamic_reconfigure` has no direct replacement

### Symptom
You search for `dynamic_reconfigure` in ROS2. There is no port.

### Cause
ROS2 unified runtime parameter changes via `rcl_interfaces/srv/SetParameters` plus the
`add_on_set_parameters_callback()` hook on the node.

### Fix
```cpp
auto cb = node->add_on_set_parameters_callback(
  [this](const std::vector<rclcpp::Parameter> & params) {
    rcl_interfaces::msg::SetParametersResult result;
    result.successful = true;
    for (const auto & p : params) {
      if (p.get_name() == "Odometry.cov_gyr") {
        cov_gyr_ = p.as_double();
      }
    }
    return result;
});
```

Then `ros2 param set /my_node Odometry.cov_gyr 0.5` triggers the callback.

For a GUI tool: `rqt_reconfigure` works in ROS2 against any node that uses `declare_parameter`.

---

## Gotcha #12: `actionlib` → `rclcpp_action` is a rewrite, not a rename

### Symptom
You replace `actionlib::SimpleActionClient` with `rclcpp_action::Client` and the call
syntax doesn't compile.

### Cause
`actionlib` had a synchronous `sendGoalAndWait()`-style API; `rclcpp_action` is
fully asynchronous via `std::future`.

### Fix outline
```cpp
auto ac = rclcpp_action::create_client<my_pkg::action::Foo>(node, "foo");
if (!ac->wait_for_action_server(2s)) { ... }

my_pkg::action::Foo::Goal goal;
goal.target = 42;

auto opts = rclcpp_action::Client<my_pkg::action::Foo>::SendGoalOptions();
opts.feedback_callback = [](auto, auto fb){ /* ... */ };
opts.result_callback   = [](auto result){ /* ... */ };
auto goal_future = ac->async_send_goal(goal, opts);
```

The server side is similarly different — see `rclcpp_action` examples in
`humble/Tutorials/Actions/`.

---

## Gotcha #13: Build silently picks up the wrong `setup.bash`

### Symptom
`colcon build` succeeds but you get linker errors against ROS1 libs, or vice versa.

### Cause
You sourced both `/opt/ros/noetic/setup.bash` and `/opt/ros/humble/setup.bash` in the same
shell. CMake then resolves the **first** match on `CMAKE_PREFIX_PATH`, which can be either.

### Fix
Open a fresh terminal. Source **only** Humble:
```bash
source /opt/ros/humble/setup.bash
echo $CMAKE_PREFIX_PATH        # should not contain /opt/ros/noetic
```

If you must keep both available, isolate workspaces:
```bash
# in ~/.bashrc
ros1_env() { source /opt/ros/noetic/setup.bash; }
ros2_env() { source /opt/ros/humble/setup.bash; }
```

---

## Gotcha #14: `colcon build` uses a different output layout

### Symptom
You expect `devel/lib/<pkg>/<exe>` (catkin layout). `colcon` puts it in
`install/<pkg>/lib/<pkg>/<exe>`.

### Cause
By design. Use `ros2 run <pkg> <exe>` to find executables; do not invoke the binary directly.

### Fix
- After every build, source the workspace overlay:
  ```bash
  source install/setup.bash
  ```
- Use `--symlink-install` during development to avoid re-installing on every code change:
  ```bash
  colcon build --symlink-install
  ```
- The `build/` directory in colcon is per-package; there is no global `build/` like catkin.

---

## Gotcha #15: Forgetting to `install(DIRECTORY launch …)`

### Symptom
```
file 'launch/foo.launch.py' was not found
```
Your launch file exists in source but `ros2 launch` cannot find it.

### Cause
`colcon` only ships what `install(...)` rules reference.

### Fix
In `CMakeLists.txt` (before `ament_package()`):
```cmake
install(DIRECTORY launch config rviz urdf
        DESTINATION share/${PROJECT_NAME})
```

Re-run `colcon build`. Verify:
```bash
ls install/<pkg>/share/<pkg>/launch/
```

---

## Gotcha #16: Parameter file YAML node name must match exactly

### Symptom
You launch with `Node(name='odom', ...)` and pass a YAML, but parameters are not applied.

### Cause
ROS2 YAML keys are scoped by the **node name** as launched, not the executable name:
```yaml
odom:                          # must match name='odom'
  ros__parameters:
    cov_gyr: 0.1
```

If you launch with `name='foo'`, the YAML key must be `foo:`.

### Fix
- Either fix the YAML key to match the launch `name=`, or
- Use the wildcard form (Humble+):
  ```yaml
  /**:
    ros__parameters:
      cov_gyr: 0.1
  ```

---

## Gotcha #17: `ros2 launch` swallows error logs

### Symptom
A node crashes during launch but you only see `[component_container-1] process has died`.

### Cause
`ros2 launch` aggregates stdout/stderr. If the node prints before its logger is initialised,
or if `RCLCPP_INFO` is at debug level, the logs are lost.

### Fix
- Use `output='screen'` on the `Node(...)` action to forward to console.
- Run the node directly while debugging: `ros2 run <pkg> <exe> --ros-args -p <param>:=<value>`.
- Capture full logs: `ros2 launch <pkg> <name>.launch.py 2>&1 | tee /tmp/launch.log`.

---

## Gotcha #18: Time messages and headers expect different fields

### Symptom
```cpp
sensor_msgs::msg::Imu msg;
msg.header.stamp = ros::Time::now();          // error
```

### Cause
`std_msgs::msg::Header::stamp` is a `builtin_interfaces::msg::Time`, not `ros::Time`.

### Fix
```cpp
msg.header.stamp = node->now();                // rclcpp::Time auto-converts
// Or explicitly:
msg.header.stamp = rclcpp::Time(now_sec, now_nsec).operator builtin_interfaces::msg::Time();
```

`rclcpp::Time` has implicit conversion to `builtin_interfaces::msg::Time` when assigned.

---

## Gotcha #19: `boost::shared_ptr` vs `std::shared_ptr`

### Symptom
```cpp
void cb(const sensor_msgs::msg::Imu::ConstPtr & msg);   // error: no such typedef
```

### Cause
ROS2 uses `std::shared_ptr` exclusively. The ROS1 `boost::shared_ptr` typedefs (`::ConstPtr`,
`::Ptr`) are gone.

### Fix
```cpp
void cb(const sensor_msgs::msg::Imu::ConstSharedPtr msg);
// or
void cb(sensor_msgs::msg::Imu::SharedPtr msg);
```

For raw const-ref subscriptions:
```cpp
void cb(const sensor_msgs::msg::Imu & msg);             // also works in Humble+
```

---

## Gotcha #20: Spinning a node twice causes UB

### Symptom
```cpp
rclcpp::spin(node);
rclcpp::spin_some(node);                  // crashes
```

### Cause
Once `rclcpp::spin` exits, the executor has been destroyed. You cannot reuse the node with a
new `spin*` call without re-adding it.

### Fix
For single-thread:
```cpp
auto node = std::make_shared<MyNode>();
rclcpp::spin(node);                       // blocks until shutdown
rclcpp::shutdown();
```

For repeated spinning (event-loop style, like ROS1's `spinOnce`):
```cpp
rclcpp::executors::SingleThreadedExecutor exec;
exec.add_node(node);
while (rclcpp::ok()) {
  exec.spin_some(std::chrono::milliseconds(10));
  // do work
}
```

---

## Gotcha #21: Multi-threaded executor + non-reentrant callbacks = data race

### Symptom
Random crashes inside a callback that doesn't appear thread-unsafe to a ROS1 reader.

### Cause
`MultiThreadedExecutor` runs callbacks concurrently across threads. ROS1's
`AsyncSpinner(N)` does the same, but in many ROS1 codebases the model was actually
"single-threaded with explicit `ros::spinOnce()`" and developers assumed serial execution.

### Fix
- Default to `SingleThreadedExecutor` unless you have a specific reason.
- If you need parallelism, group callbacks with `CallbackGroupType::MutuallyExclusive`:
  ```cpp
  auto cbg = create_callback_group(rclcpp::CallbackGroupType::MutuallyExclusive);
  ```
- Use `Reentrant` only for callbacks you have audited for thread-safety.

---

## Gotcha #22: rosbag1 `*.bag` files don't play in ROS2 directly

### Symptom
```
ros2 bag play in.bag
[error] could not open storage 'in.bag' with sqlite3 plugin
```

### Cause
ROS2's `rosbag2` uses sqlite3 (or MCAP) by default; `.bag` files are ROS1's binary format.

### Fix
```bash
# Option 1: rosbags-convert (Python tool)
pip install rosbags
rosbags-convert in.bag                 # produces in/ directory

# Option 2: ros2 bag convert (Humble has limited support)
ros2 bag convert -i in.bag -o out --output-storage-id sqlite3
```

For replay testing during migration, this is the single biggest practical hurdle.

---

## Gotcha #23: `pluginlib` macro arguments swap order

### Symptom
Your plugin loads under ROS1 but `ClassLoader` cannot find it in ROS2.

### Cause
The macro is the same name (`PLUGINLIB_EXPORT_CLASS`), but the package path conventions and
plugin XML schemas differ.

### Fix
1. The C++ side is usually unchanged:
   ```cpp
   PLUGINLIB_EXPORT_CLASS(my_pkg::MyPlugin, base_pkg::BaseClass)
   ```
2. The plugin XML must reference the **library name** as built in ROS2:
   ```xml
   <library path="my_pkg_plugin">
     <class name="my_pkg/MyPlugin"
            type="my_pkg::MyPlugin"
            base_class_type="base_pkg::BaseClass">
       <description>...</description>
     </class>
   </library>
   ```
   Path: `path="my_pkg_plugin"` (no `lib` prefix, no `.so` suffix; just the library target name).
3. In `CMakeLists.txt`:
   ```cmake
   pluginlib_export_plugin_description_file(base_pkg plugin.xml)
   ```
4. In `package.xml`:
   ```xml
   <export>
     <build_type>ament_cmake</build_type>
     <base_pkg plugin="${prefix}/plugin.xml"/>
   </export>
   ```

---

## Gotcha #24: RViz1 plugins do not work in RViz2

### Symptom
You move an RViz plugin (`my_plugin`) and it builds, but does not appear in RViz2's
"Add Display" dialog.

### Cause
RViz2 has a substantially different plugin API:
- Different base class (`rviz_common::Display` vs `rviz::Display`).
- Different property system (`rviz_common::properties::Property`, etc.).
- Different OGRE handling.

### Fix
**This is a rewrite, not a port.** Plan for it explicitly in the migration plan.
Reference: [rviz_default_plugins source](https://github.com/ros2/rviz/tree/humble/rviz_default_plugins/src).

For the Voxel-SLAM `VoxelSLAMPointCloud2` plugin specifically: budget at least a day to
re-implement against `rviz_common::Display` with `PointCloud2` topic property, properly
clear behaviour on disable, and OGRE scene management.

---

## Gotcha #25: `ros::package::getPath` → `ament_index_cpp`

### Symptom
```cpp
std::string p = ros::package::getPath("my_pkg");        // not found
```

### Cause
`ros/package.h` is gone. ROS2 uses the ament index.

### Fix
```cpp
#include <ament_index_cpp/get_package_share_directory.hpp>
std::string p = ament_index_cpp::get_package_share_directory("my_pkg");
```

In `CMakeLists.txt` add `find_package(ament_index_cpp REQUIRED)` and link with
`ament_target_dependencies(... ament_index_cpp)`.

**Note**: this returns the *share* directory, not the full source path. If you used
`getPath` to find configs, your YAML/launch file will live under
`share/<pkg>/config/...` after `colcon build` — adjust accordingly.

---

## Gotcha #26: Forgetting `rclcpp::shutdown()`

### Symptom
A test or CLI run hangs at exit; or "fastrtps participant cleanup" errors in logs.

### Cause
`rclcpp::init()` registers a global participant. Without `rclcpp::shutdown()`, the
participant lingers, sometimes preventing process exit.

### Fix
Always:
```cpp
int main(int argc, char ** argv) {
  rclcpp::init(argc, argv);
  rclcpp::spin(node);
  rclcpp::shutdown();
  return 0;
}
```

For exception-safe code, wrap with a scope guard or use `rclcpp::contexts::default_context_t`
explicitly.

---

## Gotcha #27: Implicit time-source change between ROS1 and ROS2

### Symptom
A node that worked fine on ROS1 + `rosbag --clock` deadlocks on ROS2 + `ros2 bag play --clock`.

### Cause
ROS2 nodes default to **system time**. If `/clock` is being published, you must opt-in:
```cpp
this->declare_parameter<bool>("use_sim_time", false);
```
Or pass `-r use_sim_time:=true` on the command line / set in launch.

### Fix
Set in launch:
```python
Node(package='my_pkg', executable='my_node',
     parameters=[{'use_sim_time': True}, ...])
```

---

## Gotcha #28: Including a `_INSTANCE_PER_THREAD_INIT` for OpenMP

### Symptom
Random Eigen / PCL crashes after migrating, especially under `MultiThreadedExecutor`.

### Cause
Eigen has thread-local state (e.g. `Eigen::initParallel`) that ROS1's main-thread-only
spinning hid by accident. ROS2's executor exposes this.

### Fix
Call `Eigen::initParallel();` once at the top of `main()`. For `omp_set_num_threads`, set
explicitly (don't rely on `OMP_NUM_THREADS`).

---

## Gotcha #29: `message_filters` API drift

### Symptom
```cpp
message_filters::Subscriber<sensor_msgs::Imu> sub(nh, "imu", 100);
//                                                   ^^ no NodeHandle
```

### Cause
`message_filters` API in ROS2 takes a `Node` pointer (not a `NodeHandle`) and uses
`std::shared_ptr` everywhere.

### Fix
```cpp
#include <message_filters/subscriber.h>
#include <message_filters/synchronizer.h>
#include <message_filters/sync_policies/approximate_time.h>

message_filters::Subscriber<sensor_msgs::msg::Imu>       imu_sub(this, "imu");
message_filters::Subscriber<sensor_msgs::msg::PointCloud2> pcl_sub(this, "lidar");
typedef message_filters::sync_policies::ApproximateTime<
    sensor_msgs::msg::Imu, sensor_msgs::msg::PointCloud2> SyncPolicy;
message_filters::Synchronizer<SyncPolicy> sync(SyncPolicy(10), imu_sub, pcl_sub);
sync.registerCallback(&MyNode::cb, this);
```

Note `(this, "topic")` instead of `(nh, "topic", 100)`.

---

## Gotcha #30: `colcon build` fails on the **second** run only

### Symptom
First clean build succeeds. The next run fails with a stale-cache error from CMake.

### Cause
Some packages don't re-run `find_package` properly when a sourced overlay changes. Most
common: you sourced `install/setup.bash` after building, then re-ran `colcon build`, and CMake
now sees the workspace's own install dir on `CMAKE_PREFIX_PATH` and gets confused.

### Fix
1. Don't source `install/setup.bash` before building.
2. If you must: `colcon build --cmake-clean-cache` to wipe stale caches.
3. As a last resort: `rm -rf build install log` and start fresh.

---

## Gotcha #31: A repo named `*_ROS2` may be half-ported

### Symptom
You clone `<project>_ROS2`, run `colcon build`, and get hundreds of errors:
```
error: 'ros' has not been declared
error: 'NodeHandle' is not a member of 'rclcpp'
fatal error: nav_msgs/Odometry.h: No such file or directory
```
even though the repo is described as a ROS2 port.

### Cause
Many community "ROS2 forks" only translated **header include paths** (e.g.
`<sensor_msgs/Imu.h>` → `<sensor_msgs/msg/imu.hpp>`) and updated `package.xml`
to use `ament_cmake`. The actual API code (`ros::NodeHandle`, `ros::Publisher`,
`ros::Subscriber`, `ros::Timer`, `ros::Time`, `ros::Rate`, `image_transport`,
`livox_ros_driver`, `tf::TransformBroadcaster`, `ROS_INFO/ERROR`, …) is still
ROS1.

### Detection — do this FIRST, before estimating effort
```bash
# Count ROS1-only patterns; expect ~0 for a true ROS2 port.
grep -rE "ros::|nh\.advertise|nh\.subscribe|nh\.createTimer|nh\.param|ros::Time::now|ros::Rate|ros::ok|::ConstPtr|tf::TransformBroadcaster|ROS_(INFO|WARN|ERROR|ASSERT)" \
    src/<repo>/{src,include} | wc -l

grep -rE "ros::NodeHandle" src/<repo>/{src,include}        # critical signal: any hit ⇒ heavy port
```

### Fix
- A genuine ROS2 port reads `0` (or only comments) on the grep above.
- Real-world FAST-LIVO2_ROS2 (Vulcan-YJX fork, May 2026): ~119 hits in the
  main file alone — the headers were swapped but the code wasn't.
- **Budget realistically**: 1-3 hours per ~1k LoC of ROS-touching seam.

### Decision tree
```
grep count = 0   → port is real, build issues are likely env/dep problems.
grep count < 50  → light cleanup; do it inline.
grep count > 100 → significant rewrite; ask the user before starting.
```

The `examples/fast-livo2-migration.md` walkthrough is the canonical case.

---

## Gotcha #32: Sophus 1.22 — `SE3` is now a template, not a typedef

### Symptom
```cpp
Sophus::SE3 T;
//          ^^^ error: invalid use of template-name 'Sophus::SE3' without an argument list
```
or `error: 'using SE3 = ...' has no member named 'rotation_matrix'`.

### Cause
- Old (pre-1.0) Sophus: `Sophus::SE3` was a `typedef` to `SE3<double>`.
- Sophus 1.x (shipped with `ros-humble-sophus`): `template<class Scalar_, int Options> class SE3;`.

So `Sophus::SE3` without an argument list no longer names a type. Plus several
methods were renamed (camel-case migration):

| Old (pre-1.0) | New (1.x) |
|---|---|
| `Sophus::SE3` | `Sophus::SE3<double>` aka `Sophus::SE3d` |
| `T.rotation_matrix()` | `T.rotationMatrix()` |
| `<sophus/se3.h>` | `<sophus/se3.hpp>` |

### Fix
Two complementary changes in any file that uses unqualified `SE3`:

```cpp
// In your common header:
#include <sophus/se3.hpp>
// using namespace Sophus;                      // DO NOT — see Gotcha #33
using SE3 = Sophus::SE3d;                       // legacy short name
```

Then replace `T.rotation_matrix()` with `T.rotationMatrix()` everywhere
(`sed -i 's/\.rotation_matrix()/\.rotationMatrix()/g' src/**/*.{cpp,h}`).

### Why this comes up in ROS2 migration
ROS1 codebases pinned to old Sophus via `apt install ros-noetic-sophus` or
the `strasdat/Sophus` 0.9 release. Humble's `ros-humble-sophus` is 1.22.
Migrations get bitten as soon as the system Sophus is the only one available.

---

## Gotcha #33: `using namespace Sophus;` clashes with `using namespace Eigen;`

### Symptom
```cpp
using namespace Eigen;
using namespace Sophus;
// later …
Matrix<double, 3, 1> v;
//      ^^^^^^ error: reference to 'Matrix' is ambiguous
//             candidates: Eigen::Matrix<...>  or  Sophus::Matrix<...>
```
Or more cryptically:
```cpp
template <typename T>
auto fn(const Matrix<T,3,1> &a, ...) { ... a(i) ... }
//        ^^^^^^ ambiguous → entire signature fails to parse
//                ↓
// error: there are no arguments to 'a' that depend on a template parameter
```

### Cause
Sophus 1.22 ships `template <class Scalar, int M, int N> using Matrix = Eigen::Matrix<...>;`
in `sophus/types.hpp`. Both namespaces export `Matrix` ⇒ ambiguous.

The cryptic second error happens because the compiler fails to parse the
function signature (ambiguous `Matrix`), so all arguments lose their names —
later `a(i)` references an undeclared identifier.

### Fix
Drop `using namespace Sophus`. Pull in only what you need:

```cpp
#include <sophus/se3.hpp>
using namespace std;
using namespace Eigen;
// using namespace Sophus;            // ⚠️ DO NOT
using SE3 = Sophus::SE3d;             // explicit short alias
using SO3 = Sophus::SO3d;             // if you need it
```

If you *must* keep both `using namespace`s (legacy code), fully qualify
`Eigen::Matrix<...>` everywhere.

---

## Gotcha #34: `vikit_common` / `vikit_ros` and similar satellite libraries are catkin-only

### Symptom
You're porting FAST-LIVO2, SVO, or DSO and the build immediately complains:
```
fatal error: vikit/abstract_camera.h: No such file or directory
fatal error: vikit/camera_loader.h:    No such file or directory
```
The author's repo for vikit (xuankuzcr, Taeyoung96, uzh-rpg) is still ROS1 catkin.

### Cause
Many vision/SLAM libraries depend on a small "common math" sidecar (`rpg_vikit`,
`svo_common`, `direct_visual_lidar_calibration`/internal Kontiki, …). These
libraries:
- Have `catkin` in their `package.xml` and an old `CMakeLists.txt`.
- Provide pure C++ utilities (Eigen, OpenCV, Sophus) — **no actual ROS code**
  in the algorithm modules.
- Have one ROS-touching helper file (e.g. `vikit_ros/output_helper.cpp` uses
  `tf::Transform` and `ros::Publisher`).

### Fix — port the satellite library yourself, not the algorithm
The mechanical recipe (proven on `rpg_vikit` for FAST-LIVO2_ROS2):

1. **Rewrite `package.xml`** to format=3 + `<buildtool_depend>ament_cmake</buildtool_depend>`.
2. **Rewrite `CMakeLists.txt`** as a plain ament shared library — drop `catkin_package(...)`.
   ```cmake
   find_package(ament_cmake REQUIRED)
   find_package(Eigen3 REQUIRED)
   find_package(OpenCV REQUIRED)
   find_package(Sophus REQUIRED)
   add_library(${PROJECT_NAME} SHARED ${SOURCEFILES})
   target_include_directories(${PROJECT_NAME} PUBLIC
     $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
     $<INSTALL_INTERFACE:include>)
   target_link_libraries(${PROJECT_NAME} ${OpenCV_LIBS} Sophus::Sophus)
   install(DIRECTORY include/ DESTINATION include)
   install(TARGETS ${PROJECT_NAME}
     EXPORT export_${PROJECT_NAME}
     ARCHIVE DESTINATION lib LIBRARY DESTINATION lib RUNTIME DESTINATION bin)
   ament_export_targets(export_${PROJECT_NAME} HAS_LIBRARY_TARGET)
   ament_export_dependencies(Eigen3 OpenCV Sophus)
   ament_package()
   ```
3. **Drop ROS1-only source files from the build list** if your downstream
   doesn't use them (e.g. `vikit_ros/src/output_helper.cpp` references
   `tf::*`/`ros::Publisher` — exclude it from `add_library` until / unless
   you need it). The headers can stay; what matters is that compiled
   translation units don't pull in ROS1 APIs.
4. **Re-implement the one ROS helper your downstream needs**. For
   `vikit_ros/camera_loader.h::loadFromRosNs`, change the signature to take
   `rclcpp::Node*` and read parameters via `node->declare_parameter<T>` /
   `get_parameter`.

For FAST-LIVO2_ROS2 specifically the fully-worked recipe lives in
`examples/fast-livo2-migration.md` §"vikit port".

---

## Gotcha #35: Old vikit `AbstractCamera` is missing `fx()/fy()/cx()/cy()/scale()`

### Symptom
After porting `vikit_common` to ament_cmake, the downstream still fails:
```
error: 'class vk::AbstractCamera' has no member named 'fx'
error: 'class vk::AbstractCamera' has no member named 'scale'
```

### Cause
FAST-LIVO2 uses a **customised** `vk::AbstractCamera` with virtual `fx()`, `fy()`,
`cx()`, `cy()`, `scale()` accessors so the algorithm can read intrinsics from
the abstract base. The upstream `rpg_vikit` only puts these on `PinholeCamera`.

### Fix
Add the FAST-LIVO2 extension yourself in `abstract_camera.h`:

```cpp
class AbstractCamera {
  // ...
  virtual double fx() const { return 0.0; }
  virtual double fy() const { return 0.0; }
  virtual double cx() const { return 0.0; }
  virtual double cy() const { return 0.0; }
  virtual double scale() const { return 1.0; }
};
```

In `PinholeCamera` mark the existing accessors `override` and add a `scale_`
member + `setScale()` setter. Have `camera_loader::loadFromRosNs` read the
`scale` parameter and call `setScale()` after construction.

This is FAST-LIVO2 / direct-VIO specific, but the same pattern (downstream
expects extra virtuals) recurs whenever you port a satellite lib that's been
patched in-place by the upstream project.

---

## Gotcha #36: `ROS_ASSERT` is gone

### Symptom
```cpp
ROS_ASSERT(ptr != nullptr);
//   ^^^^^^^^^^ error: 'ROS_ASSERT' was not declared in this scope; did you mean 'FMT_ASSERT'?
```

### Cause
ROS1's `ROS_ASSERT` macro lived in `<ros/assert.h>`. ROS2 removed it — the
preferred form is plain `assert()` (or your own logger-coupled abort).

### Fix
```cpp
#include <cassert>
assert(ptr != nullptr);
```

If you want the assertion to log via the ROS2 logger before aborting:

```cpp
if (!(ptr != nullptr)) {
  RCLCPP_FATAL(this->get_logger(), "assertion failed: ptr != nullptr");
  std::abort();
}
```

Bulk-replace recipe:
```bash
sed -i 's/\bROS_ASSERT(/assert(/g' src/**/*.cpp
```

---

## Gotcha #37: `tf::createQuaternionMsgFromRollPitchYaw` removed

### Symptom
```cpp
geoQuat = tf::createQuaternionMsgFromRollPitchYaw(roll, pitch, yaw);
//        ^^ error: 'tf' has not been declared
```

### Cause
The ROS1 `tf` (singular, not `tf2`) free-function helpers are gone. ROS2 routes
all rotation conversions through `tf2::Quaternion` + `tf2::toMsg`.

### Fix
```cpp
#include <tf2/LinearMath/Quaternion.h>
#include <tf2_geometry_msgs/tf2_geometry_msgs.hpp>

tf2::Quaternion q;
q.setRPY(roll, pitch, yaw);
geometry_msgs::msg::Quaternion geoQuat = tf2::toMsg(q);
// or assign component-wise if the destination is a struct field:
// geoQuat.x = q.x(); geoQuat.y = q.y(); geoQuat.z = q.z(); geoQuat.w = q.w();
```

Other RPG/FAST-LIVO-style helpers and their replacements:

| ROS1 (gone) | ROS2 |
|---|---|
| `tf::createQuaternionMsgFromYaw(yaw)` | `tf2::Quaternion q; q.setRPY(0,0,yaw); tf2::toMsg(q)` |
| `tf::Quaternion(...)` | `tf2::Quaternion(...)` |
| `tf::Vector3(x,y,z)` | `tf2::Vector3(x,y,z)` |
| `tf::Transform`/`tf::StampedTransform` | `geometry_msgs::msg::TransformStamped` |
| `br.sendTransform(tf::StampedTransform(t, stamp, "a", "b"))` | construct `TransformStamped`, set fields, `br_.sendTransform(ts)` |

---

## Gotcha #38: `colcon build --packages-select <one>` doesn't see workspace overlay deps

### Symptom
```bash
$ colcon build --packages-select fast_livo
fatal error: livox_ros_driver2/msg/custom_msg.hpp: No such file or directory
```
…even though `install/livox_ros_driver2/include/...` exists in the same
workspace and was built earlier.

### Cause
`colcon build --packages-select X` builds **only** package X. CMake's
`find_package(livox_ros_driver2 …)` still needs the dependency to be on
`AMENT_PREFIX_PATH` — but `colcon` does not auto-add `<this-ws>/install/<dep>`
to the build environment unless you've sourced it.

### Fix
Two clean options:

**(a) Source the overlay before incremental builds** (works always):
```bash
source /opt/ros/humble/setup.bash
source ~/<ws>/install/setup.bash       # makes already-built siblings visible
colcon build --packages-select fast_livo
```

**(b) Let colcon resolve the dep graph** (better for clean builds):
```bash
source /opt/ros/humble/setup.bash
colcon build --packages-up-to fast_livo
```
This builds livox_ros_driver2 → vikit_common → vikit_ros → fast_livo in
order, in a single invocation, without the overlay-source dance.

### Trap
If you sourced the overlay **before** the first build, you may hit Gotcha #30
(stale cache from CMake remembering the old install paths). The two gotchas
trade off — pick one rule for your project and stick to it:

| Rule | Suits |
|---|---|
| Always source `install/setup.bash` before `colcon build` | day-to-day dev with frequent `--packages-select` |
| Never source `install/setup.bash` before `colcon build` | clean builds, CI, `--packages-up-to` |

---

## Gotcha #39: `stamp.toSec()` and high-precision time round-tripping

### Symptom
```cpp
double t = msg->header.stamp.toSec();
//                            ^^^^^^^ error: 'class builtin_interfaces::msg::Time'
//                                    has no member named 'toSec'
```
Or, more insidiously, you write a value into a stamp by hand and lose ~1µs:
```cpp
msg->header.stamp = rclcpp::Time(int64_t(stamp_double * 1e9));
// then re-read: rclcpp::Time(msg->header.stamp).seconds() differs by ~1e-6
```

### Cause
`std_msgs::msg::Header::stamp` is a `builtin_interfaces::msg::Time` (POD with
`int32 sec` and `uint32 nanosec`). The ROS1 helpers `.toSec()` / `.fromSec()`
are gone; you must wrap in `rclcpp::Time` first.

The precision loss is the classic double→int64 nanosecond mistake: a Unix
timestamp ≈ 1.77e9 has ~10 decimal digits, but double's ~15.95 sig digits
leave only ~5–6 digits below the second mark — so multiplying by 1e9 truncates
sub-microsecond precision.

### Fix — read
```cpp
double t = rclcpp::Time(msg->header.stamp).seconds();
```

### Fix — write a double timestamp into a stamp without precision loss
```cpp
double stamp = ...;                                   // e.g. 1770885771.7012345
int64_t s  = static_cast<int64_t>(std::floor(stamp));
int64_t ns = static_cast<int64_t>(std::round((stamp - s) * 1e9));
msg->header.stamp = rclcpp::Time(s, ns);
```

This idiom avoids the double-precision loss observed in GLIM and other LIO
systems where `tf_time_offset: 1e-6` µs jitter caused TF lookup failures.
See `CLAUDE.md` of the rtabmap_ws workspace for a real incident.

---

## Gotcha #40: `.rviz` config files load but show empty / "class not registered"

### Symptom
You launch `rviz2 -d main.rviz` ported from ROS1. RViz2 starts, but:
- The Displays panel is empty or shows "**Class 'rviz/Grid' is not
  registered**" warnings on stdout.
- A `PointCloud2` topic appears in the Displays list but no points show
  up — even though `ros2 topic echo` confirms the publisher is alive.

### Cause
Two related schema differences:

1. **Class names moved into `rviz_default_plugins/`**. Every display, tool,
   and view-controller has a new `Class:` value:
   ```yaml
   # ROS1 .rviz                       # ROS2 .rviz
   Class: rviz/Grid                   Class: rviz_default_plugins/Grid
   Class: rviz/PointCloud2            Class: rviz_default_plugins/PointCloud2
   Class: rviz/PoseStamped            Class: rviz_default_plugins/Pose      ← also renamed
   Class: rviz/Orbit                  Class: rviz_default_plugins/Orbit
   ```

2. **`Topic: /xxx` is now a sub-property block carrying QoS fields**.
   ```yaml
   # ROS1
   Topic: /cloud_registered

   # ROS2
   Topic:
     Value: /cloud_registered
     Depth: 5
     History Policy: Keep Last
     Reliability Policy: Best Effort        ← must match publisher!
     Durability Policy: Volatile
     Filter size: 10
   ```

### Detection
```bash
grep -rEl '^[[:space:]]+Class: rviz/' <pkg>/rviz/        # ROS1-style classes
grep -rE  '^[[:space:]]+Topic: /'      <pkg>/rviz/        # short-form topics
```
Either grep returning hits ⇒ the file needs conversion.

### Fix
**Mechanical pass** — handles all class renames:
```bash
bash helpers/rewrite_rviz_config.sh path/to/main.rviz
# or recurse into a directory:
bash helpers/rewrite_rviz_config.sh path/to/<pkg>/rviz/
```

**Manual pass** — for the Topic-block conversion (the helper warns but
doesn't auto-fix):
```bash
rviz2 -d path/to/main.rviz                     # open it
#  - acknowledge "class not registered" warnings (helper missed something)
#  - re-add or fix any displays
#  - File → Save Config (Ctrl+S) to canonicalise
```
RViz2's save round-trip is the cheapest way to reach a fully-valid file —
it fills in default QoS sub-properties and removes deprecated keys.

### `RobotModel` special case
RViz2 reads URDF from a **topic** (`/robot_description`), not a parameter.
The display has a `Description Topic` field. Either:
- Run `robot_state_publisher` (which publishes `/robot_description` in
  ROS2 Humble), or
- Set `Description Source: File` and `Description File: <path>` in the
  display.

### When to scrap and start over
For any `.rviz` more than ~3 years old, or carrying displays from an
in-house RViz1 plugin, it's faster to launch a fresh `rviz2`, add the
displays you actually need, and `Save Config As`. Budget 10–30 minutes
per `.rviz`. Custom RViz1 plugins remain a separate rewrite — see
Gotcha #24.

---

## Summary Table

| Gotcha | Detection | Severity |
|---|---|---|
| Wrong header path | grep `<*_msgs/[A-Z]*\.h>` | ⭐⭐⭐ |
| Missing `::msg::` | grep | ⭐⭐⭐ |
| Param semantics | runtime warning | ⭐⭐⭐ |
| QoS mismatch | `ros2 topic info --verbose` | ⭐⭐⭐ |
| Latched not transient_local | echo from new sub | ⭐⭐ |
| `tf::*` types | compile error | ⭐⭐ |
| TF broadcaster ctor | compile error | ⭐⭐ |
| `ros::Time::now` | compile error | ⭐⭐ |
| `pcl_ros` removed | compile error | ⭐ |
| Nodelet API | runtime no-load | ⭐⭐ |
| `dynamic_reconfigure` | compile error | ⭐⭐ |
| `actionlib` rewrite | compile error | ⭐⭐⭐ |
| Wrong setup.bash | linker error | ⭐⭐ |
| `colcon` layout | "exe not found" | ⭐ |
| Missing `install(DIRECTORY launch)` | `ros2 launch` not found | ⭐⭐ |
| YAML node name mismatch | params not applied | ⭐⭐ |
| `ros2 launch` log loss | crashes invisible | ⭐⭐ |
| Header time field | compile error | ⭐ |
| boost::shared_ptr | compile error | ⭐ |
| Double-spin UB | runtime crash | ⭐ |
| MTE data races | random crashes | ⭐⭐⭐ |
| rosbag1 incompatible | "could not open" | ⭐⭐ |
| pluginlib path | runtime no-load | ⭐⭐ |
| RViz1 plugin | runtime invisible | ⭐⭐⭐ |
| `ros::package::getPath` | compile error | ⭐ |
| Missing `shutdown` | hang at exit | ⭐ |
| `use_sim_time` | bag replay deadlock | ⭐⭐ |
| Eigen threading | random crashes | ⭐⭐ |
| `message_filters` API | compile error | ⭐⭐ |
| Stale colcon cache | spurious second-run failures | ⭐ |
| Half-ported `*_ROS2` repo | `grep -r ros::NodeHandle` | ⭐⭐⭐ |
| Sophus 1.x SE3 template | compile error | ⭐⭐⭐ |
| Sophus×Eigen Matrix clash | cryptic compile error | ⭐⭐⭐ |
| Catkin-only satellite lib (vikit) | compile error | ⭐⭐ |
| FAST-LIVO `AbstractCamera` extension | compile error | ⭐⭐ |
| `ROS_ASSERT` removed | compile error | ⭐ |
| `tf::createQuaternionMsg…` removed | compile error | ⭐⭐ |
| `--packages-select` misses overlay | compile error | ⭐⭐⭐ |
| `stamp.toSec()` / int64 ns precision | compile error / silent µs loss | ⭐⭐ |
| `.rviz` class names + Topic→QoS | empty Displays / wrong QoS | ⭐⭐ |

---

**Remember**:
- Read each gotcha **before** you write the offending pattern, not after.
- The first time you see a symptom from this list, fix it; the second time, automate the fix
  (add to `helpers/` or `verification/`).
- Migration is mostly mechanical until it isn't. Keep a private "weird stuff" log in
  `MIGRATION_PLAN.md` decisions section so you don't relearn the same lesson twice.
