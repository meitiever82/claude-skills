# ROS2 Migration PR Checklist

> Copy this checklist into the PR description. Every box should be either checked or
> explicitly explained ("N/A — single-threaded node" / etc.).

---

## Build & test

- [ ] `colcon build --packages-select <pkg>` succeeds with no new warnings.
- [ ] `colcon test --packages-select <pkg>` passes (or matches ROS1 baseline).
- [ ] `verification/smoke_test.sh` exits cleanly.
- [ ] `verification/deprecation_grep.sh` returns 0 hits.

## Source

- [ ] No `<ros/ros.h>`, no `roscpp` references in source.
- [ ] All message includes use `<pkg/msg/snake_case.hpp>` form.
- [ ] All ROS message types qualify with `::msg::`, services `::srv::`, actions `::action::`.
- [ ] `ros::Time::now()` replaced with `node->now()` or equivalent.
- [ ] `ROS_INFO`/`ROS_WARN`/`ROS_ERROR` replaced with `RCLCPP_*` macros.
- [ ] `tf::*` replaced with `tf2::*` / `tf2_ros::*`.
- [ ] `boost::shared_ptr` replaced with `std::shared_ptr`.

## Build files

- [ ] `package.xml` is format 3 with `<buildtool_depend>ament_cmake</buildtool_depend>`.
- [ ] `CMakeLists.txt` uses `find_package(ament_cmake REQUIRED)` and ends with
      `ament_package()`.
- [ ] Per-dependency `find_package` calls present (no monolithic `catkin REQUIRED COMPONENTS`).
- [ ] `install(DIRECTORY launch config rviz ...)` present (so `ros2 launch` finds files).

## Parameters

- [ ] Every `n.param<T>(...)` has a corresponding `declare_parameter` and `get_parameter`.
- [ ] Parameter names use `.` for nesting, not `/`.
- [ ] YAML files scoped under `<node_name>: ros__parameters:` (or `/**:`).
- [ ] Integer arrays in YAML widened to doubles where the parameter is `vector<double>`.

## QoS

- [ ] Sensor topics (IMU/LiDAR/camera) use `SensorDataQoS` or an explicitly justified
      alternative.
- [ ] "Latched" ROS1 topics are now `transient_local` on **both** publisher and subscriber.
- [ ] Topic frequencies under load match the ROS1 baseline within ±5 %.

## Threading

- [ ] Executor model documented in code or in the PR description.
- [ ] If using `MultiThreadedExecutor`: callback groups assigned where shared state is
      touched.
- [ ] No deadlocks observed under bag-replay smoke test.

## Launch

- [ ] All `.launch` (XML) ports translated to `.launch.py` (or `.launch.xml` / `.launch.yaml`
      if explicitly preferred).
- [ ] `IfCondition`/`UnlessCondition` correctly map ROS1 `if=`/`unless=` attrs.
- [ ] Topic remappings translated to `remappings=[...]`.
- [ ] `use_sim_time` argument plumbed through if the node consumes `/clock`.

## Documentation

- [ ] README install section updated with `colcon build` instructions.
- [ ] CONTRIBUTING / CI updated.
- [ ] `MIGRATION_PLAN.md` decisions log complete.
- [ ] Behavioural changes documented (especially QoS choices, parameter renames).

## Cleanup

- [ ] `package.xml.bak`, `CMakeLists.txt.user`, `*.launch` (XML) removed.
- [ ] `// TODO ROS2` markers in code reduced to zero (or explicitly listed as out-of-scope).

---

## Out-of-scope (note here, do not merge as resolved)

- [ ] RViz1 plugins not yet ported (link to follow-up issue).
- [ ] dynamic_reconfigure GUI replaced with rqt_reconfigure (works automatically).
- [ ] `actionlib` clients/servers — link to follow-up if not done.
