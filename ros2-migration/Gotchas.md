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

---

**Remember**:
- Read each gotcha **before** you write the offending pattern, not after.
- The first time you see a symptom from this list, fix it; the second time, automate the fix
  (add to `helpers/` or `verification/`).
- Migration is mostly mechanical until it isn't. Keep a private "weird stuff" log in
  `MIGRATION_PLAN.md` decisions section so you don't relearn the same lesson twice.
