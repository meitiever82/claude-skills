// =============================================================================
// ROS2 Humble node skeleton — single-threaded, parameter-driven.
// Drop in src/ as <pkg>_node.cpp and adjust to taste.
// =============================================================================
#include <chrono>
#include <memory>
#include <string>
#include <vector>

#include <rclcpp/rclcpp.hpp>
#include <std_msgs/msg/header.hpp>
#include <sensor_msgs/msg/imu.hpp>
#include <geometry_msgs/msg/transform_stamped.hpp>
#include <tf2_ros/transform_broadcaster.h>
#include <tf2/LinearMath/Quaternion.h>
#include <tf2_geometry_msgs/tf2_geometry_msgs.hpp>

using namespace std::chrono_literals;

class MyNode : public rclcpp::Node
{
public:
  MyNode()
  : rclcpp::Node("my_node"),
    tf_broadcaster_(*this)
  {
    // -------- Parameters (declare once; YAML or CLI override) ----------
    this->declare_parameter<std::string>("imu_topic", "/imu/data");
    this->declare_parameter<std::string>("output_topic", "/imu/filtered");
    this->declare_parameter<double>("scale", 1.0);
    this->declare_parameter<std::vector<double>>(
      "covariance", std::vector<double>(9, 0.0));

    imu_topic_    = this->get_parameter("imu_topic").as_string();
    output_topic_ = this->get_parameter("output_topic").as_string();
    scale_        = this->get_parameter("scale").as_double();
    covariance_   = this->get_parameter("covariance").as_double_array();

    RCLCPP_INFO(get_logger(),
                "MyNode up. in=%s out=%s scale=%.3f",
                imu_topic_.c_str(), output_topic_.c_str(), scale_);

    // -------- Pub / Sub --------------------------------------------------
    pub_ = this->create_publisher<sensor_msgs::msg::Imu>(
      output_topic_, rclcpp::SensorDataQoS());

    sub_ = this->create_subscription<sensor_msgs::msg::Imu>(
      imu_topic_, rclcpp::SensorDataQoS(),
      std::bind(&MyNode::imu_cb, this, std::placeholders::_1));

    // -------- Timer ------------------------------------------------------
    timer_ = this->create_wall_timer(
      100ms, std::bind(&MyNode::tick, this));

    // -------- Runtime parameter callback ---------------------------------
    on_set_param_cb_handle_ = this->add_on_set_parameters_callback(
      std::bind(&MyNode::on_set_param, this, std::placeholders::_1));
  }

private:
  void imu_cb(const sensor_msgs::msg::Imu::SharedPtr msg)
  {
    sensor_msgs::msg::Imu out = *msg;
    out.linear_acceleration.x *= scale_;
    out.linear_acceleration.y *= scale_;
    out.linear_acceleration.z *= scale_;
    out.header.stamp = this->now();
    pub_->publish(out);
  }

  void tick()
  {
    // Example: broadcast a static-ish TF every tick.
    geometry_msgs::msg::TransformStamped ts;
    ts.header.stamp = this->now();
    ts.header.frame_id = "world";
    ts.child_frame_id  = "base_link";
    ts.transform.translation.x = 0.0;
    ts.transform.translation.y = 0.0;
    ts.transform.translation.z = 0.0;
    tf2::Quaternion q; q.setRPY(0, 0, 0);
    ts.transform.rotation = tf2::toMsg(q);
    tf_broadcaster_.sendTransform(ts);
  }

  rcl_interfaces::msg::SetParametersResult on_set_param(
    const std::vector<rclcpp::Parameter> & params)
  {
    rcl_interfaces::msg::SetParametersResult r;
    r.successful = true;
    for (const auto & p : params) {
      if (p.get_name() == "scale") {
        scale_ = p.as_double();
        RCLCPP_INFO(get_logger(), "scale -> %.3f", scale_);
      }
    }
    return r;
  }

  // -------- members --------------------------------------------------------
  std::string imu_topic_, output_topic_;
  double scale_{1.0};
  std::vector<double> covariance_;

  rclcpp::Publisher<sensor_msgs::msg::Imu>::SharedPtr      pub_;
  rclcpp::Subscription<sensor_msgs::msg::Imu>::SharedPtr   sub_;
  rclcpp::TimerBase::SharedPtr                             timer_;
  tf2_ros::TransformBroadcaster                            tf_broadcaster_;
  OnSetParametersCallbackHandle::SharedPtr                 on_set_param_cb_handle_;
};

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  rclcpp::spin(std::make_shared<MyNode>());
  rclcpp::shutdown();
  return 0;
}
