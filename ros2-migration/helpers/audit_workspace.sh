#!/usr/bin/env bash
# audit_workspace.sh — Phase 0 ROS2-readiness audit for a ROS1 workspace.
# Usage:  bash audit_workspace.sh <src_dir>
# Output: stdout report; non-zero exit if blockers found.

set -euo pipefail
ROOT="${1:-src}"
if [[ ! -d "$ROOT" ]]; then
  echo "audit: directory not found: $ROOT" >&2
  exit 2
fi

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[BLOCK]\033[0m %s\n' "$*"; }

bold "==> Workspace: $ROOT"
echo

# ---- Packages -------------------------------------------------------------
bold "==> package.xml files (and format version)"
mapfile -t PKGS < <(find "$ROOT" -name package.xml -not -path '*/build/*' -not -path '*/install/*' -not -path '*/log/*' | sort)
if [[ ${#PKGS[@]} -eq 0 ]]; then
  err "No package.xml files found under $ROOT"
  exit 1
fi
for p in "${PKGS[@]}"; do
  # format="N" with single or double quotes; absence of attr means format=1 by spec
  fmt=$(grep -oE "format=['\"][0-9]+['\"]" "$p" | head -n1 | grep -oE '[0-9]+' || true)
  if [[ -z "$fmt" ]]; then
    if grep -qE '<package[[:space:]]+format=' "$p"; then fmt="?"; else fmt="1"; fi
  fi
  pkg=$(grep -oE '<name>[^<]+</name>' "$p" | head -n1 | sed 's/<[^>]*>//g')
  printf "  format=%s  %-25s  %s\n" "$fmt" "$pkg" "$p"
done
echo

# ---- Dependency triage ----------------------------------------------------
bold "==> Aggregated <depend> entries"
declare -A DEPS
for p in "${PKGS[@]}"; do
  while IFS= read -r dep; do
    DEPS[$dep]=$((${DEPS[$dep]:-0} + 1))
  done < <(grep -oE '<(build_)?depend>[^<]+</(build_)?depend>|<exec_depend>[^<]+</exec_depend>|<run_depend>[^<]+</run_depend>' "$p" \
            | sed -E 's/<[^>]*>//g')
done

# Known mappings (subset; extend as needed)
declare -A MAP=(
  [roscpp]="rclcpp"
  [rospy]="rclpy"
  [roslib]="ament_index_cpp / ament_index_python"
  [tf]="tf2 + tf2_ros + tf2_geometry_msgs"
  [actionlib]="rclcpp_action"
  [actionlib_msgs]="action_msgs"
  [nodelet]="rclcpp_components"
  [dynamic_reconfigure]="(no port — use parameter callbacks)"
  [pcl_ros]="pcl_conversions + PCL"
  [rosbag]="rosbag2_cpp"
  [message_generation]="rosidl_default_generators"
  [message_runtime]="rosidl_default_runtime"
  [livox_ros_driver]="livox_ros_driver2 (community fork)"
  [rviz]="rviz2  (RViz1 plugins must be rewritten — see Gotcha #24)"
  [rqt_reconfigure]="rqt_reconfigure (works against any ROS2 node using declare_parameter)"
)
declare -A NATIVE=(
  [rclcpp]=1 [rclpy]=1 [std_msgs]=1 [sensor_msgs]=1 [geometry_msgs]=1 [nav_msgs]=1
  [tf2]=1 [tf2_ros]=1 [tf2_geometry_msgs]=1 [tf2_eigen]=1
  [pluginlib]=1 [message_filters]=1 [ament_cmake]=1 [ament_cmake_python]=1
  [rosidl_default_generators]=1 [rosidl_default_runtime]=1
  [rclcpp_components]=1 [rclcpp_action]=1 [rclcpp_lifecycle]=1
  [pcl_conversions]=1 [cv_bridge]=1 [image_transport]=1
  [visualization_msgs]=1 [diagnostic_msgs]=1 [diagnostic_updater]=1
  [eigen]=1 [eigen3_cmake_module]=1 [ament_index_cpp]=1 [ament_index_python]=1
  [rosbag2_cpp]=1 [rosbag2_storage]=1 [rosbag2_compression]=1 [rviz2]=1
  [livox_ros_driver2]=1
)
# System / non-ROS deps to ignore (rosdep keys for libs; not ROS-specific).
declare -A SYSTEM=(
  [libpcl-all-dev]=1 [libpcl-all]=1 [pcl]=1
  [eigen3]=1
  [libqt5-core]=1 [libqt5-gui]=1 [libqt5-widgets]=1 [qtbase5-dev]=1
  [boost]=1 [git]=1 [libpython3-dev]=1 [python3]=1
)

block=0
mapfile -t SORTED_DEPS < <(printf '%s\n' "${!DEPS[@]}" | sort)
for d in "${SORTED_DEPS[@]}"; do
  count=${DEPS[$d]}
  if [[ -n "${NATIVE[$d]:-}" ]]; then
    printf "  \033[32m[OK]\033[0m    %-32s  used by %d package(s)\n" "$d" "$count"
  elif [[ -n "${SYSTEM[$d]:-}" ]]; then
    printf "  \033[36m[SYS]\033[0m   %-32s  used by %d package(s)  (system dep — keep as-is)\n" "$d" "$count"
  elif [[ -n "${MAP[$d]:-}" ]]; then
    warn "$(printf '%-32s  used by %d package(s)  -> %s' "$d" "$count" "${MAP[$d]}")"
  else
    err "$(printf '%-32s  used by %d package(s) — unknown ROS2 mapping' "$d" "$count")"
    block=1
  fi
done
echo

# ---- Source-level seams ---------------------------------------------------
bold "==> Source seams (ROS1 patterns to migrate)"
# NB: with grep -E, '|' is alternation (do NOT escape it).
for pat in \
  'ros::Time::now|ros::Duration|ros::Rate|ros::ok|ros::spin' \
  'tf::[A-Z]' \
  'ROS_INFO|ROS_WARN|ROS_ERROR|ROS_DEBUG|ROS_FATAL' \
  'pluginlib::ClassLoader|nodelet::Nodelet' \
  'message_filters::Subscriber|message_filters::Synchronizer' \
  'actionlib::SimpleActionClient|actionlib::SimpleActionServer' \
  'dynamic_reconfigure' \
  'ros::package::getPath' \
  '<ros/ros\.h>' \
  '<sensor_msgs/[A-Z][a-zA-Z]*\.h>' \
  '<std_msgs/[A-Z][a-zA-Z]*\.h>' \
  '<geometry_msgs/[A-Z][a-zA-Z]*\.h>' \
  '<nav_msgs/[A-Z][a-zA-Z]*\.h>' \
  '<visualization_msgs/[A-Z][a-zA-Z]*\.h>'
do
  count=$(grep -rEl "$pat" "$ROOT" --include='*.h' --include='*.hpp' --include='*.cpp' --include='*.cc' 2>/dev/null | wc -l || true)
  printf "  %-60s  hits in %d file(s)\n" "$pat" "$count"
done
echo

# ---- Launch files ---------------------------------------------------------
bold "==> Launch files (ROS1 XML — need .launch.py port)"
mapfile -t LAUNCHES < <(find "$ROOT" -name '*.launch' -not -name '*.launch.py' -not -name '*.launch.xml' 2>/dev/null | sort)
echo "  $(echo ${#LAUNCHES[@]}) ROS1-style .launch files"
for l in "${LAUNCHES[@]:0:10}"; do echo "    - $l"; done
[[ ${#LAUNCHES[@]} -gt 10 ]] && echo "    ... and $((${#LAUNCHES[@]} - 10)) more"
echo

# ---- Plugin descriptors ---------------------------------------------------
bold "==> Plugin descriptors"
PLUGINS=$(grep -lE 'pluginlib|<library +path' "$ROOT"/**/*.xml 2>/dev/null || true)
if [[ -n "$PLUGINS" ]]; then
  echo "$PLUGINS" | sed 's|^|    |'
else
  echo "  (none found)"
fi
echo

# ---- Custom interfaces ----------------------------------------------------
bold "==> Custom message/service/action definitions"
MSGS=$(find "$ROOT" -name '*.msg' 2>/dev/null | wc -l)
SRVS=$(find "$ROOT" -name '*.srv' 2>/dev/null | wc -l)
ACTS=$(find "$ROOT" -name '*.action' 2>/dev/null | wc -l)
echo "  msg=$MSGS  srv=$SRVS  action=$ACTS"
echo

# ---- Result ---------------------------------------------------------------
bold "==> Verdict"
if [[ $block -ne 0 ]]; then
  err "Workspace has at least one dependency without a documented ROS2 mapping. Resolve before Phase 1."
  exit 1
else
  echo "  All dependencies have a known ROS2 path forward. Proceed to Phase 1 (plan)."
fi
