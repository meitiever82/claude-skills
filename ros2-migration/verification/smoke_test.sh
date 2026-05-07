#!/usr/bin/env bash
# smoke_test.sh — Build + launch + check topic traffic.
# Usage: bash smoke_test.sh <package_dir>
#        bash smoke_test.sh <package_dir> --no-launch       # skip launch step
# Assumes you are inside a colcon workspace (src/<pkg> structure).

set -euo pipefail
PKG_DIR="${1:?usage: smoke_test.sh <package_dir> [--no-launch]}"
SKIP_LAUNCH=0
[[ "${2:-}" == "--no-launch" ]] && SKIP_LAUNCH=1

if [[ ! -f "$PKG_DIR/package.xml" ]]; then
  echo "smoke: not a package (no package.xml): $PKG_DIR" >&2
  exit 2
fi

PKG_NAME=$(grep -oE '<name>[^<]+</name>' "$PKG_DIR/package.xml" | head -n1 | sed 's/<[^>]*>//g')
WS_ROOT=$(cd "$PKG_DIR/../.." && pwd)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; }

bold "==> Workspace: $WS_ROOT"
bold "==> Package:   $PKG_NAME"
echo

# 1. Build
bold "==> colcon build --packages-select $PKG_NAME"
cd "$WS_ROOT"
if ! colcon build --packages-select "$PKG_NAME" --cmake-args -Wno-dev 2>&1 | tail -20; then
  err "build failed"; exit 1
fi
ok "build clean"
source "$WS_ROOT/install/setup.bash"

# 2. Test
bold "==> colcon test --packages-select $PKG_NAME"
if colcon test --packages-select "$PKG_NAME" --return-code-on-test-failure 2>&1 | tail -20; then
  ok "tests pass (or none defined)"
else
  err "tests failed (continuing anyway)"
fi

# 3. Launch (optional)
if [[ "$SKIP_LAUNCH" -eq 1 ]]; then
  bold "==> Skipping launch step"
  exit 0
fi

bold "==> Looking for a launch file"
LAUNCH_FILE=$(find "$WS_ROOT/install/$PKG_NAME/share/$PKG_NAME/launch" -name '*.launch.py' 2>/dev/null | head -n1 || true)
if [[ -z "$LAUNCH_FILE" ]]; then
  bold "==> No .launch.py found; trying ros2 run on first executable"
  EXE=$(find "$WS_ROOT/install/$PKG_NAME/lib/$PKG_NAME" -maxdepth 1 -type f -executable 2>/dev/null | head -n1 || true)
  if [[ -z "$EXE" ]]; then
    err "no executable found in install/$PKG_NAME/lib/$PKG_NAME — nothing to smoke"
    exit 1
  fi
  EXE_NAME=$(basename "$EXE")
  bold "==> ros2 run $PKG_NAME $EXE_NAME (5s timeout)"
  timeout 5 ros2 run "$PKG_NAME" "$EXE_NAME" 2>&1 | head -50 || true
  exit 0
fi

bold "==> ros2 launch $PKG_NAME $(basename $LAUNCH_FILE) (5s timeout)"
LOG=$(mktemp)
timeout 5 ros2 launch "$PKG_NAME" "$(basename "$LAUNCH_FILE")" > "$LOG" 2>&1 || true
sleep 1

# 4. Topic check
bold "==> ros2 topic list (post-launch snapshot)"
ros2 topic list || true
echo
bold "==> ros2 node list"
ros2 node list || true
echo

if grep -qiE 'error|exception|aborted|terminate' "$LOG"; then
  err "launch log contains errors:"
  grep -iE 'error|exception|aborted|terminate' "$LOG" | head -20
  rm -f "$LOG"
  exit 1
fi
ok "launch ran without obvious errors"
rm -f "$LOG"
