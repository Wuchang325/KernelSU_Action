#!/usr/bin/env python3
"""Only the documented source-layout fixes needed by OPPO's public tree."""

import argparse
from pathlib import Path


def prepare(kernel: Path, modules: Path, report: Path) -> None:
    vendor = modules / "vendor"
    if not vendor.is_dir():
        raise ValueError(f"Missing vendor source: {vendor}")
    # Preserve the relative links shipped by OPPO, as in the existing workflow.
    for link in (kernel.parent / "vendor", kernel.parent.parent / "vnd/vendor"):
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.is_symlink():
            link.unlink()
        elif link.exists():
            raise ValueError(f"Refusing to replace existing directory: {link}")
        link.symlink_to(vendor, target_is_directory=True)

    header = vendor / "oplus/kernel/charger/charger_ic/oplus_battery_mtk6877R.h"
    text = header.read_text()
    prefix = "../../../../kernel-4.19/"
    if text.count(prefix) != 7:
        raise ValueError("Expected seven original MT6877 charger includes")
    # Use srctree include lookup instead of the unavailable full Android layout.
    header.write_text(text.replace(prefix, ""))
    makefile = vendor / "oplus/kernel/charger/Makefile"
    with makefile.open("a") as stream:
        stream.write("\n# Public-source layout: resolve kernel-relative charger headers.\n")
        stream.write("subdir-ccflags-y += -I$(srctree)\n")

    required = (
        "kernel/sched_assist/Kconfig",
        "kernel/locking/klockopt/Kconfig",
        "drivers/base/kernelFwUpdate/Kconfig",
        "drivers/misc/mediatek/scp/include/scp.h",
    )
    for name in required:
        if not (kernel / name).is_file():
            raise ValueError(f"Broken OPPO source mapping: {name}")
    report.write_text(
        "OPPO vendor links restored at kernel_workspace/vendor and vnd/vendor.\n"
        "Seven charger include paths changed to kernel-relative paths.\n"
        "Charger children inherit -I$(srctree).\n"
        "No function bodies, Werror flags, root hooks or guard macros modified.\n"
        "Only DT image generation is disabled later; the stock DTB is reused.\n"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kernel", type=Path)
    parser.add_argument("modules", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    prepare(args.kernel.resolve(), args.modules.resolve(), args.report)
