# Worked Example: Migrating Voxel-SLAM (Noetic → Humble)

> Real-world walkthrough of porting [Voxel-SLAM](https://arxiv.org/abs/2410.08935), a
> ROS1 LiDAR-Inertial SLAM, to ROS2 Humble. Repository layout assumed:
> `~/lio_ws/src/Voxel-SLAM/{VoxelSLAM,VoxelSLAMPointCloud2}/`.

---

## Why this example

Voxel-SLAM is a representative real-world ROS1 package:
- Two packages: `VoxelSLAM` (the SLAM node) + `VoxelSLAMPointCloud2` (an RViz1 plugin).
- ~8.5k LoC of C++ that mostly is **algorithm code** (PCL, Eigen, GTSAM) plus a thin
  **ROS-touching seam** (callbacks, publishers, parameters, TF, launch).
- Multi-threaded (3 threads): a perfect canary for callback-group / executor questions.
- Lots of YAML configs, six per-sensor launch files.
- Uses `livox_ros_driver` — a third-party ROS1 driver with a community ROS2 fork.

The migration follows the seven-phase WORKFLOW.md exactly. Skip-ahead summary:

| Phase | Effort | Hardest part |
|---|---|---|
| 0. Inventory | 30 min | Triaging `livox_ros_driver` → `livox_ros_driver2` |
| 1. Plan | 30 min | Deciding to defer the RViz plugin (Phase 7) |
| 2. Build skeleton | 1–2 h | Per-package `package.xml` + CMakeLists.txt |
| 3. Headers | 1 h | `<sensor_msgs/Imu.h>` style → `<sensor_msgs/msg/imu.hpp>` |
| 4. Node API | 1–2 days | Three-thread executor + parameter hierarchy |
| 5. Launch | 2–4 h | Six `.launch` files × per-sensor YAML wiring |
| 6. Verify | 1 day | Bag replay against ROS1 baseline |
| 7. Cleanup | 2 h | RViz plugin (or defer) + README |

Total: roughly 3–4 engineering days for a working migration; another 1–2 days if you
re-implement the RViz plugin.

---

## Phase 0: Inventory

```bash
cd ~/lio_ws
bash /home/steve/.claude/skills/ros2-migration/helpers/audit_workspace.sh src/Voxel-SLAM
```

Expected output highlights:

- **2 packages**: `VoxelSLAM` (ament_cmake target), `VoxelSLAMPointCloud2` (currently has
  `COLCON_IGNORE` — was a stub for ROS2 attempt).
- **Dependencies**:
  - ✅ Native: `roscpp`, `std_msgs`, `sensor_msgs`, `geometry_msgs`, `nav_msgs`, `tf`,
    `pcl_conversions`, `pcl_ros` (all map cleanly).
  - ⚠️ Has fork: `livox_ros_driver` → `livox_ros_driver2` (NB: message-package name and
    `CustomMsg` definition unchanged, but the binary driver and its C++ namespace differ).
- **Source seams** (count of files affected):
  - `<*_msgs/*.h>` legacy headers: ~6 files.
  - `tf::*` types: 3 occurrences in `voxelslam.cpp`.
  - `ros::Time::now()`: ~12 occurrences.
  - `n.param<*>`: ~30 calls in `voxelslam.cpp` and `voxelslam.hpp`.
  - `pluginlib`: only inside `VoxelSLAMPointCloud2` (RViz plugin).
- **Launch files**: 6 (`vxlm_avia.launch`, `vxlm_avia_fly.launch`, `vxlm_hesai.launch`,
  `vxlm_mid360.launch`, `vxlm_ouster.launch`, `vxlm_velodyne.launch`).
- **Custom interfaces**: 0 (Voxel-SLAM publishes only standard messages).

### Phase 0 verdict

- **Blocker**: `livox_ros_driver` has a documented ROS2 fork (`livox_ros_driver2`,
  github.com/Livox-SDK/livox_ros_driver2) — install it before Phase 2.
- **Defer**: `VoxelSLAMPointCloud2` is an RViz1 plugin. Mark it for Phase 7 rewrite (or
  drop entirely if RViz2's built-in `PointCloud2` display suffices). Keep its
  `COLCON_IGNORE` for now.

Update `MIGRATION_PLAN.md`:

```markdown
## Tier order
1. tier 0: voxel_slam (main SLAM node — directory `VoxelSLAM/`, package `<name>voxel_slam</name>`)
2. tier 1: VoxelSLAMPointCloud2 (RViz plugin — defer)

## Decisions log
- 2026-MM-DD: Defer VoxelSLAMPointCloud2; rely on RViz2 native PointCloud2 display.
- 2026-MM-DD: Use livox_ros_driver2 for Mid360/Avia. Re-route topic remap in launch.
```

---

## Phase 1: Branch + plan

```bash
cd ~/lio_ws/src/Voxel-SLAM
git checkout -b ros2-migration
source /opt/ros/humble/setup.bash
ros2 --version           # expect humble
```

Install `livox_ros_driver2`:

```bash
cd ~/lio_ws/src
git clone https://github.com/Livox-SDK/livox_ros_driver2.git
cd livox_ros_driver2 && bash build.sh humble
```

(Note: `livox_ros_driver2` has a non-standard `build.sh` — it patches its own
`package.xml` based on the target distro. Run **once**.)

---

## Phase 2: Build skeleton (`voxel_slam`)

> ⚠️ The directory is `VoxelSLAM/` but the ROS package name (from `package.xml`'s `<name>`)
> is `voxel_slam`. `colcon`, `ros2 run`, `ros2 launch`, and `FindPackageShare` all use the
> package name — **never the directory name**.

### 2.1 `package.xml`

```bash
python3 /home/steve/.claude/skills/ros2-migration/helpers/convert_package_xml.py \
    ~/lio_ws/src/Voxel-SLAM/VoxelSLAM/package.xml
```

Inspect the result (the original is backed up to `package.xml.bak`). Manual edits:

```xml
<!-- Add these — Voxel-SLAM uses GTSAM and PCL specifically -->
<depend>pcl_conversions</depend>
<depend>livox_ros_driver2</depend>          <!-- replaces livox_ros_driver -->
<!-- gtsam is a system dep; declare it under <depend> only if a rosdep key exists,
     otherwise leave to CMakeLists.txt -->
```

Final dependency list (Voxel-SLAM specific):

```xml
<buildtool_depend>ament_cmake</buildtool_depend>
<depend>rclcpp</depend>
<depend>std_msgs</depend>
<depend>sensor_msgs</depend>
<depend>geometry_msgs</depend>
<depend>nav_msgs</depend>
<depend>visualization_msgs</depend>
<depend>tf2</depend>
<depend>tf2_ros</depend>
<depend>tf2_geometry_msgs</depend>
<depend>pcl_conversions</depend>
<depend>livox_ros_driver2</depend>
<depend>ament_index_cpp</depend>
```

### 2.2 `CMakeLists.txt`

Use `helpers/scaffold_cmakelists.sh` as a starting point:

```bash
bash /home/steve/.claude/skills/ros2-migration/helpers/scaffold_cmakelists.sh \
    ~/lio_ws/src/Voxel-SLAM/VoxelSLAM/CMakeLists.txt > /tmp/cml.ros2
```

The generated stub captures the executable name (`voxelslam`) and core deps. Add:

```cmake
find_package(PCL 1.10 REQUIRED COMPONENTS common io kdtree)
add_definitions(${PCL_DEFINITIONS})

find_package(Eigen3 3.3 REQUIRED NO_MODULE)

# GTSAM is not ament-aware; use plain CMake
find_package(GTSAM REQUIRED)
find_package(GTSAM_UNSTABLE QUIET)

add_executable(voxelslam
  src/voxelslam.cpp
  src/BTC.cpp
)

ament_target_dependencies(voxelslam
  rclcpp std_msgs sensor_msgs geometry_msgs nav_msgs visualization_msgs
  tf2 tf2_ros tf2_geometry_msgs
  pcl_conversions livox_ros_driver2 ament_index_cpp)

target_link_libraries(voxelslam
  ${PCL_LIBRARIES}
  Eigen3::Eigen
  gtsam)

target_compile_options(voxelslam PRIVATE -O3)

install(TARGETS voxelslam DESTINATION lib/${PROJECT_NAME})
install(DIRECTORY launch config rviz_cfg
        DESTINATION share/${PROJECT_NAME})

ament_package()
```

### 2.3 First build smoke test

For Phase 2 we want **just the build skeleton to succeed** before touching code. Voxel-SLAM
unfortunately has its `main()` heavily intertwined with ROS1 — so for the skeleton, comment
out the body of `main()` and leave only `rclcpp::init`/`rclcpp::shutdown` to compile:

```cpp
// At the end of voxelslam.cpp:
int main(int argc, char ** argv) {
  rclcpp::init(argc, argv);
  // TODO: ROS2 — re-enable after Phase 4
  // VOXEL_SLAM vs(...);
  // ...
  rclcpp::shutdown();
  return 0;
}
```

This **won't link** because the rest of `voxelslam.cpp` references `ros::Publisher`, etc.
The cleanest workaround for the skeleton phase: temporarily wrap the file content in
`#if 0 ... #endif` and only enable the bits you've already migrated. Build:

```bash
cd ~/lio_ws
colcon build --packages-select voxel_slam --cmake-args -Wno-dev
```

### Phase 2 quality gate

- [ ] `package.xml` is format 3, ament-based.
- [ ] `CMakeLists.txt` uses `ament_cmake`, `ament_target_dependencies`, `gtsam` linked.
- [ ] `colcon build --packages-select voxel_slam` succeeds (with stub main).
- [ ] `ros2 run voxel_slam voxelslam` exits cleanly.

---

## Phase 3: Headers & types

```bash
bash /home/steve/.claude/skills/ros2-migration/helpers/rewrite_headers.sh \
    ~/lio_ws/src/Voxel-SLAM/VoxelSLAM/src
```

Manual fixups specific to Voxel-SLAM:

| ROS1 include | ROS2 replacement | File |
|---|---|---|
| `<ros/ros.h>` | `<rclcpp/rclcpp.hpp>` | every `.cpp` and `voxelslam.hpp` |
| `<tf/transform_broadcaster.h>` | `<tf2_ros/transform_broadcaster.h>` | `voxelslam.cpp:19` |
| `<sensor_msgs/Imu.h>` | `<sensor_msgs/msg/imu.hpp>` | `voxelslam.hpp:5`, `ekf_imu.hpp:6`, `preintegration.hpp:5` |
| `<sensor_msgs/PointCloud2.h>` | `<sensor_msgs/msg/point_cloud2.hpp>` | `feature_point.hpp:6` |
| `<pcl_conversions/pcl_conversions.h>` | unchanged | `feature_point.hpp:5`, `voxelslam.hpp:?` |
| `<livox_ros_driver/CustomMsg.h>` | `<livox_ros_driver2/msg/custom_msg.hpp>` | `feature_point.hpp:7` |
| `<visualization_msgs/MarkerArray.h>` | `<visualization_msgs/msg/marker_array.hpp>` | `voxelslam.hpp:11` |
| `<geometry_msgs/PoseArray.h>` | `<geometry_msgs/msg/pose_array.hpp>` | `voxelslam.hpp:13` |

Then update the namespace usages (`sensor_msgs::Imu` → `sensor_msgs::msg::Imu`, etc.) — about
30 occurrences in `voxelslam.cpp` and `voxelslam.hpp`. After editing, compile:

```bash
colcon build --packages-select voxel_slam
```

Expect dozens of errors complaining about `ros::Publisher`, `ros::NodeHandle`, etc. That's
**Phase 4's job** — we just want zero **header / parser** errors here.

---

## Phase 4: Node API

This is the substantive phase. Voxel-SLAM's main class `VOXEL_SLAM` runs three threads
(`thd_odometry_localmapping`, `thd_loop_closure`, `thd_globalmapping`) sharing buffers and
mutexes. The migration touches all three plus the ROS-callback-driven `imu_handler` /
`pcl_handler`.

### 4.1 Convert global state to a node class

ROS1 `voxelslam.cpp` declares globals at file scope:

```cpp
// voxelslam.hpp:42-47 (ROS1)
mutex mBuf;
Features feat;
deque<sensor_msgs::Imu::Ptr> imu_buf;
deque<pcl::PointCloud<PointType>::Ptr> pcl_buf;
deque<double> time_buf;
ros::Publisher pub_scan, pub_cmap, ...;
ros::Subscriber sub_imu, sub_pcl;
```

In ROS2 you have two options:
1. **Quick & dirty (recommended for migration)**: keep them as globals but make `pub_scan`,
   `sub_imu`, etc. type `rclcpp::Publisher<...>::SharedPtr` and create them inside the
   `VOXEL_SLAM` constructor (which now takes `rclcpp::Node::SharedPtr`).
2. **Idiomatic**: make `VOXEL_SLAM` a subclass of `rclcpp::Node` itself.

Option 1 keeps the diff smaller and the threading model identical. Recommended:

```cpp
// voxelslam.hpp (ROS2)
extern std::mutex mBuf;
extern Features feat;
extern std::deque<sensor_msgs::msg::Imu::SharedPtr> imu_buf;
extern std::deque<pcl::PointCloud<PointType>::Ptr>  pcl_buf;
extern std::deque<double> time_buf;

extern rclcpp::Publisher<sensor_msgs::msg::PointCloud2>::SharedPtr
        pub_scan, pub_cmap, pub_init, pub_pmap;
extern rclcpp::Publisher<sensor_msgs::msg::PointCloud2>::SharedPtr
        pub_test, pub_prev_path, pub_curr_path;
extern rclcpp::Subscription<sensor_msgs::msg::Imu>::SharedPtr           sub_imu;
extern rclcpp::SubscriptionBase::SharedPtr                              sub_pcl;

void imu_handler(sensor_msgs::msg::Imu::SharedPtr msg);
template<class T> void pcl_handler(typename T::SharedPtr msg);
```

### 4.2 Rewrite `imu_handler` and `pcl_handler`

```cpp
// ROS1 (voxelslam.hpp:52-74)
void imu_handler(const sensor_msgs::Imu::ConstPtr &msg_in) {
  ...
  sensor_msgs::Imu::Ptr msg(new sensor_msgs::Imu(*msg_in));
  mBuf.lock();
  imu_last_time = msg->header.stamp.toSec();
  imu_buf.push_back(msg);
  mBuf.unlock();
}

// ROS2
void imu_handler(sensor_msgs::msg::Imu::SharedPtr msg_in) {
  auto msg = std::make_shared<sensor_msgs::msg::Imu>(*msg_in);
  mBuf.lock();
  imu_last_time = rclcpp::Time(msg->header.stamp).seconds();
  imu_buf.push_back(msg);
  mBuf.unlock();
}
```

Notice:
- `ConstPtr` → `SharedPtr` (or take `const sensor_msgs::msg::Imu &`).
- `header.stamp.toSec()` is gone — use `rclcpp::Time(msg->header.stamp).seconds()`.

### 4.3 Replace `n.param<>` calls

There are ~30 lines like:

```cpp
// ROS1 (voxelslam.cpp:769-833)
n.param<string>("General/lid_topic", lid_topic, "/livox/lidar");
n.param<int>("General/lidar_type", feat.lidar_type, 0);
n.param<double>("Odometry/cov_gyr", cov_gyr, 0.1);
n.param<vector<double>>("LocalBA/plane_eigen_value_thre", plane_eigen_value_thre, vector<double>({1, 1, 1, 1}));
```

Replace with `declare_parameter` + `get_parameter`. The parameter names need `/` → `.` for
nesting:

```cpp
// ROS2
node->declare_parameter<std::string>("General.lid_topic", "/livox/lidar");
lid_topic = node->get_parameter("General.lid_topic").as_string();

node->declare_parameter<int>("General.lidar_type", 0);
feat.lidar_type = node->get_parameter("General.lidar_type").as_int();

node->declare_parameter<double>("Odometry.cov_gyr", 0.1);
cov_gyr = node->get_parameter("Odometry.cov_gyr").as_double();

node->declare_parameter<std::vector<double>>(
    "LocalBA.plane_eigen_value_thre",
    std::vector<double>{1.0, 1.0, 1.0, 1.0});
plane_eigen_value_thre = node->get_parameter("LocalBA.plane_eigen_value_thre").as_double_array();
```

Update **YAML files** (`avia.yaml`, etc.) to use **nested keys** instead of slash paths:

```yaml
# config/avia.yaml — ROS2 form
voxelslam:
  ros__parameters:
    General:
      lid_topic: "/livox/lidar"
      imu_topic: "/livox/imu"
      lidar_type: 0
      blind: 0.5
      ...
    Odometry:
      cov_gyr: 0.1
      cov_acc: 1.0
      ...
    LocalBA:
      win_size: 10
      plane_eigen_value_thre: [4.0, 4.0, 4.0, 4.0]
      ...
```

### 4.4 Replace publishers and subscribers

```cpp
// ROS1 (voxelslam.cpp:2604-2610)
pub_cmap = n.advertise<sensor_msgs::PointCloud2>("/map_cmap", 100);
pub_pmap = n.advertise<sensor_msgs::PointCloud2>("/map_pmap", 100);
... // 7 publishers total

sub_imu = n.subscribe(imu_topic, 80000, imu_handler);
if (feat.lidar_type == LIVOX)
  sub_pcl = n.subscribe<livox_ros_driver::CustomMsg>(lid_topic, 1000, pcl_handler);
else
  sub_pcl = n.subscribe<sensor_msgs::PointCloud2>(lid_topic, 1000, pcl_handler);

// ROS2
pub_cmap = node->create_publisher<sensor_msgs::msg::PointCloud2>("/map_cmap", rclcpp::QoS(100));
pub_pmap = node->create_publisher<sensor_msgs::msg::PointCloud2>("/map_pmap", rclcpp::QoS(100));
... // 7 publishers total

sub_imu = node->create_subscription<sensor_msgs::msg::Imu>(
    imu_topic, rclcpp::SensorDataQoS().keep_all(),    // approximate ROS1 queue=80000
    imu_handler);

if (feat.lidar_type == LIVOX) {
  sub_pcl = node->create_subscription<livox_ros_driver2::msg::CustomMsg>(
      lid_topic, rclcpp::SensorDataQoS(),
      [](livox_ros_driver2::msg::CustomMsg::SharedPtr msg) {
          pcl_handler<livox_ros_driver2::msg::CustomMsg>(msg);
      });
} else {
  sub_pcl = node->create_subscription<sensor_msgs::msg::PointCloud2>(
      lid_topic, rclcpp::SensorDataQoS(),
      [](sensor_msgs::msg::PointCloud2::SharedPtr msg) {
          pcl_handler<sensor_msgs::msg::PointCloud2>(msg);
      });
}
```

QoS choice rationale:
- IMU at 200 Hz — `SensorDataQoS()` (best-effort, depth 5) — drops under load.
- LiDAR at 10–20 Hz — `SensorDataQoS()` is fine; original ROS1 buffer of 1000 was a safety
  net you don't want in ROS2 (it just delays drops).

### 4.5 `ros::Time::now()` → `node->now()`

There are ~12 occurrences. Replace each. **Special case**: `ResultOutput::pub_odom_func` uses
`ros::Time::now()` to stamp a TF; pass the node into the singleton or create a helper:

```cpp
// ROS1
ros::Time ct = ros::Time::now();
br.sendTransform(tf::StampedTransform(transform, ct, "/camera_init", "/aft_mapped"));

// ROS2
auto ct = node->now();
geometry_msgs::msg::TransformStamped ts;
ts.header.stamp = ct;
ts.header.frame_id = "camera_init";
ts.child_frame_id = "aft_mapped";
ts.transform.translation.x = t_this.x();
ts.transform.translation.y = t_this.y();
ts.transform.translation.z = t_this.z();
ts.transform.rotation.w = q_this.w();
ts.transform.rotation.x = q_this.x();
ts.transform.rotation.y = q_this.y();
ts.transform.rotation.z = q_this.z();
br_.sendTransform(ts);
```

### 4.6 `ROS_INFO` / `ROS_ERROR` / `ROS_WARN` → `RCLCPP_*`

About 15 occurrences. Template:

```cpp
// ROS1
ROS_WARN("Reset");
ROS_ERROR("LiDAR time regress. Please check data");

// ROS2 — needs a logger; pass it via the node
RCLCPP_WARN(node->get_logger(), "Reset");
RCLCPP_ERROR(node->get_logger(), "LiDAR time regress. Please check data");
```

Where the function is called from a thread without direct access to `node`, capture
`rclcpp::Logger` once at startup as a global:

```cpp
extern rclcpp::Logger g_logger;
// in voxelslam.cpp::main: g_logger = node->get_logger();
RCLCPP_INFO(g_logger, "...");
```

### 4.7 Three-thread executor model

The existing model is exactly what `MultiThreadedExecutor` is designed for, but with a
twist: the threads are *not* spinning ROS callbacks — they're processing buffers fed by
ROS callbacks. So a `SingleThreadedExecutor` for the ROS side + the existing
`std::thread`s for the workers is correct:

```cpp
// in main()
rclcpp::init(argc, argv);
auto node = std::make_shared<rclcpp::Node>("voxelslam");

VOXEL_SLAM vs(node);                 // sets up pubs/subs/params
mp = new int[vs.win_size];
for (int i = 0; i < vs.win_size; i++) mp[i] = i;

std::thread thread_loop(&VOXEL_SLAM::thd_loop_closure, &vs, std::ref(node));
std::thread thread_gba(&VOXEL_SLAM::thd_globalmapping, &vs, std::ref(node));

// The main thread spins ROS callbacks AND runs the odometry/local mapping loop.
// In the ROS1 code, the main thread did "ros::spinOnce(); ... do work; ..." — the
// equivalent in ROS2 is a SingleThreadedExecutor we tick manually:
rclcpp::executors::SingleThreadedExecutor exec;
exec.add_node(node);

while (rclcpp::ok()) {
  exec.spin_some(std::chrono::milliseconds(0));
  vs.thd_odometry_localmapping_iteration(node);    // refactor to expose one iteration
  // (or keep the original `thd_odometry_localmapping(n)` and call exec.spin_some inside it)
}

thread_loop.join();
thread_gba.join();
rclcpp::shutdown();
```

**Critical**: the ROS1 code calls `ros::spinOnce()` inside `thd_odometry_localmapping`
(`voxelslam.cpp:1477`). The ROS2 equivalent is `exec.spin_some()`. Place it in the same
location.

### Phase 4 quality gate

- [ ] `colcon build --packages-select voxel_slam` clean.
- [ ] `ros2 run voxel_slam voxelslam --ros-args -p General.lid_topic:=/livox/lidar` boots.
- [ ] `ros2 topic list` shows `/map_cmap`, `/map_scan`, etc.
- [ ] `RCLCPP_INFO("scale_gravity: ...")` appears on stdout.

---

## Phase 5: Launch & params

### 5.1 Translate one launch file

Use the helper:

```bash
python3 /home/steve/.claude/skills/ros2-migration/helpers/launch_xml_to_py.py \
    ~/lio_ws/src/Voxel-SLAM/VoxelSLAM/launch/vxlm_avia.launch \
    > ~/lio_ws/src/Voxel-SLAM/VoxelSLAM/launch/vxlm_avia.launch.py
```

Manual review and edit:

```python
# vxlm_avia.launch.py (ROS2)
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare


def generate_launch_description():
    pkg = FindPackageShare('voxel_slam')
    cfg = PathJoinSubstitution([pkg, 'config', 'avia.yaml'])
    rviz = PathJoinSubstitution([pkg, 'rviz_cfg', 'voxelslam.rviz'])

    return LaunchDescription([
        DeclareLaunchArgument('rviz', default_value='true'),

        Node(
            package='voxel_slam', executable='voxelslam', name='voxelslam',
            output='screen',
            parameters=[cfg, {'use_sim_time': False}],
        ),

        Node(
            package='rviz2', executable='rviz2', name='rviz2',
            condition=IfCondition(LaunchConfiguration('rviz')),
            arguments=['-d', rviz],
        ),
    ])
```

### 5.2 Convert all six YAML configs

For each `<config>.yaml` in `VoxelSLAM/config/` (directory unchanged), prepend a node-name scope and indent:

```yaml
# Before (ROS1 / rosparam load)
General:
  lid_topic: "/livox/lidar"
  ...
Odometry:
  cov_gyr: 0.1
  ...

# After (ROS2)
voxelslam:                         # match Node(name='voxelslam', ...)
  ros__parameters:
    use_sim_time: false
    General:
      lid_topic: "/livox/lidar"
      imu_topic: "/livox/imu"
      lidar_type: 0
      blind: 0.5
      point_filter_num: 3
      extrinsic_tran: [0.04165, 0.02326, -0.0284]
      extrinsic_rota: [1.0, 0.0, 0.0,
                        0.0, 1.0, 0.0,
                        0.0, 0.0, 1.0]
      is_save_map: 0
    Odometry:
      cov_gyr: 0.1
      cov_acc: 1.0
      ...
    LocalBA:
      win_size: 10
      max_layer: 2
      plane_eigen_value_thre: [4.0, 4.0, 4.0, 4.0]
      ...
    Loop:
      jud_default: 0.5
      ...
    GBA:
      voxel_size: 2.0
      eigen_value_array: [4.0, 4.0, 4.0, 4.0]
      total_max_iter: 6
```

Watch out: integer literals like `1, 0, 0` in `extrinsic_rota` need to be `1.0, 0.0, 0.0`
because the parameter was declared as `vector<double>`. ROS2 type-pinning will reject int
arrays for double-array parameters.

### 5.3 Install rules

Already added in Phase 2:

```cmake
install(DIRECTORY launch config rviz_cfg DESTINATION share/${PROJECT_NAME})
```

Re-build:

```bash
cd ~/lio_ws
colcon build --packages-select voxel_slam
source install/setup.bash
ros2 launch voxel_slam vxlm_avia.launch.py
```

### Phase 5 quality gate

- [ ] `ros2 launch voxel_slam vxlm_avia.launch.py` brings the node up.
- [ ] No "parameter not declared" warnings.
- [ ] `ros2 topic list` shows expected topics.

---

## Phase 6: Verify (bag replay)

### 6.1 Convert a ROS1 bag

```bash
pip install rosbags
rosbags-convert ~/datasets/voxel_slam/site3_handheld_4.bag    # creates site3_handheld_4/
```

### 6.2 Replay

```bash
# Terminal 1
ros2 launch voxel_slam vxlm_avia.launch.py

# Terminal 2
ros2 bag play ~/datasets/voxel_slam/site3_handheld_4 --clock
```

(`--clock` requires `use_sim_time: True` in the param YAML for replay to use bag time.)

### 6.3 Compare against ROS1 baseline

Capture both trajectories:

```bash
# ROS1 (separate terminal — needs noetic sourced):
rosbag record -O ros1_traj.bag /map_path

# ROS2:
ros2 bag record -o ros2_traj /map_path
```

Plot both trajectories and check:
- Final position drift < 0.5 m on a 100 m loop.
- No NaN in the published path.
- Topic frequencies within 5 % of ROS1 baseline (use `ros2 topic hz` and ROS1 `rostopic hz`).

If trajectories diverge significantly, the most likely cause is **QoS-induced drops** —
check `ros2 topic info --verbose /livox/imu` and confirm both ends use compatible QoS.

### 6.4 Run deprecation grep

```bash
bash /home/steve/.claude/skills/ros2-migration/verification/deprecation_grep.sh \
     ~/lio_ws/src/Voxel-SLAM/VoxelSLAM/src
```

Expect zero hits.

---

## Phase 7: Cleanup

### 7.1 Remove ROS1 cruft

```bash
cd ~/lio_ws/src/Voxel-SLAM/VoxelSLAM
git rm launch/*.launch              # keep only the .launch.py versions
rm config/*.yaml.bak                # if any backups
git rm package.xml.bak              # converter backup
```

### 7.2 Decide: rebuild RViz plugin?

`VoxelSLAMPointCloud2` is an RViz1 plugin that auto-clears point clouds. In ROS2:
- **Option A** (recommended): drop the custom plugin. RViz2's built-in `PointCloud2` display
  has a "Decay Time" property that achieves the same effect.
- **Option B**: rewrite as `rviz_common::Display` subclass. ~1 day of work; see
  [rviz_default_plugins/point_cloud2_display.cpp](https://github.com/ros2/rviz/blob/humble/rviz_default_plugins/src/rviz_default_plugins/displays/pointcloud/point_cloud2_display.cpp).

Update `rviz_cfg/voxelslam.rviz` to use the built-in `rviz_default_plugins/PointCloud2`
display instead of `VoxelSLAMPointCloud2/PointCloud2`.

### 7.3 Update README

Replace the install section:

```markdown
## Build (ROS2 Humble)

cd ~/ros2_ws/src
git clone <this repo>
git clone https://github.com/Livox-SDK/livox_ros_driver2.git
cd livox_ros_driver2 && bash build.sh humble
cd ~/ros2_ws
colcon build --packages-up-to voxel_slam
source install/setup.bash

## Run

ros2 launch voxel_slam vxlm_avia.launch.py
```

### Phase 7 quality gate

- [ ] All `.launch` (XML) deleted.
- [ ] `package.xml.bak` deleted.
- [ ] README updated with ROS2 instructions.
- [ ] PR description summarises behavioural changes (especially QoS choices).

---

## Decisions Log (final state)

```markdown
- 2026-MM-DD: Defer VoxelSLAMPointCloud2; rely on RViz2 native PointCloud2 display.
- 2026-MM-DD: Use livox_ros_driver2 (HEAD as of build) for Livox sensors.
- 2026-MM-DD: Sensor topics use SensorDataQoS (best-effort) — drops under load are
              preferred over backpressure for real-time SLAM.
- 2026-MM-DD: All YAML config files re-scoped under `voxelslam: ros__parameters:` and
              integer arrays (extrinsic_rota) widened to doubles to match
              declare_parameter<vector<double>> typing.
- 2026-MM-DD: ROS_INFO macros replaced with RCLCPP_INFO; the global g_logger was
              introduced for thread workers that don't carry a node ref.
- 2026-MM-DD: ros::spinOnce() inside thd_odometry_localmapping replaced with
              exec.spin_some(0ms) (single-thread executor + explicit work loop).
```

---

## Pointers

| Need | File / command |
|---|---|
| Audit | `bash helpers/audit_workspace.sh src/Voxel-SLAM` |
| Convert package.xml | `python3 helpers/convert_package_xml.py <path>` |
| CMakeLists scaffold | `bash helpers/scaffold_cmakelists.sh <path>` |
| Header rewrite | `bash helpers/rewrite_headers.sh src/Voxel-SLAM/VoxelSLAM/src` |
| Launch port | `python3 helpers/launch_xml_to_py.py <path>` |
| Smoke test | `bash verification/smoke_test.sh src/Voxel-SLAM/VoxelSLAM` |
| Deprecation grep | `bash verification/deprecation_grep.sh src/Voxel-SLAM/VoxelSLAM/src` |
