"""Offline SVG normalization and pin-validation tests."""
from pathlib import Path
import contextlib
import hashlib
import io
import math
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gx_fluent_icons as fluent


def svg(body, attributes=''):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" {attributes}>{body}</svg>'.encode()


class FluentIconsTests(unittest.TestCase):
    def test_relative_and_implicit_moveto_lines(self):
        self.assertEqual(fluent.normalize('m2 3 4 5 h2 v-1 z m1 1 l2 0'), [
            ('M', 2, 3), ('L', 6, 8), ('L', 8, 8), ('L', 8, 7), ('Z',),
            ('M', 3, 4), ('L', 5, 4)])

    def test_quadratic_and_reflected_controls(self):
        rows = fluent.normalize('M0 0 Q3 3 6 0 T12 0 S14 2 16 0')
        self.assertEqual(rows[1], ('C', 2, 2, 4, 2, 6, 0))
        self.assertEqual(rows[2], ('C', 8, -2, 10, -2, 12, 0))
        self.assertEqual(rows[3], ('C', 12, 0, 14, 2, 16, 0))
        rows = fluent.normalize('M0 0 C1 1 2 2 3 3 s2 2 3 0')
        self.assertEqual(rows[-1], ('C', 4, 4, 5, 5, 6, 3))

    def test_arc_normalization_and_degenerates(self):
        rows = fluent.normalize('M10 0 A10 10 0 0 1 0 10')
        self.assertEqual(rows[-1][-2:], (0, 10))
        self.assertAlmostEqual(rows[1][2], 5.522847498, places=6)
        self.assertEqual(fluent.normalize('M1 1 a0 2 0 0 1 3 4')[-1], ('L', 4, 5))
        self.assertEqual(fluent.normalize('M1 1 A2 2 0 0 1 1 1'), [('M', 1, 1)])
        rows = fluent.normalize('M0 0 A2 1 45 1 0 20 20')
        self.assertTrue(all(math.isfinite(v) for row in rows for v in row[1:]))
        self.assertEqual(fluent.normalize('M0 0 A10 10 0 0110 20'),
                         fluent.normalize('M0 0 A10 10 0 0 1 10 20'))
        with self.assertRaises(fluent.InvalidSvg):
            fluent.normalize('M0 0 A1e-300 1 0 0 1 10 10')

    def test_compound_holes_and_multiple_paths(self):
        _, _, paths = fluent.parse_svg(svg('<g fill-rule="evenodd"><path d="M0 0H20V20H0Z M5 5V15H15V5Z"/><path fill-rule="nonzero" d="M1 1L2 2Z"/></g>'))
        self.assertEqual([p[0] for p in paths], ['evenodd', 'nonzero'])
        self.assertEqual(sum(c[0] == 'M' for c in paths[0][1]), 2)

    def test_unsupported_or_malformed_content_rejected(self):
        for body in ['<rect width="1"/>', '<path transform="scale(2)" d="M0 0Z"/>',
                     '<path stroke="red" d="M0 0Z"/>', '<path fill="url(#x)" d="M0 0Z"/>',
                     '<path fill-rule="bad" d="M0 0Z"/>', '<script/>']:
            with self.subTest(body=body), self.assertRaises(fluent.InvalidSvg):
                fluent.parse_svg(svg(body))
        for path in ['L0 0', 'M0', 'M0 0R1 2', 'M0 0 LNaN 1', 'M0 0L1e99 1',
                     'M0 0A1 1 0 2 0 3 3', 'M0 0Z1 1', 'M,0 0', 'M0,,0', 'M0 0,']:
            with self.subTest(path=path), self.assertRaises(fluent.InvalidSvg):
                fluent.normalize(path)
        with self.assertRaises(fluent.InvalidSvg):
            fluent.parse_svg(b'<!DOCTYPE svg><svg/>')

    def test_pins_allow_checkout_crlf_but_reject_changed_or_missing_input(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'input'
            digest = hashlib.sha256(b'a\nb\n').hexdigest()
            path.write_bytes(b'a\r\nb\r\n')
            self.assertEqual(fluent.pinned(path, digest), b'a\nb\n')
            path.write_bytes(b'changed')
            with self.assertRaises(fluent.InvalidSvg):
                fluent.pinned(path, digest)
            path.unlink()
            with self.assertRaises(FileNotFoundError):
                fluent.pinned(path, digest)

    def test_format_is_stable_without_negative_zero(self):
        self.assertEqual(fluent.number(-0.00000001), '0')
        self.assertEqual(fluent.number(1.23456789), '1.234568')
        self.assertEqual(fluent.normalize('M1e1 -.5'), fluent.normalize('M10 -0.5'))


class CommandTests(unittest.TestCase):
    """The command says "Generated" only when it writes paths.zig (O3 finding F-4)."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        shutil.copytree(fluent.ROOT / fluent.BASE / 'inputs', self.root / fluent.BASE / 'inputs')
        self.paths = self.root / fluent.BASE / 'paths.zig'

    def run_main(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = fluent.main(['--root', str(self.root), *argv])
        return code, out.getvalue()

    def age(self):
        os.utime(self.paths, ns=(10**18, 10**18))
        return self.paths.stat().st_mtime_ns

    def test_reports_generated_only_when_it_writes(self):
        code, out = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn('Generated Fluent paths', out)
        self.assertEqual(self.paths.read_bytes(), fluent.generate(self.root))
        stamp = self.age()
        code, out = self.run_main()
        self.assertEqual(code, 0)
        self.assertNotIn('Generated', out)
        self.assertIn('up to date', out)
        self.assertEqual(self.paths.stat().st_mtime_ns, stamp)
        self.paths.write_bytes(fluent.generate(self.root).replace(b'\n', b'\r\n'))
        stamp = self.age()
        code, out = self.run_main()
        self.assertIn('up to date', out)
        self.assertEqual(self.paths.stat().st_mtime_ns, stamp)
        self.paths.write_bytes(b'stale')
        code, out = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn('Generated Fluent paths', out)
        self.assertEqual(self.paths.read_bytes(), fluent.generate(self.root))

    def test_check_never_writes(self):
        self.run_main()
        stamp = self.age()
        code, out = self.run_main('--check')
        self.assertEqual(code, 0)
        self.assertIn('PASS', out)
        self.assertNotIn('Generated', out)
        self.assertEqual(self.paths.stat().st_mtime_ns, stamp)
        self.paths.write_bytes(b'stale')
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            self.run_main('--check')
        self.assertEqual(raised.exception.code, 1)
        self.assertEqual(self.paths.read_bytes(), b'stale')


if __name__ == '__main__':
    unittest.main()
