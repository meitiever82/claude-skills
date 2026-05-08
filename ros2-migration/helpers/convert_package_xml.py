#!/usr/bin/env python3
"""convert_package_xml.py — Convert a ROS1 package.xml (format 2) to ROS2 (format 3).

Usage:
    python3 convert_package_xml.py path/to/package.xml [--dry-run]

What it does:
    - Sets <package format="3">.
    - Replaces <buildtool_depend>catkin</buildtool_depend> with ament_cmake (or
      ament_python if a setup.py is detected next to the file).
    - Replaces <run_depend> with <exec_depend>.
    - Renames common deps via the DEP_MAP table below.
    - Adds <export><build_type>...</build_type></export>.
    - Backs up the original to package.xml.bak unless --dry-run.

It is conservative: deps without a known mapping are left as-is, so re-running
after manual edits is safe.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import xml.etree.ElementTree as ET

# ROS1 dep -> ROS2 dep (1:1 simple renames). Multi-target renames (e.g. tf -> tf2,
# tf2_ros, tf2_geometry_msgs) are handled separately below.
DEP_MAP: dict[str, str] = {
    "roscpp": "rclcpp",
    "rospy": "rclpy",
    "roslib": "ament_index_cpp",          # rough; users may need ament_index_python too
    "actionlib": "rclcpp_action",
    "actionlib_msgs": "action_msgs",
    "nodelet": "rclcpp_components",
    "rosbag": "rosbag2_cpp",
    "pcl_ros": "pcl_conversions",
    "message_generation": "rosidl_default_generators",
    "message_runtime": "rosidl_default_runtime",
    "livox_ros_driver": "livox_ros_driver2",
    "rviz": "rviz2",
    # tf -> handled specially
    # dynamic_reconfigure -> dropped (no replacement)
}

# Deps that are dropped entirely with a comment.
DEP_DROP: dict[str, str] = {
    "dynamic_reconfigure":
        "no ROS2 replacement — implement with declare_parameter + add_on_set_parameters_callback",
}

# Deps that fan out to multiple ROS2 deps.
DEP_FANOUT: dict[str, list[str]] = {
    "tf": ["tf2", "tf2_ros", "tf2_geometry_msgs"],
}


def detect_buildtool(pkg_xml_path: str) -> str:
    """Detect ament_python vs ament_cmake by what files live next to package.xml."""
    pkg_dir = os.path.dirname(os.path.abspath(pkg_xml_path))
    if os.path.exists(os.path.join(pkg_dir, "setup.py")) and not os.path.exists(
        os.path.join(pkg_dir, "CMakeLists.txt")
    ):
        return "ament_python"
    return "ament_cmake"


def convert(path: str, dry_run: bool = False) -> int:
    if not os.path.isfile(path):
        print(f"convert_package_xml: not a file: {path}", file=sys.stderr)
        return 2

    with open(path, "r", encoding="utf-8") as f:
        text = f.read()

    # Use regex on the text rather than xml.etree round-trip, to preserve formatting.
    new = text

    # 1. format="2" -> format="3"
    new = re.sub(r'<package\s+format="2"', '<package format="3"', new)
    if 'format="3"' not in new and '<package' in new:
        # No explicit format attribute → add format=3
        new = re.sub(r'<package(\s|>)', r'<package format="3"\1', new, count=1)

    # 2. buildtool: catkin -> ament_*
    buildtool = detect_buildtool(path)
    new = re.sub(
        r'<buildtool_depend>\s*catkin\s*</buildtool_depend>',
        f"<buildtool_depend>{buildtool}</buildtool_depend>",
        new,
    )

    # 3. <run_depend>X</run_depend> -> <exec_depend>X</exec_depend>
    new = re.sub(
        r'<run_depend>([^<]+)</run_depend>',
        r'<exec_depend>\1</exec_depend>',
        new,
    )

    # 4. Per-dep renames
    for ros1, ros2 in DEP_MAP.items():
        new = re.sub(
            rf'(<(?:build_|exec_|test_)?depend>)\s*{re.escape(ros1)}\s*(</(?:build_|exec_|test_)?depend>)',
            lambda m: m.group(1) + ros2 + m.group(2),
            new,
        )

    # 5. Drop deps (commented for traceability)
    for ros1, why in DEP_DROP.items():
        new = re.sub(
            rf'(<(?:build_|exec_|test_)?depend>)\s*{re.escape(ros1)}\s*(</(?:build_|exec_|test_)?depend>)',
            lambda m: f"<!-- DROPPED {ros1}: {why} -->",
            new,
        )

    # 6. Fan-out (e.g. tf -> tf2 + tf2_ros + tf2_geometry_msgs).
    # Strategy: drop ALL occurrences of the ROS1 dep first, then insert one
    # block of <depend> lines so build_depend + exec_depend collapse into one.
    for ros1, fan in DEP_FANOUT.items():
        pat = rf'<(?:build_|exec_|test_)?depend>\s*{re.escape(ros1)}\s*</(?:build_|exec_|test_)?depend>\s*\n?'
        existed = re.search(pat, new) is not None
        new = re.sub(pat, '', new)
        if existed:
            block = ''.join(f"  <depend>{d}</depend>\n" for d in fan)
            # Insert before the first <export> if any, else before </package>.
            if re.search(r'<export>', new):
                new = re.sub(r'(<export>)', block + r'\1', new, count=1)
            else:
                new = re.sub(r'</package>', block + r'</package>', new, count=1)

    # 7. Ensure <export><build_type>...</build_type></export> exists.
    if "<build_type>" in new:
        # Replace existing build_type if it says catkin
        new = re.sub(
            r'<build_type>\s*catkin\s*</build_type>',
            f"<build_type>{buildtool}</build_type>",
            new,
        )
    elif re.search(r'<export>\s*</export>', new):
        # Empty <export></export> — fill it in place rather than appending a new one.
        new = re.sub(
            r'<export>\s*</export>',
            f"<export>\n    <build_type>{buildtool}</build_type>\n  </export>",
            new,
            count=1,
        )
    elif re.search(r'<export>', new):
        # Existing non-empty <export> — append <build_type> as the first child.
        new = re.sub(
            r'(<export>)',
            r'\1\n    <build_type>' + buildtool + '</build_type>',
            new,
            count=1,
        )
    else:
        # No <export> at all — add one before </package>.
        export_block = (
            f"  <export>\n"
            f"    <build_type>{buildtool}</build_type>\n"
            f"  </export>\n"
        )
        new = re.sub(r'</package>', export_block + r'</package>', new, count=1)

    if new == text:
        print(f"convert_package_xml: no changes to {path}")
        return 0

    if dry_run:
        print(f"--- DRY RUN diff for {path} ---")
        # Simple unified-ish diff
        for i, (a, b) in enumerate(zip(text.splitlines(), new.splitlines())):
            if a != b:
                print(f"  - {a}")
                print(f"  + {b}")
        return 0

    backup = path + ".bak"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        print(f"backed up: {backup}")

    with open(path, "w", encoding="utf-8") as f:
        f.write(new)
    print(f"converted: {path}  (buildtool={buildtool})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("paths", nargs="+", help="package.xml file(s) to convert")
    ap.add_argument("--dry-run", action="store_true", help="show diff, don't write")
    args = ap.parse_args()

    rc = 0
    for p in args.paths:
        rc |= convert(p, dry_run=args.dry_run)
    return rc


if __name__ == "__main__":
    sys.exit(main())
