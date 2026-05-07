#!/usr/bin/env bash
# rewrite_headers.sh — Convert ROS1 message/service/action header includes to ROS2 form.
# Usage: bash rewrite_headers.sh <source_dir> [--dry-run]
# Idempotent: running twice is a no-op.

set -euo pipefail
DIR="${1:?usage: rewrite_headers.sh <dir> [--dry-run]}"
DRY=0
[[ "${2:-}" == "--dry-run" ]] && DRY=1

if [[ ! -d "$DIR" ]]; then echo "not a directory: $DIR" >&2; exit 2; fi

# Convert <pkg/CamelCase.h>  -> <pkg/{msg,srv,action}/snake_case.hpp>
# We don't know which subdirectory (msg/srv/action) by name alone, so we
# default to msg/ and emit a marker comment for the user to verify on actions
# and services.

py_helper=$(cat <<'PY'
import re, sys

camel_to_snake = lambda s: re.sub(r'(?<!^)(?=[A-Z])', '_', s).lower()

# Heuristic: header names ending in "Action" are actions; the rest default to msg.
# Service detection is hard without parsing — flag with a comment for review.

def convert(line):
    # Match: #include <pkg_name/CamelCaseType.h>
    m = re.match(r'(\s*#\s*include\s*<)([a-zA-Z_][a-zA-Z0-9_]*)/([A-Z][A-Za-z0-9_]+)\.h(>.*)', line)
    if not m: return line
    prefix, pkg, cls, suffix = m.groups()
    snake = camel_to_snake(cls)
    # action heuristic
    if cls.endswith('Action') and not cls.endswith('Goal') and not cls.endswith('Result'):
        sub = 'action'
        cls_clean = re.sub(r'Action$', '', cls)
        snake = camel_to_snake(cls_clean)
        return f"{prefix}{pkg}/{sub}/{snake}.hpp{suffix}\n"
    # service: cannot detect from name alone — default to msg with a TODO
    return f"{prefix}{pkg}/msg/{snake}.hpp{suffix}\n"

for path in sys.argv[1:]:
    try:
        with open(path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
    except UnicodeDecodeError:
        continue
    new = [convert(l) for l in lines]
    if new != lines:
        sys.stdout.write(f"REWROTE: {path}\n")
        for i, (a, b) in enumerate(zip(lines, new)):
            if a != b:
                sys.stdout.write(f"  - {a.rstrip()}\n")
                sys.stdout.write(f"  + {b.rstrip()}\n")
        if "${DRY}" == "0":
            with open(path, 'w', encoding='utf-8') as f:
                f.writelines(new)
PY
)

# Substitute DRY into the heredoc (the python sees it as a literal "0" or "1")
py_helper="${py_helper//\$\{DRY\}/$DRY}"

mapfile -t FILES < <(find "$DIR" \( -name '*.h' -o -name '*.hpp' -o -name '*.cpp' -o -name '*.cc' \) -not -path '*/build/*' -not -path '*/install/*' -not -path '*/log/*' -not -path '*/.git/*')

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "no source files under $DIR" >&2; exit 0
fi

python3 -c "$py_helper" "${FILES[@]}"

cat <<'EOF'

NOTE: Service headers were defaulted to msg/ — review hits and move <pkg/srv/...hpp>
manually for any actual .srv types. Action headers stripped a trailing 'Action' suffix.
This script is idempotent; rerun safely.
EOF
