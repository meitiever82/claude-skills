# ROS1 ↔ ROS2 (Humble) API Mapping Cheat-Sheet

Side-by-side mapping for the 80% of ROS1 code most projects need to migrate. For each section
the **left** column is ROS1 (Noetic), the **right** column is ROS2 (Humble).

> Convention: `n` is a ROS1 `ros::NodeHandle`. `node` is a `std::shared_ptr<rclcpp::Node>` or
> `this` from inside a class deriving from `rclcpp::Node`.

---

## §1. Headers

```cpp
// ROS1
#include <ros/ros.h>
#include <ros/console.h>
#include <std_msgs/Header.h>
#include <sensor_msgs/Imu.h>
#include <geometry_msgs/PoseStamped.h>
#include <nav_msgs/Odometry.h>
#include <my_pkg/AddTwoInts.h>           // service
#include <my_pkg/FooAction.h>            // action

// ROS2 (Humble)
#include <rclcpp/rclcpp.hpp>
// (no separate console header)
#include <std_msgs/msg/header.hpp>
#include <sensor_msgs/msg/imu.hpp>
#include <geometry_msgs/msg/pose_stamped.hpp>
#include <nav_msgs/msg/odometry.hpp>
#include <my_pkg/srv/add_two_ints.hpp>
#include <my_pkg/action/foo.hpp>
```

---

## §2. Node Bootstrap

```cpp
// ROS1
int main(int argc, char ** argv) {
  ros::init(argc, argv, "my_node");
  ros::NodeHandle n;
  ros::NodeHandle pn("~");
  // ... construct
  ros::spin();
  return 0;
}

// ROS2
class MyNode : public rclcpp::Node {
public:
  MyNode() : rclcpp::Node("my_node") {
    // construct pubs / subs / params here
  }
};
int main(int argc, char ** argv) {
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<MyNode>());
  rclcpp::shutdown();
  return 0;
}
```

The two `NodeHandle`s collapse into one `rclcpp::Node`. Where ROS1 used the private
namespace `~/`, ROS2 just uses the parameter name as declared (no special prefix).

---

## §3. Publishers and Subscribers

```cpp
// ROS1
ros::Publisher  pub = n.advertise<sensor_msgs::Imu>("imu/data", 100);
ros::Subscriber sub = n.subscribe("imu/raw", 100, &Cls::cb, this);
//                            ↑     ↑
//                          topic queue

void Cls::cb(const sensor_msgs::Imu::ConstPtr & msg) { ... }

// ROS2
auto pub = node->create_publisher<sensor_msgs::msg::Imu>("imu/data", rclcpp::QoS(100));
auto sub = node->create_subscription<sensor_msgs::msg::Imu>(
  "imu/raw", rclcpp::QoS(100),
  std::bind(&Cls::cb, this, std::placeholders::_1));

void Cls::cb(sensor_msgs::msg::Imu::SharedPtr msg) { ... }
// or:
void Cls::cb(const sensor_msgs::msg::Imu & msg) { ... }     // Humble-friendly value form
```

### QoS shortcuts

```cpp
rclcpp::QoS(10)                       // depth 10, default reliability/durability
rclcpp::SystemDefaultsQoS()           // DDS defaults
rclcpp::SensorDataQoS()               // best-effort, depth 5  (use for IMU/LiDAR/Camera)
rclcpp::ServicesQoS()                 // for service comms
rclcpp::ParametersQoS()               // for parameter services
rclcpp::QoS(1).transient_local()      // ROS1's "latched" approximation
```

---

## §4. Parameters

```cpp
// ROS1
double cov_gyr;
n.param<double>("Odometry/cov_gyr", cov_gyr, 0.1);
std::vector<double> arr;
n.param<std::vector<double>>("LocalBA/eigen_thre", arr, std::vector<double>{1,1,1,1});

// ROS2 (declare once, then get)
this->declare_parameter<double>("Odometry.cov_gyr", 0.1);
double cov_gyr = this->get_parameter("Odometry.cov_gyr").as_double();

this->declare_parameter<std::vector<double>>("LocalBA.eigen_thre",
                                             std::vector<double>{1.0,1.0,1.0,1.0});
auto arr = this->get_parameter("LocalBA.eigen_thre").as_double_array();
```

### Parameter type accessors

| Type | ROS1 | ROS2 |
|---|---|---|
| `bool` | `n.param<bool>(...)` | `.as_bool()` |
| `int` | `n.param<int>(...)` | `.as_int()` |
| `double` | `n.param<double>(...)` | `.as_double()` |
| `std::string` | `n.param<std::string>(...)` | `.as_string()` |
| `std::vector<double>` | `n.param<std::vector<double>>(...)` | `.as_double_array()` |
| `std::vector<std::string>` | same | `.as_string_array()` |
| `std::vector<int>` | same | `.as_integer_array()` |

### Runtime parameter changes (replaces `dynamic_reconfigure`)

```cpp
// ROS2 only
auto on_set_param_cb_ = node->add_on_set_parameters_callback(
  [this](const std::vector<rclcpp::Parameter> & params) {
    rcl_interfaces::msg::SetParametersResult result;
    result.successful = true;
    for (const auto & p : params) {
      if      (p.get_name() == "Odometry.cov_gyr") cov_gyr_ = p.as_double();
      else if (p.get_name() == "verbose")          verbose_ = p.as_bool();
    }
    return result;
});
```

Trigger from CLI: `ros2 param set /my_node Odometry.cov_gyr 0.5`.

---

## §5. Time, Duration, Rate, Timers

```cpp
// ROS1
ros::Time t  = ros::Time::now();
double sec   = t.toSec();
ros::Duration d(0.5);                    // 500 ms
ros::Rate r(50.0);
r.sleep();

ros::Timer tm = n.createTimer(ros::Duration(0.02),
                              &Cls::tick, this);

// ROS2
rclcpp::Time     t  = node->now();        // or node->get_clock()->now()
double sec       = t.seconds();
rclcpp::Duration d(std::chrono::milliseconds(500));
rclcpp::Rate     r(50.0);
r.sleep();                                // works, but timers are more idiomatic

auto tm = node->create_wall_timer(
  std::chrono::milliseconds(20),
  std::bind(&Cls::tick, this));
```

### Adding/subtracting time

```cpp
// ROS1
ros::Time end = ros::Time::now() + ros::Duration(0.1);
double dt = (end - ros::Time::now()).toSec();

// ROS2
rclcpp::Time end = node->now() + rclcpp::Duration::from_seconds(0.1);
double dt = (end - node->now()).seconds();
```

### Sim-time

```cpp
// ROS2 — opt in
this->declare_parameter<bool>("use_sim_time", false);
// or in launch: parameters=[{'use_sim_time': True}]
```

---

## §6. Logging

```cpp
// ROS1
ROS_INFO("v=%f", v);
ROS_INFO_STREAM("got " << x);
ROS_DEBUG("%s", s);
ROS_WARN_THROTTLE(1.0, "still bad");        // 1.0 seconds
ROS_ERROR("failed: %s", e.what());

// ROS2
RCLCPP_INFO(this->get_logger(), "v=%f", v);
RCLCPP_INFO_STREAM(this->get_logger(), "got " << x);
RCLCPP_DEBUG(this->get_logger(), "%s", s);
RCLCPP_WARN_THROTTLE(this->get_logger(), *this->get_clock(), 1000, "still bad");  // ms now
RCLCPP_ERROR(this->get_logger(), "failed: %s", e.what());
```

Log level at runtime:
```bash
ros2 run my_pkg my_node --ros-args --log-level debug
ros2 run my_pkg my_node --ros-args --log-level my_node:=debug
```

---

## §7. TF (broadcast + listen)

```cpp
// ROS1 — broadcast
#include <tf/transform_broadcaster.h>
tf::TransformBroadcaster br;
tf::Transform t;
t.setOrigin(tf::Vector3(x, y, z));
tf::Quaternion q; q.setRPY(0, 0, yaw);
t.setRotation(q);
br.sendTransform(tf::StampedTransform(t, ros::Time::now(), "world", "base"));

// ROS2 — broadcast
#include <tf2_ros/transform_broadcaster.h>
#include <geometry_msgs/msg/transform_stamped.hpp>
class MyNode : public rclcpp::Node {
  tf2_ros::TransformBroadcaster br_{*this};
  void send() {
    geometry_msgs::msg::TransformStamped ts;
    ts.header.stamp = this->now();
    ts.header.frame_id = "world";
    ts.child_frame_id  = "base";
    ts.transform.translation.x = x;
    ts.transform.translation.y = y;
    ts.transform.translation.z = z;
    tf2::Quaternion q; q.setRPY(0, 0, yaw);
    ts.transform.rotation = tf2::toMsg(q);
    br_.sendTransform(ts);
  }
};
```

```cpp
// ROS1 — listen
#include <tf/transform_listener.h>
tf::TransformListener listener;
tf::StampedTransform t;
listener.lookupTransform("world", "base", ros::Time(0), t);

// ROS2 — listen
#include <tf2_ros/buffer.h>
#include <tf2_ros/transform_listener.h>
auto buf = std::make_shared<tf2_ros::Buffer>(this->get_clock());
auto lst = std::make_shared<tf2_ros::TransformListener>(*buf, this);
auto t = buf->lookupTransform("world", "base", tf2::TimePointZero);
```

### Conversions

```cpp
#include <tf2_geometry_msgs/tf2_geometry_msgs.hpp>      // Pose, Quaternion, etc.
#include <tf2_eigen/tf2_eigen.hpp>                       // Eigen ↔ tf2

geometry_msgs::msg::Pose msg = tf2::toMsg(eigen_iso);
tf2::Quaternion q; tf2::fromMsg(msg.orientation, q);
```

---

## §8. Services

```cpp
// ROS1 — server
bool cb(my_pkg::AddTwoInts::Request & req, my_pkg::AddTwoInts::Response & res) {
  res.sum = req.a + req.b;
  return true;
}
ros::ServiceServer s = n.advertiseService("add", cb);

// ROS2 — server
auto s = node->create_service<my_pkg::srv::AddTwoInts>(
  "add",
  [](const std::shared_ptr<my_pkg::srv::AddTwoInts::Request> req,
     std::shared_ptr<my_pkg::srv::AddTwoInts::Response> res) {
       res->sum = req->a + req->b;
  });
```

```cpp
// ROS1 — client
ros::ServiceClient c = n.serviceClient<my_pkg::AddTwoInts>("add");
my_pkg::AddTwoInts srv;
srv.request.a = 1; srv.request.b = 2;
c.call(srv);                              // synchronous
int r = srv.response.sum;

// ROS2 — client (asynchronous)
auto c = node->create_client<my_pkg::srv::AddTwoInts>("add");
auto req = std::make_shared<my_pkg::srv::AddTwoInts::Request>();
req->a = 1; req->b = 2;
c->wait_for_service(2s);
auto fut = c->async_send_request(req);
if (rclcpp::spin_until_future_complete(node, fut) == rclcpp::FutureReturnCode::SUCCESS) {
  int r = fut.get()->sum;
}
```

---

## §9. Actions

```cpp
// ROS1 (actionlib) — client
#include <actionlib/client/simple_action_client.h>
actionlib::SimpleActionClient<my_pkg::FooAction> ac("foo", true);
ac.waitForServer();
my_pkg::FooGoal g; g.target = 42;
ac.sendGoal(g);
ac.waitForResult();
int r = ac.getResult()->result_value;

// ROS2 (rclcpp_action) — client (async)
#include <rclcpp_action/rclcpp_action.hpp>
auto ac = rclcpp_action::create_client<my_pkg::action::Foo>(node, "foo");
ac->wait_for_action_server(2s);
my_pkg::action::Foo::Goal g; g.target = 42;
auto opts = rclcpp_action::Client<my_pkg::action::Foo>::SendGoalOptions();
opts.feedback_callback = [](auto, auto fb){ /* ... */ };
opts.result_callback   = [](const auto & wrapped){
  if (wrapped.code == rclcpp_action::ResultCode::SUCCEEDED) {
    int r = wrapped.result->result_value;
  }
};
auto goal_future = ac->async_send_goal(g, opts);
```

Server side: see `rclcpp_action::create_server<T>(node, "foo", goal_cb, cancel_cb, accepted_cb)`.

---

## §10. message_filters

```cpp
// ROS1
#include <message_filters/subscriber.h>
#include <message_filters/sync_policies/approximate_time.h>
message_filters::Subscriber<sensor_msgs::Imu>          imu_sub(n, "imu", 10);
message_filters::Subscriber<sensor_msgs::PointCloud2>  pcl_sub(n, "lidar", 10);
typedef message_filters::sync_policies::ApproximateTime<
    sensor_msgs::Imu, sensor_msgs::PointCloud2> Sync;
message_filters::Synchronizer<Sync> sync(Sync(10), imu_sub, pcl_sub);
sync.registerCallback(&Cls::cb, this);

// ROS2 — pass node pointer, not nh + queue
#include <message_filters/subscriber.h>
#include <message_filters/synchronizer.h>
#include <message_filters/sync_policies/approximate_time.h>
message_filters::Subscriber<sensor_msgs::msg::Imu>          imu_sub(this, "imu");
message_filters::Subscriber<sensor_msgs::msg::PointCloud2>  pcl_sub(this, "lidar");
typedef message_filters::sync_policies::ApproximateTime<
    sensor_msgs::msg::Imu, sensor_msgs::msg::PointCloud2> Sync;
message_filters::Synchronizer<Sync> sync(Sync(10), imu_sub, pcl_sub);
sync.registerCallback(std::bind(&Cls::cb, this,
                                std::placeholders::_1, std::placeholders::_2));
```

---

## §11. rospy → rclpy

```python
# ROS1
import rospy
from sensor_msgs.msg import Imu
def cb(msg): rospy.loginfo(msg.linear_acceleration.x)
rospy.init_node('my_node')
rospy.Subscriber('imu', Imu, cb, queue_size=10)
rospy.spin()

# ROS2
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import Imu
class MyNode(Node):
    def __init__(self):
        super().__init__('my_node')
        self.create_subscription(Imu, 'imu', self.cb, 10)
    def cb(self, msg):
        self.get_logger().info(f'{msg.linear_acceleration.x}')
def main():
    rclpy.init()
    rclpy.spin(MyNode())
    rclpy.shutdown()
```

| Concept | ROS1 (rospy) | ROS2 (rclpy) |
|---|---|---|
| init | `rospy.init_node('n')` | `rclpy.init(); n = MyNode()` |
| publisher | `rospy.Publisher(...)` | `n.create_publisher(...)` |
| subscriber | `rospy.Subscriber(...)` | `n.create_subscription(...)` |
| spin | `rospy.spin()` | `rclpy.spin(n)` |
| logger | `rospy.loginfo(...)` | `n.get_logger().info(...)` |
| param | `rospy.get_param('~p', d)` | `n.declare_parameter('p', d); n.get_parameter('p').value` |
| time | `rospy.Time.now()` | `n.get_clock().now()` |
| rate | `rospy.Rate(50)` | `n.create_rate(50)` |

Build system for Python: `ament_python` (uses `setup.py`) or `ament_cmake_python` (mixed with C++).

---

## §12. Build files

### `package.xml` v2 → v3

```xml
<!-- ROS1 (format 2) -->
<package format="2">
  <name>my_pkg</name>
  <version>1.0.0</version>
  <description>...</description>
  <maintainer email="x@y">x</maintainer>
  <license>BSD</license>
  <buildtool_depend>catkin</buildtool_depend>
  <depend>roscpp</depend>
  <depend>std_msgs</depend>
  <depend>tf</depend>
</package>

<!-- ROS2 (format 3) -->
<package format="3">
  <name>my_pkg</name>
  <version>1.0.0</version>
  <description>...</description>
  <maintainer email="x@y">x</maintainer>
  <license>BSD</license>
  <buildtool_depend>ament_cmake</buildtool_depend>
  <depend>rclcpp</depend>
  <depend>std_msgs</depend>
  <depend>tf2_ros</depend>
  <depend>tf2_geometry_msgs</depend>
  <export>
    <build_type>ament_cmake</build_type>
  </export>
</package>
```

| ROS1 dep | ROS2 dep |
|---|---|
| `roscpp` | `rclcpp` |
| `rospy` | `rclpy` |
| `roslib` | `ament_index_cpp` (C++) / `ament_index_python` (Python) |
| `nodelet` | `rclcpp_components` |
| `tf` | `tf2`, `tf2_ros`, `tf2_geometry_msgs` (or `tf2_eigen`) |
| `actionlib` | `rclcpp_action` |
| `actionlib_msgs` | `action_msgs` |
| `dynamic_reconfigure` | (no replacement — see §4) |
| `pluginlib` | `pluginlib` (same name, different macros — see Gotcha #23) |
| `rosbag` | `rosbag2_cpp` |
| `pcl_ros` | `pcl_conversions` (and PCL directly) |
| `cv_bridge` | `cv_bridge` (works in ROS2) |
| `image_transport` | `image_transport` (works in ROS2) |

### `CMakeLists.txt` template

```cmake
cmake_minimum_required(VERSION 3.8)
project(my_pkg)

if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
endif()
if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

# Find ament + every dependency individually
find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(std_msgs REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(geometry_msgs REQUIRED)
find_package(nav_msgs REQUIRED)
find_package(tf2_ros REQUIRED)
find_package(tf2_geometry_msgs REQUIRED)
find_package(PCL 1.10 REQUIRED COMPONENTS common io)
find_package(Eigen3 3.3 REQUIRED NO_MODULE)

# (For message generation, see §13.)

add_executable(my_node src/my_node.cpp)
ament_target_dependencies(my_node
  rclcpp std_msgs sensor_msgs geometry_msgs nav_msgs
  tf2_ros tf2_geometry_msgs)
target_link_libraries(my_node ${PCL_LIBRARIES} Eigen3::Eigen)

# Install rules
install(TARGETS my_node DESTINATION lib/${PROJECT_NAME})
install(DIRECTORY launch config rviz DESTINATION share/${PROJECT_NAME})

# (For tests, see §14.)

ament_package()
```

---

## §13. Message generation (interface packages)

If your package contains `msg/`, `srv/`, or `action/` files:

```cmake
# CMakeLists.txt of the *interface* package
cmake_minimum_required(VERSION 3.8)
project(my_msgs)

find_package(ament_cmake REQUIRED)
find_package(rosidl_default_generators REQUIRED)
find_package(std_msgs REQUIRED)              # if your msgs use std_msgs

rosidl_generate_interfaces(${PROJECT_NAME}
  msg/MyMsg.msg
  srv/AddTwoInts.srv
  action/Foo.action
  DEPENDENCIES std_msgs
)

ament_export_dependencies(rosidl_default_runtime)
ament_package()
```

```xml
<!-- package.xml -->
<package format="3">
  ...
  <buildtool_depend>ament_cmake</buildtool_depend>
  <build_depend>rosidl_default_generators</build_depend>
  <exec_depend>rosidl_default_runtime</exec_depend>
  <member_of_group>rosidl_interface_packages</member_of_group>
  <depend>std_msgs</depend>
</package>
```

In a **consumer** package depending on this interface package:

```cmake
find_package(my_msgs REQUIRED)
ament_target_dependencies(my_node ... my_msgs)
```

---

## §14. Tests

```cmake
# CMakeLists.txt
if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()

  find_package(ament_cmake_gtest REQUIRED)
  ament_add_gtest(test_my test/test_my.cpp)
  target_link_libraries(test_my my_lib)
  ament_target_dependencies(test_my rclcpp)
endif()
```

Run:

```bash
colcon test --packages-select my_pkg
colcon test-result --verbose
```

---

## §15. Launch files

### Trivial node

```python
# my_pkg/launch/foo.launch.py
from launch import LaunchDescription
from launch_ros.actions import Node

def generate_launch_description():
    return LaunchDescription([
        Node(package='my_pkg', executable='my_node', name='my_node',
             output='screen'),
    ])
```

### Args, conditionals, params

```python
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare

def generate_launch_description():
    pkg = FindPackageShare('my_pkg')
    cfg = PathJoinSubstitution([pkg, 'config', 'avia.yaml'])
    rviz = PathJoinSubstitution([pkg, 'rviz', 'main.rviz'])

    return LaunchDescription([
        DeclareLaunchArgument('rviz', default_value='true'),
        DeclareLaunchArgument('bag_path', default_value=''),

        Node(package='my_pkg', executable='my_node', name='my_node',
             output='screen',
             parameters=[cfg, {'use_sim_time': False}],
             remappings=[('imu', '/livox/imu'),
                         ('lidar', '/livox/lidar')]),

        Node(package='rviz2', executable='rviz2', name='rviz2',
             condition=IfCondition(LaunchConfiguration('rviz')),
             arguments=['-d', rviz]),
    ])
```

### Including another launch file

```python
from launch.actions import IncludeLaunchDescription
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import PathJoinSubstitution
from launch_ros.substitutions import FindPackageShare

IncludeLaunchDescription(
    PythonLaunchDescriptionSource(
        PathJoinSubstitution([FindPackageShare('foo_bringup'), 'launch', 'foo.launch.py'])),
    launch_arguments={'arg1': 'value'}.items())
```

### Composable container

```python
from launch_ros.actions import ComposableNodeContainer
from launch_ros.descriptions import ComposableNode

ComposableNodeContainer(
    name='my_container',
    namespace='',
    package='rclcpp_components',
    executable='component_container',
    composable_node_descriptions=[
        ComposableNode(package='my_pkg', plugin='my_pkg::MyComponent', name='my_comp'),
    ],
    output='screen')
```

---

## §16. CLI cheat-sheet

| ROS1 | ROS2 |
|---|---|
| `roscore` | (none — DDS auto-discovery) |
| `rosrun <pkg> <exe>` | `ros2 run <pkg> <exe>` |
| `roslaunch <pkg> <file>` | `ros2 launch <pkg> <file>.launch.py` |
| `rosnode list` | `ros2 node list` |
| `rosnode info /n` | `ros2 node info /n` |
| `rostopic list/echo/hz/info/pub` | `ros2 topic list/echo/hz/info/pub` |
| `rosservice list/call` | `ros2 service list/call` |
| `rosparam list/get/set/load` | `ros2 param list/get/set` (no `rosparam load`; use launch) |
| `rosmsg show <T>` | `ros2 interface show <pkg>/msg/<T>` |
| `rossrv show <T>` | `ros2 interface show <pkg>/srv/<T>` |
| `rosbag record/play` | `ros2 bag record/play` |
| `rqt`, `rviz` | `rqt`, `rviz2` |
| `rospack find <pkg>` | `ros2 pkg prefix <pkg>` |
| `catkin_make` | `colcon build` |
| `catkin_make run_tests` | `colcon test && colcon test-result --verbose` |
| `roswtf` | `ros2 doctor` |

---

## §17. Common patterns at a glance

### Wait for a topic to appear

```cpp
// ROS1
ros::topic::waitForMessage<sensor_msgs::Imu>("imu", ros::Duration(2.0));

// ROS2 — no direct equivalent; use a one-shot subscription:
std::promise<void> got;
auto sub = node->create_subscription<sensor_msgs::msg::Imu>(
  "imu", rclcpp::SensorDataQoS(),
  [&got](sensor_msgs::msg::Imu::SharedPtr) {
    static bool fired = false;
    if (!fired) { got.set_value(); fired = true; }
});
got.get_future().wait_for(std::chrono::seconds(2));
```

### "I don't care about messages older than X"

```cpp
// ROS2 — set a deadline QoS or a per-message timestamp filter
rclcpp::QoS qos(10);
qos.deadline(std::chrono::milliseconds(100));      // optional, for tracking
// In the callback, drop based on header.stamp:
if ((node->now() - rclcpp::Time(msg->header.stamp)).seconds() > 0.1) return;
```

### One-shot timer

```cpp
// ROS2
auto t = node->create_wall_timer(std::chrono::seconds(2), [this](){
  RCLCPP_INFO(get_logger(), "fired");
  this->_oneshot_->cancel();          // cancel from inside
});
```

---

## §18. What does *not* exist in ROS2 (Humble) and what to do instead

| Missing | Workaround |
|---|---|
| `dynamic_reconfigure` | Parameter callbacks via `add_on_set_parameters_callback` (§4) |
| `nodelet` (the framework) | `rclcpp_components` (composable nodes) |
| `actionlib::SimpleActionClient` | `rclcpp_action::Client` async API (§9) |
| `tf` (the wrapper) | `tf2`, `tf2_ros`, `tf2_geometry_msgs`, `tf2_eigen` (§7) |
| `pcl_ros::transformPointCloud` | `pcl::transformPointCloud` directly (Gotcha #9) |
| ROS1 latched topics | `rclcpp::QoS(1).transient_local()` on **both** ends (Gotcha #5) |
| `rosbag1` files | `rosbags-convert` or `ros2 bag convert` (Gotcha #22) |
| RViz1 plugins | Rewrite for `rviz_common::Display` (Gotcha #24) |

---

**Last Updated**: 2026-05-07
**Tested against**: ROS2 Humble (rclcpp 16.x, ament_cmake 1.x)
