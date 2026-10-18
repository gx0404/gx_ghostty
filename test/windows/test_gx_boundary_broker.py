"""Offline boundary regression; no native UI or process operations."""
import struct
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock
import gx_drop_broker_fixture as broker


class ReceiptBoundaryTests(unittest.TestCase):

    def test_receipt_rejects_pid_reuse_and_distinguishes_rejection_from_cancel(self):
        text = ('fixture_receipt pid=44 request=1 outcome=rejected birth=100\n'
                'fixture_receipt pid=44 request=2 outcome=cancelled birth=200\n')
        self.assertEqual('cancelled', broker.receipt_rows(text, 44, 200)[0]['outcome'])
        self.assertEqual([], broker.receipt_rows(text, 44, 300))

    def test_rerun_with_the_same_name_never_overwrites_final_evidence(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            work = Path(folder)
            broker.save_new(work / 'BRK-01-native.json', {'status': 'FAIL'})
            with self.assertRaises(FileExistsError):
                broker.save_new(work / 'BRK-01-native.json', {'status': 'PASS'})
            image = SimpleNamespace(width=1, height=1, rgb=lambda: b'\x00\x00\x00')
            broker.png_new(image, work / 'BRK-01-receipt.png')
            with self.assertRaises(FileExistsError):
                broker.png_new(image, work / 'BRK-01-receipt.png')
            with self.assertRaisesRegex(FileExistsError, 'new --name'):
                broker.refuse_existing([work / 'BRK-01-native.json', work / 'missing.png'])
            self.assertIn('FAIL', (work / 'BRK-01-native.json').read_text(encoding='utf-8'))


if __name__ == "__main__":
    unittest.main()
