"""Offline boundary regression; no native UI or process operations."""
import struct
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock
import gx_popup_uia_fixture as popup_fixture


class PopupBoundaryTests(unittest.TestCase):

    def test_palette_shadow_class_is_a_real_popup_not_a_missing_transition(self):
        palette = SimpleNamespace(hwnd=3, cls='GhosttyGxPopupShadow')
        self.assertIs(palette, popup_fixture.choose_popup([palette]))


if __name__ == "__main__":
    unittest.main()
