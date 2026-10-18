"""Evidence acceptance tests for Fontconfig ELF isolation."""

import unittest
from pathlib import Path
import sys

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from gx_fontconfig_link_check import inspect


DYNSYM = "1: 00000000 0 FUNC GLOBAL DEFAULT UND malloc"
PANGO = "/lib/libpangoft2-1.0.so.0"
SYSTEM = "/lib/libfontconfig.so.1"


def binding(symbol="FcPatternDestroy", target=SYSTEM, source=PANGO):
    return f"1: binding file {source} [0] to {target} [0]: normal symbol `{symbol}'\n"


class FontconfigLinkEvidenceTests(unittest.TestCase):
    def test_single_shared_library(self):
        result = inspect(DYNSYM, binding() + binding("FcConfigReference"))
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(len(result["pango_bindings"]), 2)

    def test_exported_public_or_alias_rejected(self):
        for name in ("FcPatternDestroy", "IA__FcPatternDestroy"):
            for visibility in ("DEFAULT", "PROTECTED"):
                with self.subTest(name=name, visibility=visibility):
                    row = f"2: 00001234 20 FUNC WEAK {visibility} 16 {name}"
                    self.assertEqual(inspect(DYNSYM + "\n" + row, binding())["status"], "FAIL")

    def test_split_libraries_rejected(self):
        for target in ("/app/ghostty", "/other/libfontconfig.so.1"):
            result = inspect(DYNSYM, binding() + binding("FcConfigReference", target))
            self.assertEqual(result["status"], "FAIL")
            self.assertEqual(len(result["pango_targets"]), 2)

    def test_missing_evidence_rejected(self):
        for symbols, log in (("", binding()), (DYNSYM, ""), (DYNSYM, binding(source="/app/ghostty"))):
            self.assertEqual(inspect(symbols, log)["status"], "FAIL")

    def test_hidden_and_undefined_symbols_are_not_exports(self):
        symbols = DYNSYM + "\n2: 00001234 20 FUNC GLOBAL HIDDEN 16 FcPatternDestroy"
        symbols += "\n3: 00000000 0 FUNC GLOBAL DEFAULT UND FcPatternReference"
        self.assertEqual(inspect(symbols, binding())["status"], "PASS")

    def test_crlf_and_duplicate_bindings(self):
        log = (binding() + binding()).replace("\n", "\r\n")
        self.assertEqual(len(inspect(DYNSYM, log)["pango_bindings"]), 1)


if __name__ == "__main__":
    unittest.main()
