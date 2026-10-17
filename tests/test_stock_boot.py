"""Packaging regressions using the exact supplied F.06 boot as the fixture."""

import gzip
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("stock_boot", ROOT / "tools/stock_boot.py")
boot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(boot)


class StockBootTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.stock = boot.checked_stock(ROOT / "boot/boot.img")
        # Different compressed size and page layout, same real arm64 kernel/config.
        cls.kernel = gzip.compress(gzip.decompress(cls.stock.sections["kernel"]), compresslevel=1, mtime=0)

    def test_original_config_and_layout(self):
        self.assertEqual(self.stock.header["header_version"], 2)
        self.assertEqual(self.stock.header["page_size"], 2048)
        self.assertEqual(boot.kernel_details(self.stock.sections["kernel"])["config_sha256"], boot.CONFIG_SHA256)
        self.assertEqual(self.stock.sections["dtb"][:4], bytes.fromhex("d7b7ab1e"))
        self.assertEqual(self.stock.sections["dtb"][64:68], bytes.fromhex("d00dfeed"))

    def test_original_payload_roundtrip(self):
        payload = boot.assemble(self.stock, self.stock.sections["kernel"])
        self.assertEqual(payload, self.stock.data[:self.stock.payload_size])

    def test_changed_size_preserves_sections_and_parameters(self):
        self.assertNotEqual(len(self.kernel), len(self.stock.sections["kernel"]))
        result = boot.BootImage(boot.assemble(self.stock, self.kernel))
        boot.compare(self.stock, result, self.kernel)
        self.assertEqual(result.sections["dtb"], self.stock.sections["dtb"])
        self.assertEqual(result.sections["ramdisk"], self.stock.sections["ramdisk"])

    def test_detects_ramdisk_dtb_and_cmdline_changes(self):
        original = boot.assemble(self.stock, self.kernel)
        page = self.stock.header["page_size"]
        ramdisk = page + self.stock.align(len(self.kernel))
        dtb = ramdisk + self.stock.align(self.stock.header["ramdisk_size"])
        for offset in (64, ramdisk, dtb, dtb + 64):
            with self.subTest(offset=offset):
                modified = bytearray(original)
                modified[offset] ^= 1
                with self.assertRaises(ValueError):
                    boot.compare(self.stock, boot.BootImage(bytes(modified)), self.kernel)

    def test_rejects_unrelated_kernel_and_truncated_boot(self):
        with self.assertRaises(ValueError):
            boot.assemble(self.stock, gzip.compress(b"unrelated kernel"))
        with self.assertRaises(ValueError):
            boot.BootImage(self.stock.data[:4096])

    def test_rejects_modified_stock(self):
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / "stock.img"
            path.write_bytes(self.stock.data[:-1] + b"\1")
            with self.assertRaises(ValueError):
                boot.checked_stock(path)

    @unittest.skipUnless(os.environ.get("AVBTOOL"), "Set AVBTOOL to run the AOSP AVB integration test")
    def test_unsigned_avb_roundtrip_and_input_preservation(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            kernel = root / "Image.gz"
            kernel.write_bytes(self.kernel)
            output = root / "new-boot.img"
            boot.repack(ROOT / "boot/boot.img", kernel, output, Path(os.environ["AVBTOOL"]), root / "reports")
            result = boot.BootImage(output.read_bytes())
            self.assertEqual(len(result.data), len(self.stock.data))
            self.assertEqual(result.avb["algorithm_type"], 0)
            boot.compare(self.stock, result, self.kernel)
            self.assertEqual(boot.sha256((ROOT / "boot/boot.img").read_bytes()), boot.STOCK_SHA256)
            with self.assertRaises(ValueError):
                boot.repack(ROOT / "boot/boot.img", kernel, kernel, Path(os.environ["AVBTOOL"]), root / "reports")


if __name__ == "__main__":
    unittest.main()
