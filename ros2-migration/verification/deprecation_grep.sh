#!/usr/bin/env bash
# deprecation_grep.sh — Find ROS1-only patterns that should not survive migration.
# Usage: bash deprecation_grep.sh <source_dir>
# Exits non-zero if any patterns hit.

set -uo pipefail
DIR="${1:?usage: deprecation_grep.sh <source_dir>}"
[[ -d "$DIR" ]] || { echo "not a directory: $DIR" >&2; exit 2; }

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
red()  { printf '\033[31m%s\033[0m' "$*"; }
green(){ printf '\033[32m%s\033[0m' "$*"; }

declare -A PATTERNS=(
  ['<ros/ros.h>']='ROS1 core header'
  ['ros::NodeHandle']='ROS1 node handle'
  ['ros::Publisher']='ROS1 publisher'
  ['ros::Subscriber']='ROS1 subscriber'
  ['ros::ServiceServer']='ROS1 service server'
  ['ros::ServiceClient']='ROS1 service client'
  ['ros::AsyncSpinner']='ROS1 async spinner'
  ['ros::Time::now']='use node->now() instead'
  ['ros::Duration\(']='use rclcpp::Duration::from_seconds()'
  ['ros::Rate\(']='works in ROS2 via rclcpp::Rate; consider create_wall_timer'
  ['ros::ok']='use rclcpp::ok()'
  ['ros::spin\b']='use rclcpp::spin()'
  ['ros::spinOnce']='use exec.spin_some(0ms)'
  ['ROS_INFO\b']='use RCLCPP_INFO(get_logger(), ...)'
  ['ROS_WARN\b']='use RCLCPP_WARN(get_logger(), ...)'
  ['ROS_ERROR\b']='use RCLCPP_ERROR(get_logger(), ...)'
  ['ROS_DEBUG\b']='use RCLCPP_DEBUG(get_logger(), ...)'
  ['ROS_FATAL\b']='use RCLCPP_FATAL(get_logger(), ...)'
  ['tf::Transform[^L]']='use tf2::Transform'
  ['tf::Quaternion']='use tf2::Quaternion'
  ['tf::Vector3']='use tf2::Vector3'
  ['tf::TransformBroadcaster']='use tf2_ros::TransformBroadcaster'
  ['tf::TransformListener']='use tf2_ros::TransformListener + tf2_ros::Buffer'
  ['boost::shared_ptr']='use std::shared_ptr'
  ['actionlib::SimpleActionClient']='use rclcpp_action::Client'
  ['actionlib::SimpleActionServer']='use rclcpp_action::Server'
  ['nodelet::Nodelet']='use rclcpp_components / rclcpp::Node'
  ['dynamic_reconfigure']='use add_on_set_parameters_callback'
  ['ros::package::getPath']='use ament_index_cpp::get_package_share_directory'
  ['<sensor_msgs/[A-Z][a-zA-Z]*\.h>']='ROS1 message header'
  ['<std_msgs/[A-Z][a-zA-Z]*\.h>']='ROS1 message header'
  ['<geometry_msgs/[A-Z][a-zA-Z]*\.h>']='ROS1 message header'
  ['<nav_msgs/[A-Z][a-zA-Z]*\.h>']='ROS1 message header'
  ['<visualization_msgs/[A-Z][a-zA-Z]*\.h>']='ROS1 message header'
)

bold "==> Scanning $DIR for ROS1-only patterns"
echo

total=0
for p in "${!PATTERNS[@]}"; do
  hits=$(grep -rEnl --include='*.h' --include='*.hpp' --include='*.cpp' --include='*.cc' "$p" "$DIR" 2>/dev/null | wc -l)
  if [[ $hits -gt 0 ]]; then
    red "[$hits] "; printf '%-50s -> %s\n' "$p" "${PATTERNS[$p]}"
    grep -rEn --include='*.h' --include='*.hpp' --include='*.cpp' --include='*.cc' "$p" "$DIR" 2>/dev/null | head -3 | sed 's/^/      /'
    total=$((total + hits))
  fi
done

echo
if [[ $total -eq 0 ]]; then
  green "[CLEAN]"; printf ' No ROS1-only patterns found.\n'
  exit 0
else
  red "[DIRTY]"; printf ' %d hits remaining. Address before merging.\n' "$total"
  exit 1
fi
