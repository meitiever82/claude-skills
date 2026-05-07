# ============================================================
# ROS2 Humble CMakeLists.txt template (ament_cmake)
# Replace ${PKG_NAME} and edit dependencies / executables.
# ============================================================
cmake_minimum_required(VERSION 3.8)
project(${PKG_NAME})

# ---- Compiler settings -----------------------------------------------------
if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
endif()
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

# Optional: optimisation level (uncomment for release builds)
# set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG")

# ---- ament + ROS2 dependencies --------------------------------------------
find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)

find_package(std_msgs REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(geometry_msgs REQUIRED)
find_package(nav_msgs REQUIRED)

find_package(tf2 REQUIRED)
find_package(tf2_ros REQUIRED)
find_package(tf2_geometry_msgs REQUIRED)

# Uncomment as needed:
# find_package(rclcpp_components REQUIRED)
# find_package(rclcpp_action REQUIRED)
# find_package(pluginlib REQUIRED)
# find_package(ament_index_cpp REQUIRED)
# find_package(visualization_msgs REQUIRED)
# find_package(message_filters REQUIRED)

# ---- Third-party libraries -------------------------------------------------
# Eigen
# find_package(Eigen3 3.3 REQUIRED NO_MODULE)
#
# PCL (note: minimum version that ships in Humble is 1.10)
# find_package(PCL 1.10 REQUIRED COMPONENTS common io kdtree)
# add_definitions(${PCL_DEFINITIONS})

# ---- Headers ---------------------------------------------------------------
include_directories(include)

# ---- Library (optional) ----------------------------------------------------
# add_library(${PROJECT_NAME}_lib SHARED
#   src/foo.cpp
#   src/bar.cpp
# )
# ament_target_dependencies(${PROJECT_NAME}_lib
#   rclcpp std_msgs sensor_msgs geometry_msgs tf2_ros tf2_geometry_msgs)
# target_link_libraries(${PROJECT_NAME}_lib Eigen3::Eigen ${PCL_LIBRARIES})

# ---- Executable ------------------------------------------------------------
add_executable(${PROJECT_NAME}_node src/${PROJECT_NAME}_node.cpp)
ament_target_dependencies(${PROJECT_NAME}_node
  rclcpp
  std_msgs sensor_msgs geometry_msgs nav_msgs
  tf2 tf2_ros tf2_geometry_msgs)
# target_link_libraries(${PROJECT_NAME}_node ${PROJECT_NAME}_lib Eigen3::Eigen ${PCL_LIBRARIES})

# ---- Composable component (optional) --------------------------------------
# add_library(${PROJECT_NAME}_component SHARED src/${PROJECT_NAME}_component.cpp)
# ament_target_dependencies(${PROJECT_NAME}_component rclcpp rclcpp_components)
# rclcpp_components_register_nodes(${PROJECT_NAME}_component
#   "${PROJECT_NAME}::MyComponent")

# ---- Install rules ---------------------------------------------------------
install(TARGETS ${PROJECT_NAME}_node
  DESTINATION lib/${PROJECT_NAME})

# install(TARGETS ${PROJECT_NAME}_lib
#   ARCHIVE DESTINATION lib
#   LIBRARY DESTINATION lib
#   RUNTIME DESTINATION bin)

# install(TARGETS ${PROJECT_NAME}_component
#   ARCHIVE DESTINATION lib
#   LIBRARY DESTINATION lib
#   RUNTIME DESTINATION bin)

install(DIRECTORY include/
  DESTINATION include/)

install(DIRECTORY launch config rviz
  DESTINATION share/${PROJECT_NAME}
  OPTIONAL)

# ---- Export ----------------------------------------------------------------
ament_export_include_directories(include)
# ament_export_libraries(${PROJECT_NAME}_lib)
ament_export_dependencies(rclcpp std_msgs sensor_msgs geometry_msgs nav_msgs
                          tf2 tf2_ros tf2_geometry_msgs)

# ---- Tests -----------------------------------------------------------------
if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()

  # Example gtest:
  # find_package(ament_cmake_gtest REQUIRED)
  # ament_add_gtest(test_${PROJECT_NAME} test/test_${PROJECT_NAME}.cpp)
  # ament_target_dependencies(test_${PROJECT_NAME} rclcpp)
endif()

ament_package()
