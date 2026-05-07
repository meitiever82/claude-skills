# ROS2 Migration Skill

Migrate ROS1 (Noetic / catkin) packages to ROS2 (Humble / ament_cmake) with a
phased workflow, helper scripts, and a verifiable end state.

---

## Files

| File | Purpose |
|---|---|
| [`SKILL.md`](SKILL.md) | Top-level skill definition (frontmatter + overview) — loaded automatically when the skill is invoked. |
| [`WORKFLOW.md`](WORKFLOW.md) | ⭐ Mandatory 7-phase migration playbook with quality gates. |
| [`Gotchas.md`](Gotchas.md) | ⭐ Common pitfalls (wrong header path, QoS mismatch, `tf::*` traps, …). |
| [`API_MAPPING.md`](API_MAPPING.md) | Side-by-side ROS1 ↔ ROS2 cheat-sheet (rclcpp, tf2, ament). |
| [`templates/`](templates/) | `package.xml`, `CMakeLists.txt`, `node.cpp`, `lifecycle_node.cpp`, `component.cpp`, `launch.py`, `params.yaml`. |
| [`helpers/`](helpers/) | Bash & Python automation: header rewriter, package.xml converter, CMakeLists scaffolder, launch-XML→launch.py, workspace audit. |
| [`verification/`](verification/) | `smoke_test.sh`, `deprecation_grep.sh`, PR `checklist.md`. |
| [`examples/voxel-slam-migration.md`](examples/voxel-slam-migration.md) | End-to-end worked example: porting Voxel-SLAM (Noetic LIO). |

---

## Quick start

```bash
# 1. Audit a workspace before touching anything (read-only).
bash helpers/audit_workspace.sh ~/lio_ws/src

# 2. Convert a package.xml in-place (creates .bak).
python3 helpers/convert_package_xml.py path/to/package.xml

# 3. Generate a ROS2 CMakeLists.txt skeleton from a ROS1 one.
bash helpers/scaffold_cmakelists.sh path/to/CMakeLists.txt > /tmp/CMakeLists.ros2

# 4. Bulk-rewrite ROS1 message headers (<pkg/Type.h> → <pkg/msg/snake_case.hpp>).
bash helpers/rewrite_headers.sh path/to/src

# 5. Translate a ROS1 .launch (XML) into a ROS2 .launch.py stub.
python3 helpers/launch_xml_to_py.py path/to/foo.launch > path/to/foo.launch.py

# 6. After Phase 4 is done, smoke-test the package.
bash verification/smoke_test.sh path/to/package_dir

# 7. Run a final ROS1-only-pattern check before merging.
bash verification/deprecation_grep.sh path/to/src
```

---

## Phase summary

```
0. Inventory  ─►  1. Plan ─►  2. Build skeleton  ─►  3. Headers  ─►
4. Node API   ─►  5. Launch & params           ─►  6. Verify    ─►  7. Cleanup
```

Each phase has a quality gate. **Don't advance through a failed gate** — the cost of
debugging a half-migrated package compounds quickly. See `WORKFLOW.md` for the gates.

---

## Trigger phrases

The skill auto-activates on:

- "migrate to ros2" / "port to ros2"
- "ros1 to ros2" / "ros2 migration"
- "catkin to colcon" / "noetic to humble"
- "ament_cmake" / "rclcpp port"
- Chinese: "ros2迁移", "迁移到ros2", "ros1迁移ros2"

It does **not** activate for:

- ROS2-only development questions
- ROS1 debugging unrelated to ROS2
- Generic "what is rclcpp" tutorials

---

## Target distro

**ROS2 Humble Hawksbill** (LTS, EOL May 2027). Most patterns also work on Iron / Jazzy
with minor API tweaks (e.g. `rclcpp` API changes are backwards-compatible within these LTS
releases). Distro-specific notes are inline in each file.

---

## Companion skills

If during migration you find:

- The codebase architecture is unclear → invoke `/codebase-analysis` first.
- Want a multi-agent review of the migration PR → `/ultrareview` against the PR.
- Worried about subtle threading regressions → `/security-review` after Phase 6.

---

## Version

| | |
|---|---|
| Version | 1.0 |
| Target distro | Humble (Iron/Jazzy supported with notes) |
| Last updated | 2026-05-07 |
| Author | Generated via Claude Code, refined against the Voxel-SLAM use case |
