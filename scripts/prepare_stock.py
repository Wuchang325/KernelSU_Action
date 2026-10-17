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
    # Resolve the seven original references directly. The symlinked vendor tree
    # does not reliably inherit include roots from charger parent Makefiles.
    # Only include locations change; header contents and driver code stay intact.
    for line in text.splitlines():
        if prefix in line:
            suffix = line.split(prefix, 1)[1].split('"', 1)[0]
            if not (kernel / suffix).is_file():
                raise ValueError(f"Missing original charger dependency: {suffix}")
    header.write_text(text.replace(prefix, kernel.as_posix() + "/"))

    required = (
        "kernel/sched_assist/Kconfig",
        "kernel/locking/klockopt/Kconfig",
        "drivers/base/kernelFwUpdate/Kconfig",
        "drivers/misc/mediatek/scp/include/scp.h",
        "drivers/misc/mediatek/typec/tcpc/inc/tcpm.h",
    )
    for name in required:
        if not (kernel / name).is_file():
            raise ValueError(f"Broken OPPO source mapping: {name}")
    report.write_text(
        "OPPO vendor links restored at kernel_workspace/vendor and vnd/vendor.\n"
        "Seven charger include paths resolved directly against the pinned kernel tree.\n"
        "No charger Makefile or inherited include flags modified.\n"
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
