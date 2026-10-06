#!/usr/bin/env bash

set -euo pipefail

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}

echo "=============================================="
echo " OPPO / MTK vendor Werror compatibility"
echo "=============================================="

python3 - "$KERNEL_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])

if not root.is_dir():
    raise SystemExit(f"Kernel directory not found: {root}")

#
# OPPO/MediaTek's old 4.19 source contains many local:
#
#   ccflags-y += -Werror
#   subdir-ccflags-y += -Werror
#
# These bypass CONFIG_CC_WERROR and turn warnings introduced by
# newer Clang versions into fatal build failures.
#
# Only downgrade the standalone "-Werror" token.
#
# Keep specific diagnostics such as:
#
#   -Werror=implicit-function-declaration
#
# untouched.
#

pattern = re.compile(r'(?<!\S)-Werror(?=\s|$)')

changed_files = []
changed_count = 0

for path in root.rglob("*"):
    if not path.is_file():
        continue

    if path.name not in ("Makefile", "Kbuild"):
        continue

    try:
        text = path.read_text()
    except UnicodeDecodeError:
        continue

    new_text, count = pattern.subn("-Wno-error", text)

    if not count:
        continue

    path.write_text(new_text)

    rel = path.relative_to(root)

    changed_files.append((rel, count))
    changed_count += count

print()
print(f"Replaced {changed_count} standalone -Werror flags")
print(f"in {len(changed_files)} Makefile/Kbuild files.")
print()

for path, count in changed_files:
    print(f"[{count:2}] {path}")

print()
print("Specific -Werror=<warning> flags were preserved.")
PY

echo
echo "=============================================="
echo " Remaining standalone -Werror"
echo "=============================================="

grep -R \
    --include='Makefile' \
    --include='Kbuild' \
    -nE '(^|[[:space:]])-Werror([[:space:]]|$)' \
    "$KERNEL_DIR" \
    || true

echo
echo "=============================================="
echo " OPPO / MTK Werror compatibility ready"
echo "=============================================="
