#!/usr/bin/env bash
# rewrite_rviz_config.sh — convert a ROS1 .rviz config file to ROS2 (RViz2).
#
# Usage:    bash rewrite_rviz_config.sh <path/to/file.rviz> [<file2.rviz> ...]
#           bash rewrite_rviz_config.sh path/to/dir/      # recurse into directory
#
# Behaviour:
#   - Creates <file>.rviz.bak backup before in-place rewrite.
#   - Renames `Class: rviz/<X>` → `Class: rviz_default_plugins/<X>` for the
#     plugins shipped with rviz_default_plugins (Humble).
#   - Renames a few special cases (`PoseStamped` → `Pose`, `2D Nav Goal` →
#     `SetGoal`, etc.).
#   - Does NOT touch `Topic: /something` lines — those need a structural
#     conversion to a QoS sub-property block (see WORKFLOW.md §5.4); the
#     script prints a warning listing affected lines so you can hand-fix.
#   - After running, open the file in `rviz2` and Save Config As to let
#     RViz2 canonicalise the rest.
#
# Exit codes:
#   0 = success (warnings count as success)
#   1 = file argument not found / unreadable
#   2 = no input given

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <file.rviz> [<file2.rviz> ...]" >&2
  exit 2
fi

# Class-name rename table.  Key = ROS1 class, Value = ROS2 class.
# Sorted alphabetically; keep this in sync with WORKFLOW.md §5.4.
RENAMES=(
  "rviz/Axes|rviz_default_plugins/Axes"
  "rviz/Camera|rviz_default_plugins/Camera"
  "rviz/DepthCloud|rviz_default_plugins/DepthCloud"
  "rviz/FPS|rviz_default_plugins/FPS"
  "rviz/Grid|rviz_default_plugins/Grid"
  "rviz/GridCells|rviz_default_plugins/GridCells"
  "rviz/Image|rviz_default_plugins/Image"
  "rviz/InteractiveMarkers|rviz_default_plugins/InteractiveMarkers"
  "rviz/LaserScan|rviz_default_plugins/LaserScan"
  "rviz/Map|rviz_default_plugins/Map"
  "rviz/Marker|rviz_default_plugins/Marker"
  "rviz/MarkerArray|rviz_default_plugins/MarkerArray"
  "rviz/Odometry|rviz_default_plugins/Odometry"
  "rviz/Path|rviz_default_plugins/Path"
  "rviz/PointCloud|rviz_default_plugins/PointCloud"
  "rviz/PointCloud2|rviz_default_plugins/PointCloud2"
  "rviz/PointStamped|rviz_default_plugins/PointStamped"
  "rviz/Polygon|rviz_default_plugins/Polygon"
  "rviz/PoseArray|rviz_default_plugins/PoseArray"
  # PoseStamped → Pose (also renamed in RViz2)
  "rviz/PoseStamped|rviz_default_plugins/Pose"
  "rviz/PoseWithCovariance|rviz_default_plugins/PoseWithCovariance"
  "rviz/Range|rviz_default_plugins/Range"
  "rviz/RobotModel|rviz_default_plugins/RobotModel"
  "rviz/TF|rviz_default_plugins/TF"
  "rviz/WrenchStamped|rviz_default_plugins/Wrench"
  # Tools (in `Tools:` block)
  "rviz/MoveCamera|rviz_default_plugins/MoveCamera"
  "rviz/Select|rviz_default_plugins/Select"
  "rviz/FocusCamera|rviz_default_plugins/FocusCamera"
  "rviz/Measure|rviz_default_plugins/Measure"
  "rviz/PublishPoint|rviz_default_plugins/PublishPoint"
  # Common alias names too
  "rviz/SetInitialPose|rviz_default_plugins/SetInitialPose"
  "rviz/SetGoal|rviz_default_plugins/SetGoal"
  "rviz/2D Pose Estimate|rviz_default_plugins/SetInitialPose"
  "rviz/2D Nav Goal|rviz_default_plugins/SetGoal"
  "rviz/Interact|rviz_default_plugins/Interact"
  # View controllers
  "rviz/Orbit|rviz_default_plugins/Orbit"
  "rviz/XYOrbit|rviz_default_plugins/XYOrbit"
  "rviz/ThirdPersonFollower|rviz_default_plugins/ThirdPersonFollower"
  "rviz/FollowCamera|rviz_default_plugins/Follow"
  "rviz/TopDownOrtho|rviz_default_plugins/TopDownOrtho"
)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m[OK]\033[0m   %s\n' "$*"; }

process_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "skip: $f not a regular file" >&2
    return
  fi
  cp "$f" "$f.bak"
  local sed_args=()
  for entry in "${RENAMES[@]}"; do
    local old="${entry%|*}"; local new="${entry#*|}"
    # Use `#` as sed delimiter — the patterns contain both `:` and `/` but
    # never `#`. Match `Class: rviz/Foo` at end of line (covers entries that
    # have spaces in the class name like `rviz/2D Nav Goal`).
    sed_args+=(-e "s#Class: ${old}\$#Class: ${new}#")
  done
  sed -i "${sed_args[@]}" "$f"

  # Warn on `Topic: /xxx` shorthand — needs hand-conversion to QoS block.
  local topic_lines
  topic_lines=$(grep -nE '^[[:space:]]+Topic:[[:space:]]+/?[A-Za-z]' "$f" || true)
  if [[ -n "$topic_lines" ]]; then
    warn "$f: ${topic_lines%%$'\n'*}... needs Topic→QoS sub-property conversion"
    echo "$topic_lines" | sed 's/^/    /' | head -5
    [[ $(echo "$topic_lines" | wc -l) -gt 5 ]] && echo "    ... and $(( $(echo "$topic_lines" | wc -l) - 5 )) more"
    echo "  (open in rviz2 and Save Config As to canonicalise.)"
  fi

  # Warn about RobotModel — it loads from topic, not param, in RViz2.
  if grep -qE '^[[:space:]]+Class: rviz_default_plugins/RobotModel' "$f"; then
    if grep -qE '^[[:space:]]+Robot Description:' "$f"; then
      warn "$f: RobotModel uses 'Robot Description:' (param name); RViz2 reads from /robot_description topic."
      echo "  Either: (a) keep robot_state_publisher running so /robot_description is published,"
      echo "          (b) set Description Source: File and Description File: <urdf path>."
    fi
  fi

  # Warn about old plugin classes we don't know how to map.
  local unknown
  unknown=$(grep -nE '^[[:space:]]+Class: rviz/[A-Za-z]' "$f" || true)
  if [[ -n "$unknown" ]]; then
    warn "$f: still has unmapped 'rviz/...' classes — verify or hand-port:"
    echo "$unknown" | sed 's/^/    /'
  fi

  ok "rewrote $f (backup at $f.bak)"
}

# Expand directory args.
files=()
for arg in "$@"; do
  if [[ -d "$arg" ]]; then
    while IFS= read -r f; do files+=("$f"); done < <(find "$arg" -name '*.rviz' -not -name '*.rviz.bak')
  elif [[ -f "$arg" ]]; then
    files+=("$arg")
  else
    echo "skip: $arg not found" >&2
  fi
done

if [[ ${#files[@]} -eq 0 ]]; then
  echo "no .rviz files to process" >&2
  exit 1
fi

bold "==> Rewriting ${#files[@]} .rviz file(s)"
for f in "${files[@]}"; do
  process_file "$f"
done
echo
bold "==> Done. Next step:"
echo "  1. Open each file in rviz2:    rviz2 -d <path>.rviz"
echo "  2. Confirm displays appear; fix Topic→QoS warnings flagged above."
echo "  3. Save Config (Ctrl+S) to canonicalise."
echo "  4. Diff against .rviz.bak; commit."
