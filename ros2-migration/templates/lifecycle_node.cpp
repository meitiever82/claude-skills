// =============================================================================
// ROS2 Humble lifecycle node skeleton.
// State machine: unconfigured → inactive → active → ... → finalised.
// =============================================================================
#include <memory>
#include <string>

#include <rclcpp/rclcpp.hpp>
#include <rclcpp_lifecycle/lifecycle_node.hpp>
#include <rclcpp_lifecycle/lifecycle_publisher.hpp>
#include <sensor_msgs/msg/imu.hpp>

using CallbackReturn = rclcpp_lifecycle::node_interfaces::LifecycleNodeInterface::CallbackReturn;

class MyLifecycleNode : public rclcpp_lifecycle::LifecycleNode
{
public:
  MyLifecycleNode() : rclcpp_lifecycle::LifecycleNode("my_lc_node") {}

  CallbackReturn on_configure(const rclcpp_lifecycle::State &) override
  {
    this->declare_parameter<std::string>("imu_topic", "/imu/data");
    imu_topic_ = this->get_parameter("imu_topic").as_string();

    pub_ = this->create_publisher<sensor_msgs::msg::Imu>(
      imu_topic_ + "_filtered", rclcpp::SensorDataQoS());
    sub_ = this->create_subscription<sensor_msgs::msg::Imu>(
      imu_topic_, rclcpp::SensorDataQoS(),
      [this](sensor_msgs::msg::Imu::SharedPtr msg) {
        if (active_) pub_->publish(*msg);
      });

    RCLCPP_INFO(get_logger(), "configured");
    return CallbackReturn::SUCCESS;
  }

  CallbackReturn on_activate(const rclcpp_lifecycle::State &) override
  {
    pub_->on_activate();
    active_ = true;
    RCLCPP_INFO(get_logger(), "activated");
    return CallbackReturn::SUCCESS;
  }

  CallbackReturn on_deactivate(const rclcpp_lifecycle::State &) override
  {
    active_ = false;
    pub_->on_deactivate();
    RCLCPP_INFO(get_logger(), "deactivated");
    return CallbackReturn::SUCCESS;
  }

  CallbackReturn on_cleanup(const rclcpp_lifecycle::State &) override
  {
    pub_.reset();
    sub_.reset();
    RCLCPP_INFO(get_logger(), "cleaned up");
    return CallbackReturn::SUCCESS;
  }

  CallbackReturn on_shutdown(const rclcpp_lifecycle::State &) override
  {
    pub_.reset();
    sub_.reset();
    RCLCPP_INFO(get_logger(), "shutting down");
    return CallbackReturn::SUCCESS;
  }

private:
  std::string imu_topic_;
  bool active_{false};
  rclcpp_lifecycle::LifecyclePublisher<sensor_msgs::msg::Imu>::SharedPtr pub_;
  rclcpp::Subscription<sensor_msgs::msg::Imu>::SharedPtr                 sub_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::executors::SingleThreadedExecutor exec;
  auto node = std::make_shared<MyLifecycleNode>();
  exec.add_node(node->get_node_base_interface());
  exec.spin();
  rclcpp::shutdown();
  return 0;
}
