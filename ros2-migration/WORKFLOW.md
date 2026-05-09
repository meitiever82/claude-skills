# ROS2 Migration Mandatory Workflow (Noetic → Humble)

> **CRITICAL**: This workflow is **mandatory** for every ROS1→ROS2 migration. Skipping a phase
> compounds errors that get exponentially harder to debug.

---

## Core Principle

> **Every phase ends with a runnable artifact.** Never sit half-built across phases.

---

## Workflow Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│                ROS1 → ROS2 Migration: 7 Phases + Quality Gates           │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  Phase 0: Inventory          (read-only — no code changes)               │
│   ├─ List packages, deps, message types                                  │
│   ├─ Identify external blockers (drivers, third-party deps)              │
│   └─ Gate ✅: every dependency has a known ROS2 equivalent OR plan       │
│                                                                          │
│  Phase 1: Plan + Branch                                                  │
│   ├─ Order packages by dependency depth                                  │
│   ├─ Write MIGRATION_PLAN.md                                             │
│   └─ Gate ✅: plan + branch + ROS2 toolchain ready                       │
│                                                                          │
│  Phase 2: Skeleton (per package)                                         │
│   ├─ Convert package.xml v2 → v3                                         │
│   ├─ Replace catkin → ament_cmake in CMakeLists.txt                      │
│   ├─ Add COLCON_IGNORE to other packages temporarily                     │
│   └─ Gate ✅: `colcon build --packages-select <pkg>` succeeds             │
│                  with empty source (or stub main)                        │
│                                                                          │
│  Phase 3: Headers & Types                                                │
│   ├─ Rewrite <foo_msgs/Bar.h> → <foo_msgs/msg/bar.hpp>                   │
│   ├─ Update C++ namespaces (msg/srv/action subnamespaces)                │
│   ├─ tf::… → tf2::… / tf2_ros::…                                         │
│   └─ Gate ✅: package compiles (link errors expected, that's fine)       │
│                                                                          │
│  Phase 4: Node API                                                       │
│   ├─ ros::NodeHandle  → rclcpp::Node                                     │
│   ├─ ros::Publisher/Subscriber → rclcpp::Publisher/Subscription          │
│   ├─ ros::Time/Duration → rclcpp::Time/Duration                          │
│   ├─ ros::spin/spinOnce → rclcpp::spin / rclcpp::spin_some               │
│   ├─ n.param<T>(...) → declare_parameter + get_parameter                 │
│   ├─ tf::TransformBroadcaster → tf2_ros::TransformBroadcaster            │
│   ├─ ROS_INFO/ERROR → RCLCPP_INFO/ERROR with get_logger()                │
│   └─ Gate ✅: `ros2 run <pkg> <exe>` boots without crashing,             │
│                even if it doesn't yet do useful work                     │
│                                                                          │
│  Phase 5: Launch & Params                                                │
│   ├─ <pkg>.launch (XML) → <pkg>.launch.py                                │
│   ├─ <param name="..."> → declare_parameter + YAML file                  │
│   ├─ rosparam load → launch_ros.actions.Node(parameters=[...])           │
│   └─ Gate ✅: `ros2 launch <pkg> <pkg>.launch.py` brings node up         │
│                                                                          │
│  Phase 6: Verify                                                         │
│   ├─ `colcon test`                                                       │
│   ├─ `ros2 topic list` / echo on key topics                              │
│   ├─ Replay a bag against the new node and compare output                │
│   └─ Gate ✅: functional parity with ROS1 baseline                       │
│                                                                          │
│  Phase 7: Cleanup                                                        │
│   ├─ Remove ROS1-only files (.launch XML, package.xml v2 backups)        │
│   ├─ Remove `// ROS2 migration:` markers older than 30 days              │
│   ├─ Update README, CONTRIBUTING, CI                                     │
│   └─ Gate ✅: PR description lists every behavioural change              │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Phase 0: Inventory

**Purpose**: Build a complete picture of what depends on what before touching anything.

### 0.1 Workspace audit

```bash
# Run from the workspace root (where src/ lives)
bash helpers/audit_workspace.sh src/
```

The audit reports:
- All `package.xml` files and their format version
- `<depend>`, `<build_depend>`, `<exec_depend>` aggregated across packages
- Source files using `<ros/ros.h>`, `<roscpp/...>`, `<tf/transform_listener.h>`, `<*.h>` legacy
  message includes
- `.launch` files (XML) — count and locations
- `nodelet` plugins (`*.xml` plugin descriptors)
- RViz plugins
- Custom message/service/action definitions (`msg/`, `srv/`, `action/` directories)

### 0.2 Dependency triage

For each `<depend>` from `package.xml`:

| Status | Meaning | Action |
|---|---|---|
| ✅ ROS2 native | The dep ships in Humble (`rclcpp`, `tf2_ros`, `sensor_msgs`, ...) | Note the new name if different |
| ⚠️ Has ROS2 fork | Dep has a community ROS2 port (`livox_ros_driver` → `livox_ros_driver2`) | Document the fork URL |
| ❌ ROS1-only | Dep has no ROS2 equivalent | Either replace, port, or stop |

Save this in `MIGRATION_PLAN.md` § "Dependency triage". An unblocking entry here is the
single most common reason migrations stall.

### 0.3 Identify hot seams

Source-level seams that almost always need attention:

```bash
grep -rn "ros::Time::now\|ros::Duration\|ros::Rate\|ros::ok\|ros::spin" src/
grep -rn "tf::\|tf2::Transform[^L]" src/                # not tf2::TransformListener
grep -rn "pluginlib::ClassLoader\|nodelet::Nodelet" src/
grep -rn "message_filters::" src/
grep -rn "actionlib::" src/                              # → rclcpp_action
grep -rn "dynamic_reconfigure" src/                      # → declare_parameter + on_set_parameters_callback
grep -rn "ros::package::getPath" src/                    # → ament_index_cpp
grep -rn "<sensor_msgs/.*\.h>" src/                       # ROS1 header style
```

### 0.4 Inventory RViz configs

`.rviz` files are not just data — RViz1 and RViz2 use **different display class
names** (`rviz/Grid` vs `rviz_default_plugins/Grid`) and RViz2 wraps each
topic in a QoS sub-property block. A ROS1 `.rviz` will load in RViz2 with
broken displays unless you rewrite it.

```bash
find src/ -name '*.rviz' | xargs -I{} grep -l '^      Class: rviz/' {} 2>/dev/null
```

If the count is non-zero, log them in `MIGRATION_PLAN.md` for Phase 5 conversion
(see §5.4 below). Don't try to fix them now — wait until your launch file
references the converted path.

### Quality Gate 0

- [ ] All `<depend>` entries triaged
- [ ] All ROS1-only deps have a documented decision (port / replace / drop)
- [ ] Every `.launch`, `.rviz`, plugin, nodelet, action, message_filter is enumerated
- [ ] `MIGRATION_PLAN.md` § Inventory exists

**Cannot proceed if**: any blocker dep is "unknown".

---

## Phase 1: Plan + Branch

### 1.1 Topological ordering

Order packages so each is migrated **before** its dependents:

```
   tier 0 (leaves)         msg-only packages, common utilities
   tier 1                  one-package-deep clients of tier 0
   ...
   tier N (root)           main application node
```

Migrate tier 0 first. Use `colcon list --topological-order` (after Phase 2) to verify.

### 1.2 Write `MIGRATION_PLAN.md`

Required sections:

```markdown
# Migration Plan: <workspace name>

## Inventory  (Phase 0 output)
## Dependency Triage  (Phase 0 output)

## Tier order
1. tier 0: <pkgs>
2. tier 1: <pkgs>
3. ...

## Per-package plan
### <pkg name>
- ROS1 deps: ...
- ROS2 deps mapping: ...
- Headers to rewrite: ...
- Nodes: <list>
- Plugins: <list>
- Launch files: <list>
- Risk areas: <e.g. "uses rosbag1 API">

## Decisions log  (append-only)
- 2026-MM-DD: chose `livox_ros_driver2` over `livox_ros2_driver` because <reason>
- ...
```

### 1.3 Branch + ROS2 toolchain

```bash
git checkout -b ros2-migration
source /opt/ros/humble/setup.bash           # confirms toolchain
which colcon                                # confirms colcon is on PATH
ros2 --version                              # confirm Humble
```

### Quality Gate 1

- [ ] `MIGRATION_PLAN.md` committed on branch
- [ ] Tier ordering documented
- [ ] Branch created from a clean base
- [ ] `source /opt/ros/humble/setup.bash` works

---

## Phase 2: Skeleton (per package)

### 2.1 `package.xml` v2 → v3

Use `helpers/convert_package_xml.py`:

```bash
python3 helpers/convert_package_xml.py path/to/package.xml
```

This:
- Sets `<package format="3">`
- Replaces `<buildtool_depend>catkin</buildtool_depend>` with `ament_cmake` (or `ament_python`)
- Adds `<export><build_type>ament_cmake</build_type></export>`
- Renames common deps (`roscpp` → `rclcpp`, etc.)

Manual review checklist after conversion:
- [ ] One `<buildtool_depend>` only
- [ ] All ROS1 message deps still listed (their **package** names; ROS2 keeps them, e.g.
  `sensor_msgs` is still `sensor_msgs`)
- [ ] No `<run_depend>` (replaced by `<exec_depend>`)

### 2.2 `CMakeLists.txt` rewrite

Use `templates/CMakeLists.txt` as the starting point. Use
`helpers/scaffold_cmakelists.sh` to grep the ROS1 file for executables, libraries, and message
files and emit a stub:

```bash
bash helpers/scaffold_cmakelists.sh path/to/CMakeLists.txt > /tmp/CMakeLists.ros2
diff /tmp/CMakeLists.ros2 path/to/CMakeLists.txt   # review before replacing
```

Key transformations:

```cmake
# ROS1
find_package(catkin REQUIRED COMPONENTS
  roscpp std_msgs sensor_msgs tf
)
catkin_package(CATKIN_DEPENDS roscpp std_msgs sensor_msgs)
include_directories(${catkin_INCLUDE_DIRS})
add_executable(my_node src/main.cpp)
target_link_libraries(my_node ${catkin_LIBRARIES})

# ROS2
find_package(ament_cmake REQUIRED)
find_package(rclcpp     REQUIRED)
find_package(std_msgs   REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(tf2_ros    REQUIRED)
add_executable(my_node src/main.cpp)
ament_target_dependencies(my_node rclcpp std_msgs sensor_msgs tf2_ros)

install(TARGETS my_node DESTINATION lib/${PROJECT_NAME})
ament_package()
```

### 2.3 First-build smoke test

Stub `src/main.cpp` (if needed) to:

```cpp
#include <rclcpp/rclcpp.hpp>
int main(int argc, char ** argv) {
  rclcpp::init(argc, argv);
  auto node = std::make_shared<rclcpp::Node>("stub");
  RCLCPP_INFO(node->get_logger(), "stub up");
  rclcpp::spin(node);
  rclcpp::shutdown();
  return 0;
}
```

Build:

```bash
colcon build --packages-select <pkg> --cmake-args -Wno-dev
```

### Quality Gate 2

- [ ] `package.xml` is format 3, ament-based
- [ ] `CMakeLists.txt` uses `ament_cmake`, no `catkin` references
- [ ] `colcon build --packages-select <pkg>` succeeds (with stub main if needed)
- [ ] `ros2 run <pkg> <exe>` runs the stub

**Do not advance** if `colcon build` fails. Even one missing `find_package` will cascade.

---

## Phase 3: Headers & Types

### 3.1 Header rewrite

Run the header rewriter:

```bash
bash helpers/rewrite_headers.sh src/<pkg>
```

This script handles the standard pattern `<foo_msgs/Bar.h>` →
`<foo_msgs/msg/bar.hpp>` for `msg`, `srv`, and `action`. After it runs, manually check for:

- `<tf/transform_broadcaster.h>` → `<tf2_ros/transform_broadcaster.h>`
- `<tf/transform_listener.h>` → `<tf2_ros/transform_listener.h>` + `<tf2_ros/buffer.h>`
- `<pcl_ros/point_cloud.h>` → `<pcl_conversions/pcl_conversions.h>` (no `pcl_ros` in Humble core)
- `<image_transport/image_transport.h>` → still works, namespace unchanged
- `<dynamic_reconfigure/server.h>` → has no ROS2 equivalent; rewrite as parameter callbacks

### 3.2 Namespace updates

```cpp
// ROS1
sensor_msgs::Imu msg;
nav_msgs::Odometry odom;

// ROS2
sensor_msgs::msg::Imu msg;       // note the ::msg::
nav_msgs::msg::Odometry odom;
```

For services and actions:

```cpp
// ROS1
my_pkg::AddTwoInts srv;
actionlib::SimpleActionClient<my_pkg::FooAction> ac("foo", true);

// ROS2
my_pkg::srv::AddTwoInts srv;
rclcpp_action::Client<my_pkg::action::Foo>::SharedPtr ac;
```

### 3.3 Compile (link errors are fine here)

```bash
colcon build --packages-select <pkg>
```

You will see many `undefined reference` errors — that's expected at this stage. The goal is
zero **compile** errors (parsing/include).

### Quality Gate 3

- [ ] No `<*_msgs/*.h>` legacy includes remain (`grep -rn '<.*_msgs/[A-Z][a-zA-Z]*\.h>' src/`)
- [ ] All ROS message types use `::msg::`, services `::srv::`, actions `::action::`
- [ ] Compile errors are zero (link errors OK)

---

## Phase 4: Node API

This is the longest phase. Work **one node at a time**. After each node compiles, smoke-test
it standalone before moving on.

### 4.1 Node bootstrap

```cpp
// ROS1
int main(int argc, char **argv) {
  ros::init(argc, argv, "my_node");
  ros::NodeHandle n;
  ros::NodeHandle pn("~");
  // ...
  ros::spin();
  return 0;
}

// ROS2
class MyNode : public rclcpp::Node {
public:
  MyNode() : Node("my_node") {
    // Construct pubs/subs/timers here.
  }
};
int main(int argc, char ** argv) {
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<MyNode>());
  rclcpp::shutdown();
  return 0;
}
```

Two NodeHandles (`n` and `pn("~")`) are merged into one `rclcpp::Node` — parameters are
addressed by name without the `~/` prefix.

### 4.2 Publishers and subscribers

```cpp
// ROS1
ros::Publisher  pub = n.advertise<sensor_msgs::Imu>("imu/data", 100);
ros::Subscriber sub = n.subscribe("imu/raw", 100, &Cls::cb, this);

// ROS2
auto pub = node->create_publisher<sensor_msgs::msg::Imu>("imu/data", rclcpp::QoS(100));
auto sub = node->create_subscription<sensor_msgs::msg::Imu>(
  "imu/raw", rclcpp::QoS(100),
  std::bind(&Cls::cb, this, std::placeholders::_1));
```

QoS templates:
- `rclcpp::QoS(100)` — depth 100, default reliable+volatile (closest to ROS1 default)
- `rclcpp::SensorDataQoS()` — best-effort for high-rate sensors (IMU, LiDAR, camera)
- `rclcpp::SystemDefaultsQoS()` — DDS defaults (depth 10, reliable, volatile)

**Pick `SensorDataQoS()` for sensor topics** if you want to drop messages on overload, like
ROS1's UDP transport. Otherwise the buffer fills and drops at random.

### 4.3 Parameters

```cpp
// ROS1
double cov_gyr;
n.param<double>("Odometry/cov_gyr", cov_gyr, 0.1);

// ROS2 (declare once, then get)
this->declare_parameter<double>("Odometry.cov_gyr", 0.1);
double cov_gyr = this->get_parameter("Odometry.cov_gyr").as_double();
```

**Note**: ROS2 parameters use `.` as a sub-namespace separator (in YAML they use nested keys).
ROS1's `/` is **not** a subnamespace separator in ROS2 — use `.` everywhere.

For struct/array parameters:

```cpp
this->declare_parameter<std::vector<double>>("LocalBA.plane_eigen_value_thre",
                                             std::vector<double>{1.0,1.0,1.0,1.0});
auto v = this->get_parameter("LocalBA.plane_eigen_value_thre").as_double_array();
```

### 4.4 Time and rate

```cpp
// ROS1
ros::Time t = ros::Time::now();
ros::Duration d = ros::Time::now() - last;
ros::Rate r(50.0);
r.sleep();

// ROS2
rclcpp::Time t = node->now();             // or node->get_clock()->now()
rclcpp::Duration d = node->now() - last;
rclcpp::Rate r(50.0);
r.sleep();                                 // works, but a wall-rate timer is more idiomatic:
auto timer = node->create_wall_timer(20ms, std::bind(&Cls::tick, this));
```

### 4.5 Logging

```cpp
// ROS1
ROS_INFO ("v=%f", v);
ROS_WARN_THROTTLE(1.0, "still bad");
ROS_ERROR_STREAM("got " << x);

// ROS2
RCLCPP_INFO (node->get_logger(), "v=%f", v);
RCLCPP_WARN_THROTTLE(node->get_logger(), *node->get_clock(), 1000, "still bad");  // ms now
RCLCPP_ERROR_STREAM(node->get_logger(), "got " << x);
```

### 4.6 TF

```cpp
// ROS1
#include <tf/transform_broadcaster.h>
tf::TransformBroadcaster br;
br.sendTransform(tf::StampedTransform(t, ros::Time::now(), "world", "base"));

// ROS2
#include <tf2_ros/transform_broadcaster.h>
#include <geometry_msgs/msg/transform_stamped.hpp>
tf2_ros::TransformBroadcaster br(node);
geometry_msgs::msg::TransformStamped ts;
ts.header.stamp = node->now();
ts.header.frame_id = "world";
ts.child_frame_id  = "base";
ts.transform.translation.x = ...;        // populate from your data
ts.transform.rotation.w    = ...;
br.sendTransform(ts);
```

For listening:

```cpp
#include <tf2_ros/buffer.h>
#include <tf2_ros/transform_listener.h>
auto tf_buffer   = std::make_shared<tf2_ros::Buffer>(node->get_clock());
auto tf_listener = std::make_shared<tf2_ros::TransformListener>(*tf_buffer, node);
auto tf = tf_buffer->lookupTransform("world", "base", tf2::TimePointZero);
```

### 4.7 Spin model (single-threaded)

For most ports, the default single-threaded executor is fine:

```cpp
rclcpp::spin(std::make_shared<MyNode>());
```

If your ROS1 node ran multiple threads (e.g. one per `ros::AsyncSpinner`), use a
`rclcpp::executors::MultiThreadedExecutor` and assign callbacks to **callback groups**:

```cpp
auto exec = rclcpp::executors::MultiThreadedExecutor();
auto node = std::make_shared<MyNode>();
exec.add_node(node);
exec.spin();
```

In `MyNode` constructor:

```cpp
auto cb_group = create_callback_group(rclcpp::CallbackGroupType::Reentrant);
auto opts = rclcpp::SubscriptionOptions(); opts.callback_group = cb_group;
sub_ = create_subscription<...>("topic", qos, cb, opts);
```

### Quality Gate 4

- [ ] `colcon build` clean for the migrated package
- [ ] `ros2 run <pkg> <exe>` runs without crashing
- [ ] `ros2 topic list` shows expected publishers/subscribers
- [ ] `RCLCPP_INFO` calls produce output

---

## Phase 5: Launch & Params

### 5.1 `.launch` (XML) → `.launch.py`

Use the stub generator:

```bash
python3 helpers/launch_xml_to_py.py launch/foo.launch > launch/foo.launch.py
```

Then **review and edit** — the generator handles common patterns but not every macro.

ROS1 launch file:
```xml
<launch>
  <arg name="rviz" default="true"/>
  <node pkg="my_pkg" type="my_node" name="my_node" output="screen">
    <rosparam command="load" file="$(find my_pkg)/config/params.yaml"/>
    <param name="topic" value="/scan"/>
  </node>
  <node if="$(arg rviz)" pkg="rviz" type="rviz" name="rviz"
        args="-d $(find my_pkg)/rviz/main.rviz"/>
</launch>
```

ROS2 equivalent:
```python
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare

def generate_launch_description():
    pkg = FindPackageShare('my_pkg')
    return LaunchDescription([
        DeclareLaunchArgument('rviz', default_value='true'),
        Node(
            package='my_pkg', executable='my_node', name='my_node',
            output='screen',
            parameters=[PathJoinSubstitution([pkg, 'config', 'params.yaml']),
                        {'topic': '/scan'}],
        ),
        Node(
            package='rviz2', executable='rviz2', name='rviz2',
            condition=IfCondition(LaunchConfiguration('rviz')),
            arguments=['-d', PathJoinSubstitution([pkg, 'rviz', 'main.rviz'])],
        ),
    ])
```

### 5.2 Param file structure

ROS2 params are **scoped by node name**:

```yaml
# config/params.yaml
my_node:                    # must match Node(name='my_node', ...)
  ros__parameters:
    topic: /scan
    Odometry:
      cov_gyr: 0.1
      cov_acc: 1.0
    LocalBA:
      win_size: 10
      plane_eigen_value_thre: [4.0, 4.0, 4.0, 4.0]
```

If you used `n.param<>("Odometry/cov_gyr", ...)` in ROS1, declare in ROS2 as
`"Odometry.cov_gyr"` (dot, not slash) and let the YAML supply the nested form above.

### 5.3 Install launch and config

In `CMakeLists.txt`:

```cmake
install(DIRECTORY launch config rviz
        DESTINATION share/${PROJECT_NAME})
```

Without this, `ros2 launch` will not find your `.launch.py` files.

### 5.4 Convert RViz configs (`.rviz`)

`.rviz` files are versioned YAML. Two things differ between RViz1 and RViz2:

1. **Display / Tool / View-Controller class names** all moved into the
   `rviz_default_plugins/` namespace.
2. **Topic properties became sub-properties** carrying QoS fields (Depth,
   History Policy, Reliability Policy, Durability Policy, Filter size).

Without conversion, RViz2 starts but the displays show **"Class
'rviz/Grid' is not registered"** and the panel is empty.

#### Common class-name renames

| RViz1 (`Class: ...`) | RViz2 |
|---|---|
| `rviz/Grid` | `rviz_default_plugins/Grid` |
| `rviz/Image` | `rviz_default_plugins/Image` |
| `rviz/Camera` | `rviz_default_plugins/Camera` |
| `rviz/PointCloud2` | `rviz_default_plugins/PointCloud2` |
| `rviz/LaserScan` | `rviz_default_plugins/LaserScan` |
| `rviz/Path` | `rviz_default_plugins/Path` |
| `rviz/Odometry` | `rviz_default_plugins/Odometry` |
| `rviz/PoseStamped` | `rviz_default_plugins/Pose` *(also renamed)* |
| `rviz/PoseArray` | `rviz_default_plugins/PoseArray` |
| `rviz/PointStamped` | `rviz_default_plugins/PointStamped` |
| `rviz/Marker` | `rviz_default_plugins/Marker` |
| `rviz/MarkerArray` | `rviz_default_plugins/MarkerArray` |
| `rviz/RobotModel` | `rviz_default_plugins/RobotModel` *(see note)* |
| `rviz/TF` | `rviz_default_plugins/TF` |
| `rviz/Map` | `rviz_default_plugins/Map` |
| `rviz/Range` | `rviz_default_plugins/Range` |
| `rviz/Axes` | `rviz_default_plugins/Axes` |
| `rviz/InteractiveMarkers` | `rviz_default_plugins/InteractiveMarkers` |
| `rviz/MoveCamera` (Tool) | `rviz_default_plugins/MoveCamera` |
| `rviz/Select` (Tool) | `rviz_default_plugins/Select` |
| `rviz/SetGoal` / `rviz/2D Nav Goal` | `rviz_default_plugins/SetGoal` |
| `rviz/SetInitialPose` / `rviz/2D Pose Estimate` | `rviz_default_plugins/SetInitialPose` |
| `rviz/PublishPoint` | `rviz_default_plugins/PublishPoint` |
| `rviz/Orbit` (View Controller) | `rviz_default_plugins/Orbit` |
| `rviz/XYOrbit` | `rviz_default_plugins/XYOrbit` |
| `rviz/FPS` | `rviz_default_plugins/FPS` |
| `rviz/ThirdPersonFollower` | `rviz_default_plugins/ThirdPersonFollower` |
| `rviz/TopDownOrtho` | `rviz_default_plugins/TopDownOrtho` |

**`RobotModel` note**: RViz2 reads the URDF from a topic
(`/robot_description`), not from a parameter. The display has a `Description
Topic` field instead of `Robot Description` (param name). Republish the URDF
via `robot_state_publisher` (which already does this in ROS2 Humble), or use
the `Description Source: File` option.

#### Topic → QoS sub-properties

```yaml
# RViz1
- Class: rviz/PointCloud2
  Name: cloud_registered
  Topic: /cloud_registered
  Queue Size: 100
  Style: Points
```
becomes:
```yaml
# RViz2
- Class: rviz_default_plugins/PointCloud2
  Name: cloud_registered
  Topic:
    Value: /cloud_registered
    Depth: 5
    History Policy: Keep Last
    Reliability Policy: Best Effort        # set per-topic; LiDAR/IMU usually best_effort
    Durability Policy: Volatile
    Filter size: 10
  Style: Points
```

The most common runtime symptom of forgetting this: **RViz2 shows the topic
in green but the cloud never appears**. Cause: publisher uses `best_effort`
QoS (typical for LiDAR / sensor data) but the .rviz still encodes default
`reliable`. Fix the .rviz to match the publisher.

#### Tool / View Controller / Visualization Manager

Tools and view controllers also need the namespace change. Additionally
the global `Visualization Manager` may carry a stale `Tool Properties` block
that RViz2 silently drops if the tool class isn't found — which usually
just means the in-3D-view click tools don't work until you re-add them.

#### Helper

A simple sed-based rewriter handles the class renames:

```bash
bash helpers/rewrite_rviz_config.sh path/to/main.rviz
```

It:
- backs up `<file>.rviz.bak`
- substitutes the rename table above
- warns (does **not** auto-fix) when it sees `Topic: /something` that
  needs to be hand-converted to a QoS sub-property block

After running it, **open the file in RViz2 and re-save** — RViz2's "Save
Config As" canonicalises any remaining differences (defaults, missing
fields). This is the cheapest way to get a fully-valid RViz2 config.

#### When to give up and rebuild from scratch

If the `.rviz` file is more than a few years old, or carries displays from
an in-house RViz1 plugin, it's faster to:
1. Launch a fresh `rviz2`,
2. Add the displays you actually need,
3. `Save Config As <pkg>/rviz/main.rviz`,
4. `git diff` against the old file to confirm topic names and frames carry
   over.

Budget: 10–30 minutes per `.rviz`. Custom RViz1 plugins are a separate
rewrite — see Gotcha #24.

### Quality Gate 5

- [ ] `ros2 launch <pkg> <name>.launch.py` brings the node up
- [ ] All declared params in code receive YAML values (no warnings about defaults)
- [ ] Topic remappings (`<remap from="..." to="..."/>`) translated into `remappings=[...]`
- [ ] Conditions (`if=`/`unless=`) translated into `IfCondition`/`UnlessCondition`
- [ ] All referenced `.rviz` files load in RViz2 without "class not registered" warnings
- [ ] Sensor-data topics (LiDAR / IMU / Camera) in RViz match publisher QoS (best_effort vs reliable)

---

## Phase 6: Verify

### 6.1 Functional smoke test

Run `verification/smoke_test.sh`:

```bash
bash verification/smoke_test.sh src/<pkg>
```

This:
1. `colcon build --packages-select <pkg>`
2. `colcon test --packages-select <pkg>` (skipped if no tests)
3. Launches the node, waits 5 s
4. Captures `ros2 topic list` and `ros2 node info /<node>`
5. Reports a clean-exit / dirty-exit summary

### 6.2 Replay test (recommended)

If you have a ROS1 bag (`*.bag`):

```bash
# Convert to ROS2 bag
ros2 bag convert -i in.bag -o out
# Or use rosbags-convert (pip install rosbags)
rosbags-convert in.bag

# Replay against the new node
ros2 launch <pkg> <name>.launch.py &
ros2 bag play out
```

Compare:
- Topic frequencies (`ros2 topic hz`)
- Approximate output values (e.g. odometry trajectory) against the ROS1 baseline

### 6.3 Deprecation grep

```bash
bash verification/deprecation_grep.sh src/<pkg>
```

Reports any remaining ROS1-only patterns that should not be in the migrated source.

### Quality Gate 6

- [ ] `colcon build` clean
- [ ] `colcon test` matches ROS1 baseline (allow expected diffs)
- [ ] Smoke test passes
- [ ] Replay test produces topics with values within tolerance of ROS1
- [ ] `deprecation_grep.sh` returns zero hits

---

## Phase 7: Cleanup

### 7.1 Remove ROS1 cruft

- [ ] `.launch` XML files (move to `legacy_launch/` or delete)
- [ ] `package.xml.bak` from converter (delete)
- [ ] `catkin_*` references in CMakeLists.txt (delete)
- [ ] `CMakeLists.txt.user` from QtCreator (delete)
- [ ] Any commented-out ROS1 code blocks tagged `// TODO ROS1`

### 7.2 Update repo metadata

- [ ] README badges (build status now points to colcon, not catkin)
- [ ] CONTRIBUTING.md (mentions colcon, ament_cmake)
- [ ] CI: replace `catkin_make` with `colcon build` / `colcon test`

### 7.3 Document residual diffs

In `docs/ros2-migration/RESIDUAL_DIFFS.md`:
- QoS choices that differ from ROS1 (especially for high-rate sensor topics)
- Parameter name changes (`/` → `.`)
- Any behavioural change (e.g. sub queue size, timer drift, callback ordering)

### Quality Gate 7

- [ ] All cruft removed
- [ ] CI runs colcon-based pipeline successfully
- [ ] PR description summarises the migration

---

## Anti-Patterns (Stop Immediately If You See These)

🚩 **"Let me migrate everything in parallel"** — every package broken at once.
🚩 **"I'll fix the build later, just focus on the code"** — you can't test code that doesn't
   build.
🚩 **"Skip Phase 0, we know the code"** — Phase 0 catches the *ecosystem* blockers (third-
   party drivers without ROS2 forks). Skipping it virtually guarantees a stalled PR.
🚩 **"Use whatever QoS, it'll be fine"** — wrong QoS on a sensor topic causes the node to
   hold an ever-growing queue and miss real-time deadlines.
🚩 **"Keep the ROS1 launch.xml, it'll work"** — it won't; ROS2 launch is Python.
🚩 **"Auto-translate everything with sed"** — the helpers cover ~80%; the rest needs human
   judgement.

---

## Summary

| Phase | Output | Gate (cannot skip) |
|---|---|---|
| 0 | Inventory + dep triage | Every dep has a known plan |
| 1 | Branch + plan | `MIGRATION_PLAN.md` exists |
| 2 | Build skeleton | `colcon build` of stub succeeds |
| 3 | Headers fixed | Compile errors zero |
| 4 | Node API ported | `ros2 run` works |
| 5 | Launch ported | `ros2 launch` works |
| 6 | Verified | Replay test passes |
| 7 | Cleaned up | PR description complete |

**Workflow status**: MANDATORY for all `/ros2-migration` invocations.
**Version**: 1.0
**Target distro**: Humble (Iron/Jazzy with notes)
