---
name: ros2-migration
description: "TRIGGER when user asks to migrate, port, or convert a ROS1 (catkin/Noetic) project to ROS2 (ament/Humble). Use when user wants to: port roscpp/rospy code to rclcpp/rclpy, convert package.xml v2→v3, rewrite CMakeLists.txt for ament_cmake, port .launch XML to .launch.py, replace tf with tf2_ros, migrate plugins (pluginlib/RViz), or audit a workspace for ROS2-readiness. Triggers on: 'migrate to ros2', 'port to ros2', 'ros1 to ros2', 'ros2 migration', 'catkin to colcon', 'noetic to humble', 'rclcpp port', 'ros2迁移', 'ros1迁移ros2', 'ament_cmake', '迁移到ros2'. DO NOT trigger for: pure ROS2 development questions, ROS1-only debugging, or simple 'how do I use ros2' questions."
level: 3
version: "1.0"
triggers:
  - "ros2 migration"
  - "ros1 to ros2"
  - "migrate to ros2"
  - "port to ros2"
  - "catkin to colcon"
  - "noetic to humble"
  - "ros2迁移"
  - "ros1迁移ros2"
argument-hint: "<package_or_workspace_path>"
---

# ROS2 Migration Skill (ROS1 Noetic → ROS2 Humble)

**Purpose**: Migrate a ROS1 (`catkin` / Noetic) C++ or Python package to ROS2 (`ament_cmake` /
Humble), with verifiable build and a phased rollback path.

**Default target**: ROS2 **Humble Hawksbill** (LTS, EOL May 2027). Most patterns also apply to
Iron / Jazzy with minor adjustments noted inline.

---

## What This Skill Does

Produces a migration plan and applies it across the seven moving parts of any ROS1 package:

| # | Layer | ROS1 | ROS2 (Humble) |
|---|---|---|---|
| 1 | **Build system** | `catkin_make` / `catkin build` | `colcon build` |
| 2 | **Package metadata** | `package.xml` v2 | `package.xml` v3 |
| 3 | **CMake macros** | `find_package(catkin REQUIRED COMPONENTS …)` + `catkin_package(...)` | `find_package(ament_cmake REQUIRED)` + `find_package(<each_dep> REQUIRED)` + `ament_package()` |
| 4 | **Node API** | `ros::NodeHandle`, `ros::Publisher`, `ros::spin` | `rclcpp::Node`, `rclcpp::Publisher<T>`, `rclcpp::spin` |
| 5 | **Message headers** | `<sensor_msgs/Imu.h>` | `<sensor_msgs/msg/imu.hpp>` (snake_case + `msg/` folder) |
| 6 | **TF / parameters** | `tf::*`, `n.param<T>(…)` | `tf2_ros::*`, `node->declare_parameter<T>(…)` |
| 7 | **Launch / config** | `.launch` XML, `rosrun`, `rosparam` | `.launch.py` (preferred) / `.launch.xml`, `ros2 run`, YAML loaded by launch |

**Output**: a migration plan document, modified source files in a feature branch, a working
`colcon build` and a smoke-tested `ros2 launch`.

---

## When to Use

Invoke this skill when the user asks to:
- Migrate a ROS1 package or workspace to ROS2
- "Build this on Humble" / "Why won't this work in ROS2?"
- Convert build files or launch files
- Port a node, plugin, or message library
- Audit a workspace for ROS2 compatibility before starting work

**Do NOT use** for:
- ROS2-only development questions ("how do I write a lifecycle node from scratch")
- ROS1 debugging that has nothing to do with ROS2
- Simple "what does `rclcpp::Node` do" questions

---

## ⚠️ MANDATORY PRE-REQUISITES

Before doing **any** migration work, read these files in this order:

1. **`WORKFLOW.md`** — the 7-phase migration process and quality gates.
2. **`Gotchas.md`** — common pitfalls that have wasted weeks of engineering time.
3. **`API_MAPPING.md`** — side-by-side rclcpp / tf2 / ament cheat-sheet.

**Non-negotiable rules**:
- ✅ **Always work on a branch** — the migration is destructive to the existing build.
- ✅ **Migrate one package at a time** — don't fan out until the first builds and runs.
- ✅ **Compile after every layer** — never batch up 7 layers of changes and hope.
- ✅ **Preserve algorithm code unchanged when possible** — the 80% that's just maths/PCL/Eigen
  doesn't move; only the ROS-touching seam moves.
- ❌ **Never delete the original ROS1 build** until the ROS2 build is functionally verified.

---

## High-Level Workflow

```
Phase 0: Inventory          → list packages, count ROS dependencies, identify blockers
Phase 1: Plan               → produce MIGRATION_PLAN.md with per-package ordering
Phase 2: Branch + sandbox   → create migration branch; ensure ROS2 toolchain installed
Phase 3: Build system       → package.xml v2→v3, CMakeLists.txt rewrite, colcon build skeleton
Phase 4: Node API           → headers, ros::* → rclcpp::*, params, tf, time
Phase 5: Launch + params    → .launch → .launch.py, YAML param hierarchy
Phase 6: Verify             → colcon build clean; ros2 launch smoke test
Phase 7: Cleanup            → remove ROS1 cruft, update README, document residual diffs
```

Each phase has a **quality gate**. Skipping a gate compounds errors that are far more
expensive to debug later. See `WORKFLOW.md` for the full per-phase protocol.

---

## File-System Layout

```
ros2-migration/
├── SKILL.md                    # this file (top-level definition)
├── WORKFLOW.md                 # ⭐ MANDATORY 7-phase migration workflow
├── Gotchas.md                  # ⭐ MANDATORY common pitfalls
├── API_MAPPING.md              # rclcpp / tf2 / ament cheat-sheet
├── README.md                   # human-facing index
├── templates/
│   ├── package.xml             # v3 template with placeholders
│   ├── CMakeLists.txt          # ament_cmake skeleton
│   ├── node.cpp                # rclcpp node skeleton
│   ├── lifecycle_node.cpp      # rclcpp_lifecycle node skeleton
│   ├── launch.py               # ROS2 launch.py template
│   ├── params.yaml             # ROS2 parameter file template
│   └── component.cpp           # composable node template
├── helpers/
│   ├── rewrite_headers.sh      # ROS1 → ROS2 message header rewriter
│   ├── convert_package_xml.py  # v2 → v3 converter
│   ├── scaffold_cmakelists.sh  # generate ROS2 CMakeLists.txt from a ROS1 one
│   ├── launch_xml_to_py.py     # .launch (XML) → .launch.py stub generator
│   └── audit_workspace.sh      # workspace-wide ROS2-readiness audit
├── verification/
│   ├── smoke_test.sh           # colcon build + ros2 run smoke test
│   ├── deprecation_grep.sh     # find remaining ROS1-only patterns
│   └── checklist.md            # per-PR review checklist
└── examples/
    └── voxel-slam-migration.md # worked example: Voxel-SLAM (Noetic → Humble)
```

---

## How to Invoke

```
/ros2-migration <path>          # Begin migration of a package or workspace
/ros2-migration --audit <path>  # Phase-0 audit only (no code changes)
/ros2-migration --package=<name> <ws>   # Migrate one specific package
```

Examples:

```
/ros2-migration src/Voxel-SLAM
/ros2-migration --audit ~/ros1_ws
/ros2-migration --package=voxel_slam /home/steve/lio_ws/src/Voxel-SLAM
```

---

## Output Style

Each migration produces:
1. **`MIGRATION_PLAN.md`** at the package root — Phase-0 inventory + Phase-1 plan + decisions log.
2. **Modified source files** on a `ros2-migration` git branch.
3. **`docs/ros2-migration/`** with per-phase notes and any open questions.
4. A **before/after diff summary** in the agent's final response.

All file changes carry a `# ROS2 migration:` comment for the first 30 days so future readers
can spot ports that may need cleanup.

---

## Progressive Disclosure

This skill loads on demand:

- **Always**: `SKILL.md` (this file).
- **Phase 0–2**: `WORKFLOW.md`, `helpers/audit_workspace.sh`.
- **Phase 3**: `templates/package.xml`, `templates/CMakeLists.txt`, `helpers/convert_package_xml.py`,
  `helpers/scaffold_cmakelists.sh`.
- **Phase 4**: `API_MAPPING.md`, `templates/node.cpp`, `helpers/rewrite_headers.sh`.
- **Phase 5**: `templates/launch.py`, `templates/params.yaml`, `helpers/launch_xml_to_py.py`.
- **Phase 6–7**: `Gotchas.md`, `verification/*`.

This avoids loading 30k of cheat-sheet into context when you only need a header rewrite.

---

## Why This Order Matters

1. **Build system before code** — without `colcon build` finding your package, you can't
   incrementally test code changes.
2. **Headers before APIs** — fixing `<sensor_msgs/Imu.h>` → `<sensor_msgs/msg/imu.hpp>` first
   makes most ROS1-vs-ROS2 differences syntactically obvious; the compiler stops complaining
   about missing types and starts complaining about missing methods (which is what you want).
3. **APIs before launch** — a working `ros2 run my_node` in a terminal is the cheapest
   smoke test. Only after the node spins up should you tackle launch.py.
4. **Launch before params** — once `ros2 launch` loads, parameter wiring becomes a normal
   debug exercise rather than a bootstrap problem.

The key principle: **each phase ends with a runnable artifact**. Never finish a phase in a
half-built state.

---

## Migration Decision Tree

```
Is this a C++ node?
├── Yes
│   └── Does it use lifecycle / managed shutdown?
│       ├── Yes → use rclcpp_lifecycle (templates/lifecycle_node.cpp)
│       └── No  → use plain rclcpp::Node (templates/node.cpp)
│           └── Is it a plugin / nodelet / composable?
│               ├── nodelet → port to rclcpp_components (templates/component.cpp)
│               └── pluginlib → keep pluginlib, update class_loader macros
└── No (Python)
    └── Use rclpy + ament_python (not covered by templates here, see API_MAPPING.md §11)

Is this an RViz plugin?
├── rviz1 plugin → rewrite for rviz_common::Display (rviz2 has different API; non-trivial)
└── rviz2 already → no migration

Is this a message-only package?
└── Convert to rosidl_default_generators (CMakeLists pattern in templates)
```

---

## Companion Skills

If during migration you find:
- The codebase architecture is unclear → invoke `/codebase-analysis` first.
- The migration changes shared interfaces and you want a security pass on the diff →
  `/security-review` after Phase 6.
- You want a multi-agent review of the migration PR → `/ultrareview` against the PR.

---

## Acceptance Criteria

A migration is **complete** when:

- [ ] `colcon build` succeeds with `--cmake-args -Wno-dev` and zero new warnings.
- [ ] `ros2 launch <pkg> <launch>.launch.py` brings the node up.
- [ ] Smoke test: relevant topics show data via `ros2 topic echo`.
- [ ] `colcon test` passes (or matches the ROS1 baseline if some tests are expected to fail).
- [ ] No `<ros/ros.h>`, no `roscpp`, no `<*.h>` (legacy) message header in source.
- [ ] No `catkin` references in `package.xml` or `CMakeLists.txt`.
- [ ] `MIGRATION_PLAN.md` decisions log is complete.
- [ ] Branch is merge-ready or a documented remaining-work list exists.

---

**Remember**: ROS2 migration is mechanical for ~80% of code (headers, types, build files) and
opinionated for ~20% (executors, lifecycle, callback groups, QoS). Get the mechanical parts done
first, runnable, and only then think about whether to use multi-threaded executors or
intra-process communication.

**Version**: 1.0
**Target distro**: ROS2 Humble Hawksbill (works for Iron/Jazzy with notes)
**Last Updated**: 2026-05-07
