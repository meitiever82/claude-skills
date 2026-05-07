// =============================================================================
// ROS2 Humble composable node skeleton.
// Used as a replacement for ROS1 nodelets.
// =============================================================================
#include <memory>
#include <string>

#include <rclcpp/rclcpp.hpp>
#include <rclcpp_components/register_node_macro.hpp>
#include <sensor_msgs/msg/imu.hpp>

namespace my_pkg
{

class MyComponent : public rclcpp::Node
{
public:
  explicit MyComponent(const rclcpp::NodeOptions & options)
  : rclcpp::Node("my_component", options)
  {
    pub_ = this->create_publisher<sensor_msgs::msg::Imu>(
      "out", rclcpp::SensorDataQoS());
    sub_ = this->create_subscription<sensor_msgs::msg::Imu>(
      "in", rclcpp::SensorDataQoS(),
      [this](sensor_msgs::msg::Imu::SharedPtr msg) { pub_->publish(*msg); });
    RCLCPP_INFO(get_logger(), "MyComponent constructed");
  }

private:
  rclcpp::Publisher<sensor_msgs::msg::Imu>::SharedPtr    pub_;
  rclcpp::Subscription<sensor_msgs::msg::Imu>::SharedPtr sub_;
};

}  // namespace my_pkg

// Register the component with class_loader.
RCLCPP_COMPONENTS_REGISTER_NODE(my_pkg::MyComponent)

// CMakeLists.txt:
//   add_library(my_component SHARED src/my_component.cpp)
//   ament_target_dependencies(my_component rclcpp rclcpp_components sensor_msgs)
//   rclcpp_components_register_nodes(my_component "my_pkg::MyComponent")
//   install(TARGETS my_component
//           ARCHIVE DESTINATION lib
//           LIBRARY DESTINATION lib
//           RUNTIME DESTINATION bin)
//
// Run with:
//   ros2 run rclcpp_components component_container
//   ros2 component load /ComponentManager my_pkg my_pkg::MyComponent
