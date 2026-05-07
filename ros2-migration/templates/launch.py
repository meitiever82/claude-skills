# =============================================================================
# ROS2 Humble launch file template.
# Save as <pkg>/launch/<name>.launch.py
# =============================================================================
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription
from launch.conditions import IfCondition, UnlessCondition
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare


def generate_launch_description():
    pkg = FindPackageShare('${PKG_NAME}')

    # -------- Substitutions / paths -----------------------------------------
    config_yaml = PathJoinSubstitution([pkg, 'config', 'params.yaml'])
    rviz_cfg    = PathJoinSubstitution([pkg, 'rviz', 'main.rviz'])

    # -------- Launch arguments ----------------------------------------------
    use_sim_time = LaunchConfiguration('use_sim_time')
    rviz         = LaunchConfiguration('rviz')

    declared_args = [
        DeclareLaunchArgument('use_sim_time', default_value='false',
                              description='Use /clock as the time source.'),
        DeclareLaunchArgument('rviz', default_value='true',
                              description='Whether to launch RViz2.'),
    ]

    # -------- Nodes ---------------------------------------------------------
    main_node = Node(
        package='${PKG_NAME}',
        executable='${PKG_NAME}_node',
        name='${PKG_NAME}_node',
        output='screen',
        parameters=[config_yaml,
                    {'use_sim_time': use_sim_time}],
        remappings=[
            # ('/old_topic', '/new_topic'),
        ],
        # Optional: --ros-args --log-level debug
        # arguments=['--ros-args', '--log-level', 'info'],
    )

    rviz_node = Node(
        package='rviz2',
        executable='rviz2',
        name='rviz2',
        output='screen',
        condition=IfCondition(rviz),
        arguments=['-d', rviz_cfg],
    )

    return LaunchDescription(declared_args + [main_node, rviz_node])
