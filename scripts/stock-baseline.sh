#!/usr/bin/env bash
# Stage 1: public OPPO source + device config + original-generation toolchain.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=config/reno7se-stock-baseline.env
. "$REPO_ROOT/config/reno7se-stock-baseline.env"
WORKSPACE=${WORKSPACE:-"$REPO_ROOT/kernel_workspace"}
KERNEL_DIR="$WORKSPACE/android-kernel"
MODULES_DIR="$WORKSPACE/oppo-kernel-modules"
ARTIFACTS="$WORKSPACE/artifacts"
TOOLS="$WORKSPACE/toolchains"
mkdir -p "$ARTIFACTS" "$TOOLS"
exec > >(tee -a "$ARTIFACTS/build.log") 2>&1

collect() {
    local result=$? file
    trap - EXIT
    set +e
    for file in .config Module.symvers System.map include/generated/utsrelease.h include/generated/compile.h; do
        if [ -f "$KERNEL_DIR/out/$file" ]; then
            cp "$KERNEL_DIR/out/$file" "$ARTIFACTS/$(basename "$file")"
        fi
    done
    if [ -f "$KERNEL_DIR/out/.config" ]; then
        cp "$KERNEL_DIR/out/.config" "$ARTIFACTS/config.final"
        diff -u "$ARTIFACTS/config.original" "$ARTIFACTS/config.final" > "$ARTIFACTS/config.diff"
    fi
    if [ -d "$KERNEL_DIR/.git" ]; then
        git -C "$KERNEL_DIR" diff --binary > "$ARTIFACTS/kernel-source.diff"
    fi
    if [ -d "$MODULES_DIR/.git" ]; then
        git -C "$MODULES_DIR" diff --binary > "$ARTIFACTS/vendor-source.diff"
    fi
    if [ -f "$KERNEL_DIR/out/certs/signing_key.x509" ]; then
        openssl x509 -inform DER -in "$KERNEL_DIR/out/certs/signing_key.x509" \
            -noout -fingerprint -sha256 > "$ARTIFACTS/module-signing-certificate.txt"
    fi
    # Never upload generated signing_key.pem or any private key.
    python3 - "$ARTIFACTS" <<'PY'
import hashlib
from pathlib import Path
import sys
root = Path(sys.argv[1])
lines = []
for path in sorted(root.rglob("*")):
    if path.is_file() and path.name not in ("sha256sums.txt", "build.log"):
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        lines.append(f"{digest.hexdigest()}  {path.relative_to(root).as_posix()}\n")
(root / "sha256sums.txt").write_text("".join(lines))
PY
    exit "$result"
}
trap collect EXIT

clone_revision() {
    local url=$1 revision=$2 destination=$3
    test ! -e "$destination"
    git init -q "$destination"
    git -C "$destination" remote add origin "$url"
    git -C "$destination" fetch --depth=1 origin "$revision"
    git -C "$destination" checkout -q --detach FETCH_HEAD
    test "$(git -C "$destination" rev-parse HEAD)" = "$revision"
}

archive() {
    local url=$1 destination=$2 name=$3
    mkdir -p "$destination"
    curl --fail --location --retry 6 --retry-all-errors --retry-delay 5 \
        --connect-timeout 30 --max-time 600 "$url" -o "$TOOLS/$name.tar.gz"
    tar -xzf "$TOOLS/$name.tar.gz" -C "$destination"
    sha256sum "$TOOLS/$name.tar.gz" >> "$ARTIFACTS/toolchain-archives.sha256"
    rm "$TOOLS/$name.tar.gz"
}

python3 "$REPO_ROOT/tools/stock_boot.py" inspect "$REPO_ROOT/$STOCK_BOOT" > "$ARTIFACTS/stock-boot.json"
printf '%s  %s\n' "$STOCK_BOOT_SHA256" "$REPO_ROOT/$STOCK_BOOT" | sha256sum -c -
python3 - "$REPO_ROOT/$DEVICE_CONFIG" "$ARTIFACTS/config.original" "$DEVICE_CONFIG_SHA256" <<'PY'
import hashlib
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes().replace(b"\r\n", b"\n")
if hashlib.sha256(data).hexdigest() != sys.argv[3]:
    raise SystemExit("Device config hash mismatch")
Path(sys.argv[2]).write_bytes(data)
PY
cp "$REPO_ROOT/config/reno7se-stock-baseline.env" "$ARTIFACTS/build-profile.env"
git -C "$REPO_ROOT" rev-parse HEAD > "$ARTIFACTS/action-git-revision.txt"

clone_revision "$KERNEL_SOURCE" "$KERNEL_REVISION" "$KERNEL_DIR"
clone_revision "$MODULES_SOURCE" "$MODULES_REVISION" "$MODULES_DIR"
git -C "$KERNEL_DIR" rev-parse HEAD > "$ARTIFACTS/kernel-git-revision.txt"
git -C "$MODULES_DIR" rev-parse HEAD > "$ARTIFACTS/modules-git-revision.txt"
python3 "$REPO_ROOT/scripts/prepare_stock.py" "$KERNEL_DIR" "$MODULES_DIR" "$ARTIFACTS/source-adjustments.txt"

AOSP=https://android.googlesource.com/platform/prebuilts
archive "$AOSP/clang/host/linux-x86/+archive/$CLANG_REVISION/clang-$CLANG_VERSION.tar.gz" "$TOOLS/clang" clang
archive "$AOSP/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/+archive/$GCC64_REVISION.tar.gz" "$TOOLS/gcc64" gcc64
archive "$AOSP/gcc/linux-x86/arm/arm-linux-androideabi-4.9/+archive/$GCC32_REVISION.tar.gz" "$TOOLS/gcc32" gcc32
export PATH="$TOOLS/clang/bin:$TOOLS/gcc64/bin:$TOOLS/gcc32/bin:$PATH"
{
    clang --version
    ld.lld --version
    aarch64-linux-android-gcc --version
    arm-linux-androideabi-gcc --version
} > "$ARTIFACTS/compiler-version.txt"
cat "$ARTIFACTS/compiler-version.txt"
grep -q 'clang version 11.0.1' "$ARTIFACTS/compiler-version.txt"

# Avoid the generic KernelSU config, patch and build scripts entirely.
unset LOCALVERSION DISABLE_LTO
export KBUILD_BUILD_USER=stock-baseline KBUILD_BUILD_HOST=github-actions
export KBUILD_BUILD_TIMESTAMP='Tue Jan 31 21:06:31 CST 2023'
# OPPO uses unqualified -include paths for OplusKernelEnvConfig.mk and
# oplus_native_features.mk. Keep them visible in the O=out sub-make too.
MAKE_ARGS=( -C "$KERNEL_DIR" -I "$KERNEL_DIR" O=out ARCH=arm64 CC=clang LD=ld.lld
    AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump
    READELF=llvm-readelf STRIP=llvm-strip
    CROSS_COMPILE=aarch64-linux-android- CROSS_COMPILE_ARM32=arm-linux-androideabi-
    CROSS_COMPILE_COMPAT=arm-linux-androideabi- CLANG_TRIPLE=aarch64-linux-gnu-
    "TARGET_PRODUCT=$TARGET_PRODUCT" LLVM_IAS=1 )
mkdir -p "$KERNEL_DIR/out"
cp "$ARTIFACTS/config.original" "$KERNEL_DIR/out/.config"
make "${MAKE_ARGS[@]}" olddefconfig
cp "$KERNEL_DIR/out/.config" "$ARTIFACTS/config.after-olddefconfig"
diff -u "$ARTIFACTS/config.original" "$ARTIFACTS/config.after-olddefconfig" > "$ARTIFACTS/config.olddefconfig.diff" || test "$?" -eq 1

# Public source lacks the product cust.dtsi. Reuse stock boot DT data instead.
"$KERNEL_DIR/scripts/config" --file "$KERNEL_DIR/out/.config" \
    --disable BUILD_ARM64_APPENDED_DTB_IMAGE --disable BUILD_ARM64_DTB_OVERLAY_IMAGE
make "${MAKE_ARGS[@]}" olddefconfig
cp "$KERNEL_DIR/out/.config" "$ARTIFACTS/config.build-input"
python3 - "$ARTIFACTS/config.original" "$KERNEL_DIR/out/.config" <<'PY'
import re
from pathlib import Path
import sys
def options(path):
    found = {}
    for line in Path(path).read_text().splitlines():
        match = re.fullmatch(r"(CONFIG_\w+)=(.*)", line)
        if match:
            found[match[1]] = match[2]
    return found
original, final = map(options, sys.argv[1:])
protected = ["MODVERSIONS", "MODULE_SIG", "MODULE_SIG_FORCE", "MODULE_SIG_ALL",
             "KALLSYMS", "KALLSYMS_ALL", "KPROBES", "OVERLAY_FS", "LTO_NONE",
             "OPLUS_ROOT_CHECK", "OPLUS_EXECVE_BLOCK", "OPLUS_MOUNT_BLOCK", "OPLUS_SECURE_GUARD"]
for name in protected:
    key = "CONFIG_" + name
    if final.get(key) != original.get(key):
        raise SystemExit(f"Protected stock setting changed: {key}: {original.get(key)} -> {final.get(key)}")
for key, value in final.items():
    if (key.startswith("CONFIG_KSU") or key == "CONFIG_KPM") and value != "n":
        raise SystemExit(f"Unexpected root feature enabled: {key}")
print("Stock MODVERSIONS/signing/guards preserved; KSU absent")
PY

make "${MAKE_ARGS[@]}" -j"$(nproc)" Image.gz modules
grep -q 'UTS_RELEASE "4.19.191+"' "$KERNEL_DIR/out/include/generated/utsrelease.h"
for file in Image Image.gz; do
    cp "$KERNEL_DIR/out/arch/arm64/boot/$file" "$ARTIFACTS/$file"
done
test -s "$KERNEL_DIR/out/Module.symvers"
gzip -1 -c "$KERNEL_DIR/out/vmlinux" > "$ARTIFACTS/vmlinux.gz"
find "$KERNEL_DIR/out" -name '*.ko' -printf '%P\n' > "$ARTIFACTS/built-modules.txt"

curl --fail --location --retry 6 --retry-all-errors \
    "https://android.googlesource.com/platform/external/avb/+/$AVB_REVISION/avbtool.py?format=TEXT" \
    | base64 --decode > "$TOOLS/avbtool.py"
python3 "$REPO_ROOT/tools/stock_boot.py" repack \
    --stock "$REPO_ROOT/$STOCK_BOOT" --kernel "$ARTIFACTS/Image.gz" \
    --output "$ARTIFACTS/boot-stockbaseline.img" --avbtool "$TOOLS/avbtool.py" \
    --report-dir "$ARTIFACTS/repack"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo '### Reno7 SE F.06 — Stage 1 stock baseline'
        echo 'KSU/path_umount/SUSFS/KPM absent; original guards and module signing retained.'
        echo 'DT image generation disabled; original boot DTB and raw ramdisk preserved.'
        echo 'boot-stockbaseline.img uses unsigned AVB metadata (algorithm NONE).'
        echo 'Build/repack success does not establish device boot compatibility.'
    } >> "$GITHUB_STEP_SUMMARY"
fi
