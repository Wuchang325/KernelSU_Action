#!/usr/bin/env python3
"""Inspect and repack this project's F.06 Android boot-v2 image, without flashing."""

import argparse
import gzip
import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

STOCK_SHA256 = "2dca84788aa3d5d60a839cf393319fac6da05cff19f34b17897af941378cb9e9"
CONFIG_SHA256 = "0abae937608160934018ef390390bf4a3361bf3b4ac717f571c955c6e67703d3"
FIELDS = (
    "kernel_size", "kernel_addr", "ramdisk_size", "ramdisk_addr",
    "second_size", "second_addr", "tags_addr", "page_size",
    "header_version", "os_version",
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def kernel_details(data: bytes) -> dict:
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    raw = decoder.decompress(data) + decoder.flush()
    if not decoder.eof or decoder.unused_data:
        raise ValueError("Expected one complete gzip kernel without appended DTB")
    if raw[56:60] != b"ARM\x64":
        raise ValueError("New kernel is not an arm64 Image")
    start = raw.find(b"Linux version ")
    if start < 0:
        raise ValueError("Kernel has no Linux version banner")
    end = raw.find(b"\0", start)
    banner = raw[start:end].decode(errors="replace").strip()
    if not banner.startswith("Linux version 4.19.191+ "):
        raise ValueError(f"Unexpected kernel release: {banner}")
    start = raw.find(b"IKCFG_ST")
    end = raw.find(b"IKCFG_ED", start)
    if start < 0 or end < 0:
        raise ValueError("Kernel has no embedded IKCONFIG")
    config = gzip.decompress(raw[start + 8:end])
    return {"banner": banner, "config_sha256": sha256(config)}


class BootImage:
    def __init__(self, data: bytes):
        self.data = data
        if len(data) < 1660 or data[:8] != b"ANDROID!":
            raise ValueError("Not an Android boot image")
        self.header = dict(zip(FIELDS, struct.unpack_from("<10I", data, 8)))
        h = self.header
        if h["header_version"] != 2 or h["page_size"] != 2048:
            raise ValueError("This tool supports the Reno7 SE boot-v2 / 2048 layout only")
        recovery_size, recovery_offset, header_size = struct.unpack_from("<IQI", data, 1632)
        dtb_size, dtb_addr = struct.unpack_from("<IQ", data, 1648)
        h.update(recovery_dtbo_size=recovery_size, recovery_dtbo_offset=recovery_offset,
                 header_size=header_size, dtb_size=dtb_size, dtb_addr=dtb_addr)
        if header_size != 1660 or recovery_size or recovery_offset or h["second_size"]:
            raise ValueError("Unexpected secondary/recovery section or header size")
        self.sections = {}
        offset = h["page_size"]
        for name in ("kernel", "ramdisk", "second", "recovery_dtbo", "dtb"):
            size = h[f"{name}_size"]
            if offset + size > len(data):
                raise ValueError(f"Truncated {name} section")
            self.sections[name] = data[offset:offset + size]
            offset += self.align(size)
        self.payload_size = offset
        self.avb = None
        if data[-64:-60] == b"AVBf":
            _, major, minor, original_size, vbmeta_offset, vbmeta_size = struct.unpack_from(
                ">4sIIQQQ", data, len(data) - 64
            )
            if (original_size != offset or vbmeta_offset < original_size
                    or vbmeta_offset + vbmeta_size > len(data) - 64
                    or data[vbmeta_offset:vbmeta_offset + 4] != b"AVB0"):
                raise ValueError("Invalid AVB footer layout")
            self.avb = {"footer_version": [major, minor], "original_image_size": original_size,
                        "vbmeta_offset": vbmeta_offset, "vbmeta_size": vbmeta_size,
                        "algorithm_type": struct.unpack_from(">I", data, vbmeta_offset + 28)[0]}

    def align(self, size: int) -> int:
        page = self.header["page_size"]
        return (size + page - 1) // page * page

    def metadata(self) -> dict:
        return {"image_sha256": sha256(self.data), "image_size": len(self.data),
                "header": self.header,
                "name_hex": self.data[48:64].hex(),
                "cmdline": (self.data[64:576].split(b"\0")[0]
                            + self.data[608:1632].split(b"\0")[0]).decode(),
                "section_sha256": {key: sha256(value) for key, value in self.sections.items()},
                "kernel": kernel_details(self.sections["kernel"]), "avb": self.avb}


def checked_stock(path: Path) -> BootImage:
    boot = BootImage(path.read_bytes())
    if sha256(boot.data) != STOCK_SHA256:
        raise ValueError("Stock SHA256 does not match the supplied PFCM00 F.06 backup")
    if kernel_details(boot.sections["kernel"])["config_sha256"] != CONFIG_SHA256:
        raise ValueError("Stock embedded config does not match F.06")
    return boot


def assemble(stock: BootImage, kernel: bytes) -> bytes:
    kernel_details(kernel)
    header = bytearray(stock.data[:stock.header["page_size"]])
    struct.pack_into("<I", header, 8, len(kernel))
    sections = dict(stock.sections, kernel=kernel)
    digest = hashlib.sha1()
    for name in ("kernel", "ramdisk", "second", "recovery_dtbo", "dtb"):
        section = sections[name]
        digest.update(section)
        digest.update(struct.pack("<I", len(section)))
    header[576:608] = digest.digest() + bytes(12)
    payload = bytes(header)
    for section in sections.values():
        payload += section + bytes(stock.align(len(section)) - len(section))
    return payload


def compare(stock: BootImage, result: BootImage, kernel: bytes) -> None:
    for field, value in stock.header.items():
        if field != "kernel_size" and result.header[field] != value:
            raise ValueError(f"Header changed unexpectedly: {field}")
    before = bytearray(stock.data[:2048])
    after = bytearray(result.data[:2048])
    for start, end in ((8, 12), (576, 608)):
        before[start:end] = after[start:end] = bytes(end - start)
    if before != after:
        raise ValueError("Header/cmdline/address/padding changed unexpectedly")
    for name, content in stock.sections.items():
        if name != "kernel" and result.sections[name] != content:
            raise ValueError(f"Original {name} bytes changed")
    if result.sections["kernel"] != kernel:
        raise ValueError("Output kernel does not equal the supplied Image.gz")


def repack(stock_path: Path, kernel_path: Path, output: Path, avbtool: Path,
           report_dir: Path) -> None:
    paths = (stock_path.resolve(), kernel_path.resolve(), avbtool.resolve())
    if output.resolve() in paths:
        raise ValueError("Output must not overwrite an input")
    if output.exists():
        raise ValueError("Output already exists; choose a new filename")
    stock = checked_stock(stock_path)
    kernel = kernel_path.read_bytes()
    payload = assemble(stock, kernel)
    output.parent.mkdir(parents=True, exist_ok=True)
    report_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="f06-repack-") as work:
        staged = Path(work) / "boot.img"
        staged.write_bytes(payload)
        # The OEM private key is unavailable. Recompute the boot hash descriptor,
        # explicitly unsigned, instead of retaining an invalid OEM signature.
        subprocess.run([
            sys.executable, str(avbtool.resolve()), "add_hash_footer",
            "--image", str(staged), "--partition_name", "boot",
            "--partition_size", str(len(stock.data)), "--algorithm", "NONE",
            "--salt", STOCK_SHA256,
        ], check=True)
        subprocess.run([sys.executable, str(avbtool.resolve()), "verify_image",
                        "--image", str(staged)], check=True)
        result = BootImage(staged.read_bytes())
        compare(stock, result, kernel)
        if len(result.data) != len(stock.data) or not result.avb or result.avb["algorithm_type"] != 0:
            raise ValueError("Expected original partition size and explicitly unsigned AVB")
        with output.open("xb") as stream:
            stream.write(result.data)
    for name, boot in (("before", stock), ("after", result)):
        (report_dir / f"metadata-{name}.json").write_text(
            json.dumps(boot.metadata(), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (report_dir / "repack-check.txt").write_text(
        "PASS: raw ramdisk, second, recovery DTBO, entire OEM DTB wrapper and DTB,\n"
        "cmdline, header version, page size, OS version and load addresses preserved.\n"
        "Expected changes: kernel, kernel_size, legacy header checksum and AVB metadata.\n"
        "AVB hash descriptor verified; algorithm NONE (unsigned, requires unlocked bootloader).\n"
        "This is packaging validation, not a device boot test.\n", encoding="utf-8")
    (report_dir / "sha256sums.txt").write_text(
        f"{sha256(stock.data)}  stock-boot.img\n{sha256(kernel)}  Image.gz\n"
        f"{sha256(result.data)}  {output.name}\n", encoding="utf-8")
    print(f"Verified: {output}\nSHA256: {sha256(result.data)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    inspect = sub.add_parser("inspect")
    inspect.add_argument("boot", type=Path)
    build = sub.add_parser("repack")
    for option in ("stock", "kernel", "output", "avbtool", "report-dir"):
        build.add_argument(f"--{option}", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "inspect":
        print(json.dumps(checked_stock(args.boot).metadata(), indent=2, ensure_ascii=False))
    else:
        repack(args.stock, args.kernel, args.output, args.avbtool, args.report_dir)


if __name__ == "__main__":
    main()
