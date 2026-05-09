# Worked Example: Migrating FAST-LIVO2_ROS2 (half-ported fork → buildable Humble)

> Real-world walkthrough: porting `Vulcan-YJX/FAST-LIVO2_ROS2` (a ROS1
> codebase whose author swapped header paths but left ros::* APIs intact) to
> ROS2 Humble. Companion case to `voxel-slam-migration.md`.
>
> Workspace layout assumed: `~/<ws>/src/FAST-LIVO2_ROS2/` plus separately
> cloned `~/<ws>/src/rpg_vikit/` (Taeyoung96 fork) and an installed
> `livox_ros_driver2`.

---

## Why this example

FAST-LIVO2 is the canonical "tightly-coupled LiDAR + Inertial + Visual
Odometry" reference and a frequent ROS2 porting target. The Vulcan-YJX
"ROS2" fork (May 2026) is representative of a broader phenomenon: **a fork
named `*_ROS2` that has only had its message-header includes rewritten**.
The actual API code is still ROS1.

In numbers:

| Layer | State at fork time |
|---|---|
| `<sensor_msgs/Imu.h>` style headers | ✓ already swapped |
| `package.xml` v3 + ament_cmake | ✓ already swapped |
| `ros::NodeHandle` / `Publisher` / `Subscriber` / `Timer` / `Time` / `Rate` | ✗ ROS1 (~119 hits in `LIVMapper.cpp`) |
| `image_transport`, `livox_ros_driver`, `tf::*`, `ROS_INFO/ASSERT` | ✗ ROS1 |
| Sophus | uses old `Sophus::SE3` (no template) — **incompatible with ROS2 Humble's `ros-humble-sophus` 1.22** |
| Sister library `rpg_vikit` | catkin-only on master (no ROS2 fork exists) |

**Lesson for future migrations**: do `grep -r "ros::NodeHandle" src/<repo>`
**before** giving the user an estimate. See Gotcha #31.

---

## Phase 0: Inventory

```bash
cd ~/<ws>
bash /path/to/skill/helpers/audit_workspace.sh src/FAST-LIVO2_ROS2

# Spot-check: is this really a ROS2 port?
grep -rcE "ros::NodeHandle|ros::Time::now|nh\.advertise|nh\.subscribe" \
  src/FAST-LIVO2_ROS2/{src,include}
```

Expected output:

- 1 package: `fast_livo` (ament_cmake, but with ROS1 internals).
- ROS1-API count: ~119 in `LIVMapper.cpp`, ~5 in `preprocess.cpp`, ~12 in
  `IMU_Processing.cpp`, ~2 in `main.cpp`. **Total ≈ 140 sites of code**.
- Sophus references: `using namespace Sophus`, `Sophus::SE3` (no template),
  `T.rotation_matrix()` — all need updating to Sophus 1.22.
- Missing dependencies on system: `vikit_common`, `vikit_ros`,
  `livox_ros_driver2`.

### Phase 0 verdict

This is **not a "build fix"** but a **substantive port**. Tell the user
upfront. Reasonable estimate: 2–4 hours of focused work for a clean compile
(no runtime validation).

Decisions logged to `MIGRATION_PLAN.md`:
1. Pull `Taeyoung96/rpg_vikit` and convert it to ament_cmake (no ROS2
   fork exists).
2. Use `livox_ros_driver2` from another workspace (or copy into ours).
3. Defer launch-file conversion — `mapping_avia.launch` is ROS1 XML; runtime
   testing will need a `.launch.py` rewrite later.

---

## Phase 1: Plan

Three packages to build in order:

```
1. vikit_common (ament_cmake conversion)
2. vikit_ros    (ament_cmake conversion + ROS2 camera_loader)
3. fast_livo    (heavy ROS1→ROS2 port)
```

Plus a shared external: `livox_ros_driver2` from `~/driver_ws/install/` or
copied into `<ws>/src/`.

---

## Phase 2: Port the satellite library — `rpg_vikit`

`rpg_vikit` (master branch is catkin/ROS1) provides camera classes and
math helpers. FAST-LIVO2 uses:

- `vikit_common`: `abstract_camera.h`, `pinhole_camera.h`, `math_utils.h`,
  `vision.h`, `robust_cost.h`, `performance_monitor.h`.
- `vikit_ros`: `camera_loader.h` (the only file we actually need).

### `vikit_common/package.xml` (rewrite)

```xml
<?xml version="1.0"?>
<package format="3">
  <name>vikit_common</name>
  <version>0.0.1</version>
  <description>Vision toolkit common (ROS2 ament port)</description>
  <maintainer email="forster@ifi.uzh.ch">cforster</maintainer>
  <license>GPLv3</license>
  <buildtool_depend>ament_cmake</buildtool_depend>
  <depend>eigen</depend>
  <depend>sophus</depend>
  <depend>libopencv-dev</depend>
  <export><build_type>ament_cmake</build_type></export>
</package>
```

### `vikit_common/CMakeLists.txt` (rewrite)

```cmake
cmake_minimum_required(VERSION 3.8)
project(vikit_common)
if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
endif()
add_compile_options(-Wall -Wno-unused-parameter -march=native)

find_package(ament_cmake REQUIRED)
find_package(Eigen3 REQUIRED)
find_package(OpenCV REQUIRED)
find_package(Sophus REQUIRED)

# NB: we DROP homography.cpp and img_align.cpp from the build —
# they use the old Sophus::SE3 API and FAST-LIVO2 doesn't call them.
set(SOURCEFILES
  src/atan_camera.cpp src/omni_camera.cpp src/math_utils.cpp
  src/vision.cpp src/performance_monitor.cpp src/robust_cost.cpp
  src/user_input_thread.cpp src/pinhole_camera.cpp)

add_library(${PROJECT_NAME} SHARED ${SOURCEFILES})
target_include_directories(${PROJECT_NAME} PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>
  ${EIGEN3_INCLUDE_DIR} ${OpenCV_INCLUDE_DIRS})
target_link_libraries(${PROJECT_NAME} ${OpenCV_LIBS} Sophus::Sophus)

install(DIRECTORY include/vikit DESTINATION include)
install(TARGETS ${PROJECT_NAME}
  EXPORT export_${PROJECT_NAME}
  ARCHIVE DESTINATION lib LIBRARY DESTINATION lib RUNTIME DESTINATION bin
  INCLUDES DESTINATION include)
ament_export_targets(export_${PROJECT_NAME} HAS_LIBRARY_TARGET)
ament_export_dependencies(Eigen3 OpenCV Sophus)
ament_package()
```

### Three patches inside `vikit_common` headers/sources

```diff
# include/vikit/math_utils.h
- #include <sophus/se3.h>
+ #include <sophus/se3.hpp>

# math_utils.h, line ~147 — Sophus 1.22 also exports `Matrix` (Gotcha #33)
-                  Matrix<double,2,6> & frame_jac)
+                  Eigen::Matrix<double,2,6> & frame_jac)

# src/pinhole_camera.cpp — OpenCV 4 dropped CV_INTER_LINEAR
-     cv::remap(raw, rectified, undist_map1_, undist_map2_, CV_INTER_LINEAR);
+     cv::remap(raw, rectified, undist_map1_, undist_map2_, cv::INTER_LINEAR);
```

### FAST-LIVO2-specific extension to `AbstractCamera` (Gotcha #35)

FAST-LIVO2 calls `cam->fx()` / `cy()` / `scale()` on `vk::AbstractCamera*`.
Stock vikit only puts them on `PinholeCamera`. Add virtuals on the base:

```diff
// include/vikit/abstract_camera.h
+   virtual double fx() const { return 0.0; }
+   virtual double fy() const { return 0.0; }
+   virtual double cx() const { return 0.0; }
+   virtual double cy() const { return 0.0; }
+   virtual double scale() const { return 1.0; }
```

```diff
// include/vikit/pinhole_camera.h
+   double scale_ = 1.0;
    ...
-   inline double fx() const { return fx_; };
+   inline double fx() const override { return fx_; };
+   inline double scale() const override { return scale_; };
+   inline void setScale(double s) { scale_ = s; }
```

### `vikit_ros` is now header-only — drop `output_helper.cpp`

`output_helper.cpp` uses `tf::*` and `ros::Publisher`. FAST-LIVO2 only needs
`camera_loader.h`. Removing it from the build avoids hours of porting ROS1
helpers nobody calls:

```cmake
# vikit_ros/CMakeLists.txt — header-only
cmake_minimum_required(VERSION 3.8)
project(vikit_ros)
find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(vikit_common REQUIRED)
install(DIRECTORY include/vikit DESTINATION include)
ament_export_include_directories(include)
ament_export_dependencies(rclcpp vikit_common)
ament_package()
```

### Rewrite `camera_loader.h` for ROS2 parameters

```cpp
// include/vikit/camera_loader.h
#include <rclcpp/rclcpp.hpp>
#include <vikit/abstract_camera.h>
#include <vikit/pinhole_camera.h>
// ... + atan, omni, params_helper

namespace vk { namespace camera_loader {
inline bool loadFromRosNs(rclcpp::Node* node, const std::string& ns,
                          vk::AbstractCamera*& cam) {
  const std::string p = ns.empty() ? "" : (ns + ".");
  std::string cam_model = getParam<std::string>(node, p + "cam_model");
  if (cam_model == "Pinhole") {
    auto* pinhole = new vk::PinholeCamera(
        getParam<int>(node,    p + "cam_width"),
        getParam<int>(node,    p + "cam_height"),
        getParam<double>(node, p + "cam_fx"),
        getParam<double>(node, p + "cam_fy"),
        getParam<double>(node, p + "cam_cx"),
        getParam<double>(node, p + "cam_cy"),
        getParam<double>(node, p + "cam_d0", 0.0),
        getParam<double>(node, p + "cam_d1", 0.0),
        getParam<double>(node, p + "cam_d2", 0.0),
        getParam<double>(node, p + "cam_d3", 0.0));
    pinhole->setScale(getParam<double>(node, p + "scale", 1.0));
    cam = pinhole;
    return true;
  }
  // ... ATAN, Ocam fall-throughs
  return false;
}
}}
```

`params_helper.h` becomes a thin wrapper around
`node->declare_parameter<T>(name, default); node->get_parameter(name, v);`.

### Build vikit

```bash
source /opt/ros/humble/setup.bash
colcon build --packages-up-to vikit_ros        # builds common+ros in order
```

---

## Phase 3: Sophus + Eigen + macros — `common_lib.h`

The single most important fix in the entire migration:

```diff
// include/common_lib.h
  using namespace std;
  using namespace Eigen;
- using namespace Sophus;            // (Gotcha #33) clashes with Eigen's Matrix
+ using SE3 = Sophus::SE3d;          // legacy short name, no namespace pollution
```

Then a global rename for Sophus 1.22 method casing (Gotcha #32):

```bash
sed -i 's/\.rotation_matrix()/\.rotationMatrix()/g' \
  src/FAST-LIVO2_ROS2/{src,include}/**/*.{cpp,h}
```

This single block of changes unblocks **`vio.cpp`, `frame.cpp`,
`visual_point.cpp`, `feature.h`** simultaneously (they all use `SE3`
unqualified).

---

## Phase 4: Headers and message types — `voxel_map.h`, `IMU_Processing.{h,cpp}`, `preprocess.{h,cpp}`

Mostly mechanical — `helpers/rewrite_headers.sh` covers most of this. The
manual residue:

| File | What |
|---|---|
| `voxel_map.h` | `tf2_geometry_msgs/tf2_geometry_msgs.h` → `.hpp` (Humble warns about old name); already had `visualization_msgs/msg/marker.hpp` correct, just missing `<depend>` in package.xml. |
| `preprocess.{h,cpp}` | `livox_ros_driver/CustomMsg.h` → `livox_ros_driver2/msg/custom_msg.hpp`; `sensor_msgs::PointCloud2::ConstPtr` → `sensor_msgs::msg::PointCloud2::ConstSharedPtr`; `ros::Time` → `rclcpp::Time`; `stamp.toSec()` → `rclcpp::Time(stamp).seconds()`. |
| `IMU_Processing.h` | `<nav_msgs/Odometry.h>` → `<nav_msgs/msg/odometry.hpp>`; `sensor_msgs::ImuConstPtr` → `sensor_msgs::msg::Imu::ConstSharedPtr`; add `<fstream>` (header was relying on transitive include from `<nav_msgs/Odometry.h>`). |
| `IMU_Processing.cpp` | `ROS_ASSERT` → `assert` (Gotcha #36); `ROS_INFO/WARN/ERROR` → `RCLCPP_*(rclcpp::get_logger("imu_proc"), ...)`. |

### Bulk message-type rewrite — Python helper

```python
import re
replacements = [
    ('sensor_msgs::Imu::ConstPtr', 'sensor_msgs::msg::Imu::ConstSharedPtr'),
    ('sensor_msgs::Imu::Ptr',      'sensor_msgs::msg::Imu::SharedPtr'),
    ('sensor_msgs::Imu',           'sensor_msgs::msg::Imu'),
    ('sensor_msgs::PointCloud2::ConstPtr',
                                   'sensor_msgs::msg::PointCloud2::ConstSharedPtr'),
    ('sensor_msgs::PointCloud2',   'sensor_msgs::msg::PointCloud2'),
    ('sensor_msgs::ImageConstPtr', 'sensor_msgs::msg::Image::ConstSharedPtr'),
    ('sensor_msgs::Image::Ptr',    'sensor_msgs::msg::Image::SharedPtr'),
    ('sensor_msgs::Image',         'sensor_msgs::msg::Image'),
    ('nav_msgs::Path',             'nav_msgs::msg::Path'),
    ('nav_msgs::Odometry',         'nav_msgs::msg::Odometry'),
    ('geometry_msgs::PoseStamped', 'geometry_msgs::msg::PoseStamped'),
    ('geometry_msgs::Quaternion',  'geometry_msgs::msg::Quaternion'),
    ('visualization_msgs::Marker',      'visualization_msgs::msg::Marker'),
    ('visualization_msgs::MarkerArray', 'visualization_msgs::msg::MarkerArray'),
    ('livox_ros_driver::CustomMsg::ConstPtr',
                                   'livox_ros_driver2::msg::CustomMsg::ConstSharedPtr'),
    ('livox_ros_driver::CustomMsg::Ptr',
                                   'livox_ros_driver2::msg::CustomMsg::SharedPtr'),
    ('livox_ros_driver::CustomMsg', 'livox_ros_driver2::msg::CustomMsg'),
]
for f in target_files:
    s = open(f).read()
    for old, new in replacements:
        s = re.sub(re.escape(old) + r'(?!\w)', new, s)
    s = re.sub(r'msg::msg::', 'msg::', s)            # collapse double-replace
    open(f, 'w').write(s)
```

The `(?!\w)` guard prevents `sensor_msgs::Image` from also matching
`sensor_msgs::ImageConstPtr` after `Imu` was already done.

The `s/msg::msg::/msg::/` cleanup catches cases where a longer
replacement (`Imu::ConstPtr` → `msg::Imu::ConstSharedPtr`) and a shorter one
(`Imu` → `msg::Imu`) cascade in the same file.

---

## Phase 5: The big one — `LIVMapper.cpp/h`

119 ROS1-API sites. Approach: split into **batch sed-able patterns** vs.
**one-off careful edits**.

### Class data members and signatures (one-off)

```diff
- LIVMapper(ros::NodeHandle &nh);
- void initializeSubscribersAndPublishers(ros::NodeHandle &nh, image_transport::ImageTransport &it);
- void readParameters(ros::NodeHandle &nh);
+ LIVMapper(rclcpp::Node::SharedPtr node);
+ void initializeSubscribersAndPublishers(rclcpp::Node::SharedPtr node, image_transport::ImageTransport &it);
+ void readParameters(rclcpp::Node::SharedPtr node);

- ros::Publisher pubLaserCloudFullRes;        // ×8
- ros::Subscriber sub_pcl, sub_imu, sub_img;
- ros::Timer imu_prop_timer;
- image_transport::Publisher pubImage;        // unchanged
+ rclcpp::Publisher<sensor_msgs::msg::PointCloud2>::SharedPtr pubLaserCloudFullRes;   // ×n with the right MsgType
+ rclcpp::SubscriptionBase::SharedPtr sub_pcl;     // type unknown until lidar_type read
+ rclcpp::Subscription<sensor_msgs::msg::Imu>::SharedPtr sub_imu;
+ rclcpp::Subscription<sensor_msgs::msg::Image>::SharedPtr sub_img;
+ rclcpp::TimerBase::SharedPtr imu_prop_timer;
+ rclcpp::Node::SharedPtr node_;               // store for later use
```

### `nh.param` ⇒ `declare_parameter` (programmatic)

47 occurrences in `readParameters`. The slash-to-dot conversion is
mandatory (Gotcha #3):

```python
import re, pathlib
src = pathlib.Path('LIVMapper.cpp').read_text()

def repl(m):
    typ, name, var, dflt = m.group(1), m.group(2).replace('/','.'), m.group(3), m.group(4).strip()
    return f'{var} = node->declare_parameter<{typ}>("{name}", {dflt});'

# Match nh.param<TYPE>("name", var, default);
pat = re.compile(r'nh\.param<([^>]+(?:<[^>]*>)?)>\(\s*"([^"]+)"\s*,\s*([^,]+?)\s*,\s*([^)]+)\)\s*;')
src = pat.sub(repl, src)
pathlib.Path('LIVMapper.cpp').write_text(src)
```

The `(?:<[^>]*>)?` allows `vector<double>` types without breaking on the
embedded `<>`.

For `vector<double>` overloads sed/regex won't reach them — patch by hand:

```cpp
extrinT = node->declare_parameter<std::vector<double>>("extrin_calib.extrinsic_T", std::vector<double>(3, 0.0));
extrinR = node->declare_parameter<std::vector<double>>("extrin_calib.extrinsic_R", std::vector<double>(9, 0.0));
```

### Pub/sub creation, executor, timer (block rewrite)

```diff
- sub_pcl = p_pre->lidar_type == AVIA ?
-           nh.subscribe(lid_topic, 200000, &LIVMapper::livox_pcl_cbk, this):
-           nh.subscribe(lid_topic, 200000, &LIVMapper::standard_pcl_cbk, this);
- sub_imu = nh.subscribe(imu_topic, 200000, &LIVMapper::imu_cbk, this);
- sub_img = nh.subscribe(img_topic, 200000, &LIVMapper::img_cbk, this);
- pubLaserCloudFullRes = nh.advertise<sensor_msgs::PointCloud2>("/cloud_registered", 100);
- ...
- pubImage = it.advertise("/rgb_img", 1);
- imu_prop_timer = nh.createTimer(ros::Duration(0.004), &LIVMapper::imu_prop_callback, this);
+ using std::placeholders::_1;
+ rclcpp::QoS sensor_qos(rclcpp::KeepLast(200000));
+ sensor_qos.best_effort();
+ if (p_pre->lidar_type == AVIA) {
+   sub_pcl = node->create_subscription<livox_ros_driver2::msg::CustomMsg>(
+       lid_topic, sensor_qos, std::bind(&LIVMapper::livox_pcl_cbk, this, _1));
+ } else {
+   sub_pcl = node->create_subscription<sensor_msgs::msg::PointCloud2>(
+       lid_topic, sensor_qos, std::bind(&LIVMapper::standard_pcl_cbk, this, _1));
+ }
+ sub_imu = node->create_subscription<sensor_msgs::msg::Imu>(
+     imu_topic, sensor_qos, std::bind(&LIVMapper::imu_cbk, this, _1));
+ sub_img = node->create_subscription<sensor_msgs::msg::Image>(
+     img_topic, sensor_qos, std::bind(&LIVMapper::img_cbk, this, _1));
+ pubLaserCloudFullRes = node->create_publisher<sensor_msgs::msg::PointCloud2>("/cloud_registered", 100);
+ ...
+ pubImage = it.advertise("/rgb_img", 1);
+ imu_prop_timer = node->create_wall_timer(std::chrono::microseconds(4000),
+     std::bind(&LIVMapper::imu_prop_callback, this));
```

Note `imu_prop_callback` no longer takes `const ros::TimerEvent&` — the
ROS2 timer callback is `void()` (or `void(void)`).

### Spin loop

```diff
- ros::Rate rate(5000);
- while (ros::ok()) {
-   ros::spinOnce();
+ rclcpp::Rate rate(5000);
+ rclcpp::executors::SingleThreadedExecutor exec;
+ exec.add_node(node_);
+ while (rclcpp::ok()) {
+   exec.spin_some();
    if (!sync_packages(LidarMeasures)) { rate.sleep(); continue; }
    ...
  }
```

### Logging macros (sed-able)

```bash
sed -i \
  -e 's|ros::Time::now()|node_->now()|g' \
  -e 's|ROS_ERROR(|RCLCPP_ERROR(node_->get_logger(), |g' \
  -e 's|ROS_WARN(|RCLCPP_WARN(node_->get_logger(), |g' \
  -e 's|ROS_INFO(|RCLCPP_INFO(node_->get_logger(), |g' \
  -e 's|ROS_DEBUG(|RCLCPP_DEBUG(node_->get_logger(), |g' \
  src/FAST-LIVO2_ROS2/src/LIVMapper.cpp
```

### Stamp arithmetic (`.toSec()` and integer-ns round-trip — Gotcha #39)

```diff
- if (msg->header.stamp.toSec() < last_timestamp_lidar) ...
+ const double stamp = rclcpp::Time(msg->header.stamp).seconds();
+ if (stamp < last_timestamp_lidar) ...

- msg->header.stamp = ros::Time().fromSec(timestamp);
+ {
+   int64_t s  = static_cast<int64_t>(std::floor(timestamp));
+   int64_t ns = static_cast<int64_t>(std::round((timestamp - s) * 1e9));
+   msg->header.stamp = rclcpp::Time(s, ns);
+ }
```

### TF broadcast (Gotcha #37)

```diff
- static tf::TransformBroadcaster br;
- tf::Transform transform;
- tf::Quaternion q;
- transform.setOrigin(tf::Vector3(_state.pos_end(0), _state.pos_end(1), _state.pos_end(2)));
- q.setW(geoQuat.w); q.setX(geoQuat.x); q.setY(geoQuat.y); q.setZ(geoQuat.z);
- transform.setRotation(q);
- br.sendTransform(tf::StampedTransform(transform, odomAftMapped.header.stamp, "camera_init", "aft_mapped"));
+ static auto br = std::make_shared<tf2_ros::TransformBroadcaster>(node_);
+ geometry_msgs::msg::TransformStamped transform;
+ transform.header.stamp = odomAftMapped.header.stamp;
+ transform.header.frame_id = "camera_init";
+ transform.child_frame_id  = "aft_mapped";
+ transform.transform.translation.x = _state.pos_end(0);
+ transform.transform.translation.y = _state.pos_end(1);
+ transform.transform.translation.z = _state.pos_end(2);
+ transform.transform.rotation = geoQuat;        // already geometry_msgs::msg::Quaternion
+ br->sendTransform(transform);
```

And the RPY → quaternion helper (Gotcha #37 / API_MAPPING §7):

```diff
- geoQuat = tf::createQuaternionMsgFromRollPitchYaw(roll, pitch, yaw);
+ {
+   tf2::Quaternion q_tf;
+   q_tf.setRPY(roll, pitch, yaw);
+   geoQuat.x = q_tf.x();
+   geoQuat.y = q_tf.y();
+   geoQuat.z = q_tf.z();
+   geoQuat.w = q_tf.w();
+ }
```

### `main.cpp`

```cpp
#include "LIVMapper.h"
#include <rclcpp/rclcpp.hpp>

int main(int argc, char **argv) {
  rclcpp::init(argc, argv);
  auto node = std::make_shared<rclcpp::Node>("laserMapping");
  image_transport::ImageTransport it(node);
  LIVMapper mapper(node);
  mapper.initializeSubscribersAndPublishers(node, it);
  mapper.run();
  rclcpp::shutdown();
  return 0;
}
```

---

## Phase 6: Build

```bash
source /opt/ros/humble/setup.bash
source ~/driver_ws/install/setup.bash         # provides livox_ros_driver2
colcon build --packages-up-to fast_livo
```

Or, if `livox_ros_driver2` is in the same workspace:

```bash
source /opt/ros/humble/setup.bash
colcon build --packages-up-to fast_livo
```

Beware Gotcha #38: `colcon build --packages-select fast_livo` alone will
fail with `livox_ros_driver2/msg/custom_msg.hpp: No such file or directory`
unless you've sourced the workspace overlay first.

---

## Phase 7: Verify (deferred)

The compile passes. **Runtime validation is a separate effort** that this
worked example does not cover:

- The launch file `mapping_avia.launch` is ROS1 XML — needs a `.launch.py`
  rewrite (see `templates/launch.py`).
- Camera params yaml (`config/camera_pinhole.yaml`) uses top-level keys
  (`cam_model:`, `cam_fx:`); pass them through launch with no prefix
  (`{'cam_model': 'Pinhole', ...}`) since `loadFromRosNs` is called with
  empty namespace.
- Bag replay needs `qos:=2` (BEST_EFFORT) or matching reliability on the
  publisher side; the converted code uses `sensor_qos.best_effort()` for
  pcl/imu/image subs already.
- Sim-time (Gotcha #27): set `use_sim_time:=true` for bag replay.

---

## Lessons (replayable on the next half-ported fork)

1. **Audit before estimating.** A `*_ROS2` repo name is not evidence; only
   `grep -r ros::NodeHandle` is (Gotcha #31).
2. **Port the satellite library yourself.** `rpg_vikit` / `svo_common` /
   similar are recurring blockers. The recipe (header-only ament_cmake,
   drop ROS1-only translation units) is reusable.
3. **Fix Sophus first.** A single `using SE3 = Sophus::SE3d;` plus
   removing `using namespace Sophus` plus `s/rotation_matrix/rotationMatrix/`
   unblocks 5–10 source files at once.
4. **Bulk-translate by pattern, hand-port the structural bits.** `nh.param`,
   message types, log macros, `.toSec()` are Python/sed-replaceable.
   Pub/sub creation, timer callbacks, executor wiring, and TF broadcast
   need careful edits.
5. **Distinguish "compiles" from "runs".** Tell the user explicitly when
   you've only achieved compile-clean; runtime validation is a separate
   workitem.
6. **Use `--packages-up-to` for clean reproducible builds.** Avoids the
   "did I source the overlay?" footgun.

---

## File-change count (FAST-LIVO2_ROS2 May-2026 baseline)

| File | New LoC / changes |
|---|---|
| `rpg_vikit/vikit_common/{package.xml,CMakeLists.txt}` | rewritten |
| `rpg_vikit/vikit_common/include/vikit/{abstract,pinhole}_camera.h` | +virtuals + scale_ |
| `rpg_vikit/vikit_common/include/vikit/math_utils.h` | sophus + Matrix |
| `rpg_vikit/vikit_common/src/pinhole_camera.cpp` | OpenCV 4 const |
| `rpg_vikit/vikit_ros/{package.xml,CMakeLists.txt}` | rewritten (header-only) |
| `rpg_vikit/vikit_ros/include/vikit/{camera_loader,params_helper}.h` | rewritten for rclcpp |
| `FAST-LIVO2_ROS2/include/common_lib.h` | Sophus typedef |
| `FAST-LIVO2_ROS2/src/vio.cpp` | rotation_matrix → rotationMatrix (12 sites) |
| `FAST-LIVO2_ROS2/include/voxel_map.h` | tf2_geometry_msgs.hpp |
| `FAST-LIVO2_ROS2/{include,src}/preprocess.{h,cpp}` | livox_ros_driver2, msg types, toSec |
| `FAST-LIVO2_ROS2/{include,src}/IMU_Processing.{h,cpp}` | nav_msgs.hpp, RCLCPP, ROS_ASSERT |
| `FAST-LIVO2_ROS2/include/LIVMapper.h` | declarations rewritten |
| `FAST-LIVO2_ROS2/src/LIVMapper.cpp` | ~119 sites, see Phase 5 |
| `FAST-LIVO2_ROS2/src/main.cpp` | rewritten (12 lines) |
| `FAST-LIVO2_ROS2/package.xml` | +visualization_msgs, +nav_msgs, +geometry_msgs, +cv_bridge, +image_transport, +livox_ros_driver2, +pcl_conversions |

Total: ~16 files, ~200 manual edits + 47 `nh.param` rewrites + 12 sites of
sed-able log macros + 14 sites of message-type bulk replace.

---

**Time spent**: ~3–4 hours of focused work for compile-clean. Runtime
validation pending.
