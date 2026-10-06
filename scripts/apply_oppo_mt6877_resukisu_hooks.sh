#!/usr/bin/env bash

#
# OPPO Reno7 SE 5G / MT6877 / Linux 4.19.191
#
# ReSukiSU manual-hook integration.
#
# Target kernel:
#
#   oppo-source/android_kernel_oppo_mt6877
#
# Target branch:
#
#   oppo/mt6877_t_13.1.0_reno7_se_5g
#
# ReSukiSU's official scope-minimized kernel-4.19 patch matches:
#
#   fs/exec.c
#   fs/open.c
#   fs/stat.c
#
# very closely.
#
# The reboot.c hunk however targets a slightly different OPPO/MTK
# 4.19 tree containing check_poweroff_charger_mode().
#
# Therefore:
#
#   1. Apply the official ReSukiSU patch only to exec/open/stat.
#   2. Apply the reboot hook specifically for MT6877.
#   3. Verify all required hooks.
#

set -euo pipefail


KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}

WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}

PATCH_REPO="https://github.com/ReSukiSU/ReSukiSU_Patches.git"

PATCH_DIR="${WORKSPACE}/ReSukiSU_Patches"

PATCH_FILE="${PATCH_DIR}/scope-minimized/kernel-4.19.patch"


echo "=============================================="
echo " OPPO MT6877 ReSukiSU Manual Hook"
echo "=============================================="

echo
echo "Kernel:"
echo "  $KERNEL_DIR"

echo
echo "Patch repository:"
echo "  $PATCH_REPO"


# ============================================================
# Fetch official ReSukiSU patches
# ============================================================

if [ ! -d "${PATCH_DIR}/.git" ]; then

    echo
    echo "Downloading ReSukiSU patches..."

    rm -rf "$PATCH_DIR"

    git clone \
        --depth=1 \
        "$PATCH_REPO" \
        "$PATCH_DIR"

else

    echo
    echo "ReSukiSU patch repository already exists."

fi


if [ ! -f "$PATCH_FILE" ]; then

    echo "::error::ReSukiSU kernel-4.19 patch not found:"
    echo "::error::$PATCH_FILE"

    exit 1

fi


echo
echo "Official ReSukiSU patch:"
echo "  $PATCH_FILE"


# ============================================================
# Apply official 4.19 hooks
#
# We explicitly include only:
#
#   fs/exec.c
#   fs/open.c
#   fs/stat.c
#
# Do NOT apply the generic reboot.c hunk.
# ============================================================

cd "$KERNEL_DIR"


PATCH_ARGS=(
    "--include=fs/exec.c"
    "--include=fs/open.c"
    "--include=fs/stat.c"
)


echo
echo "=============================================="
echo " Applying official ReSukiSU 4.19 FS hooks"
echo "=============================================="


if git apply \
    --check \
    "${PATCH_ARGS[@]}" \
    "$PATCH_FILE"
then

    echo
    echo "Patch check successful."

    git apply \
        "${PATCH_ARGS[@]}" \
        "$PATCH_FILE"

    echo
    echo "Official ReSukiSU FS hooks applied."

elif git apply \
    --reverse \
    --check \
    "${PATCH_ARGS[@]}" \
    "$PATCH_FILE"
then

    echo
    echo "Official ReSukiSU FS hooks already applied."

else

    echo
    echo "::error::Official ReSukiSU 4.19 FS hooks do not apply cleanly."

    echo
    echo "Relevant locations:"

    grep -n \
        "int do_execve(struct filename" \
        fs/exec.c \
        || true

    grep -n \
        "SYSCALL_DEFINE3(faccessat" \
        fs/open.c \
        || true

    grep -n \
        "SYSCALL_DEFINE4(newfstatat" \
        fs/stat.c \
        || true

    echo
    echo "Patch dry-run output:"

    git apply \
        --check \
        --verbose \
        "${PATCH_ARGS[@]}" \
        "$PATCH_FILE" \
        || true

    exit 1

fi


# ============================================================
# OPPO MT6877 reboot hook
#
# ReSukiSU's generic 4.19 patch expects another OPPO/MTK
# reboot implementation.
#
# Insert the same ReSukiSU hook into the exact MT6877 source.
# ============================================================

echo
echo "=============================================="
echo " Applying MT6877 reboot hook"
echo "=============================================="


python3 - "$KERNEL_DIR" <<'PY'

from pathlib import Path
import sys


kernel = Path(sys.argv[1])

path = kernel / "kernel/reboot.c"


if not path.is_file():
    raise SystemExit(
        "[ERROR] kernel/reboot.c does not exist"
    )


text = path.read_text()


# ============================================================
# Declaration
# ============================================================

declaration_marker = (
    "extern int ksu_handle_sys_reboot"
)


if declaration_marker not in text:

    syscall_marker = (
        "SYSCALL_DEFINE4(reboot, int, magic1, int, magic2, unsigned int, cmd,\n"
        "\t\tvoid __user *, arg)"
    )


    if syscall_marker not in text:

        raise SystemExit(
            "[ERROR] MT6877 reboot syscall declaration was not found"
        )


    declaration = r'''#ifdef CONFIG_KSU_MANUAL_HOOK
extern int ksu_handle_sys_reboot(
	int magic1,
	int magic2,
	unsigned int cmd,
	void __user **arg);
#endif

'''


    text = text.replace(
        syscall_marker,
        declaration + syscall_marker,
        1
    )


    print("[ OK ] reboot hook declaration added")

else:

    print("[SKIP] reboot hook declaration already present")


# ============================================================
# Hook invocation
# ============================================================

call_marker = "ksu_handle_sys_reboot("


# Declaration itself already contains one occurrence.
# We therefore need at least two occurrences when the actual
# syscall hook call is installed.

if text.count(call_marker) < 2:

    syscall_start = text.find(
        "SYSCALL_DEFINE4(reboot"
    )


    if syscall_start < 0:

        raise SystemExit(
            "[ERROR] reboot syscall not found"
        )


    ret_marker = "\tint ret = 0;\n"


    ret_position = text.find(
        ret_marker,
        syscall_start
    )


    if ret_position < 0:

        raise SystemExit(
            "[ERROR] could not find reboot syscall ret initialization"
        )


    insert_position = (
        ret_position + len(ret_marker)
    )


    invocation = r'''
#ifdef CONFIG_KSU_MANUAL_HOOK
	ksu_handle_sys_reboot(
		magic1,
		magic2,
		cmd,
		&arg);
#endif
'''


    text = (
        text[:insert_position]
        + invocation
        + text[insert_position:]
    )


    print("[ OK ] reboot hook invocation added")

else:

    print("[SKIP] reboot hook invocation already present")


path.write_text(text)


# ============================================================
# Re-read and verify
# ============================================================

text = path.read_text()


if text.count("ksu_handle_sys_reboot(") < 2:

    raise SystemExit(
        "[ERROR] reboot hook verification failed"
    )


if "CONFIG_KSU_MANUAL_HOOK" not in text:

    raise SystemExit(
        "[ERROR] CONFIG_KSU_MANUAL_HOOK guard missing"
    )


print("[ OK ] kernel/reboot.c verified")

PY


# ============================================================
# Full hook verification
# ============================================================

echo
echo "=============================================="
echo " Verifying ReSukiSU hooks"
echo "=============================================="


check_marker()
{
    local file="$1"
    local marker="$2"
    local description="$3"

    if ! grep -q "$marker" "$file"; then

        echo "::error::Missing ReSukiSU hook:"
        echo "::error::$description"
        echo "::error::File: $file"
        echo "::error::Marker: $marker"

        exit 1

    fi

    echo "OK: $description"
}


check_marker \
    "$KERNEL_DIR/fs/exec.c" \
    "ksu_handle_execveat" \
    "execve hook"


check_marker \
    "$KERNEL_DIR/fs/open.c" \
    "ksu_handle_faccessat" \
    "faccessat hook"


check_marker \
    "$KERNEL_DIR/fs/stat.c" \
    "ksu_handle_stat" \
    "stat hook"


check_marker \
    "$KERNEL_DIR/fs/stat.c" \
    "ksu_handle_newfstat_ret" \
    "newfstat return hook"


check_marker \
    "$KERNEL_DIR/fs/stat.c" \
    "ksu_handle_fstat64_ret" \
    "fstat64 return hook"


check_marker \
    "$KERNEL_DIR/kernel/reboot.c" \
    "ksu_handle_sys_reboot" \
    "reboot hook"


# ============================================================
# Validate source formatting
# ============================================================

echo
echo "=============================================="
echo " git diff --check"
echo "=============================================="


git diff --check


echo
echo "=============================================="
echo " ReSukiSU hook diff"
echo "=============================================="


git diff -- \
    fs/exec.c \
    fs/open.c \
    fs/stat.c \
    kernel/reboot.c


echo
echo "=============================================="
echo " OPPO MT6877 ReSukiSU hooks ready"
echo "=============================================="
