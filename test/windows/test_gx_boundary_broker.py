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


if __name__ == "__main__":
    unittest.main()
