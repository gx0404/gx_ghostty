#!/usr/bin/env python3
"""Check ELF dynsym and LD_DEBUG=bindings evidence for Fontconfig isolation."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re


BINDING = re.compile(
    r"binding file (?P<source>.+?) \[\d+\] to (?P<target>.+?) \[\d+\]: "
    r"normal symbol [`'](?P<symbol>(?:IA__)?Fc\w+)'"
)


def inspect(dynsym: str, bindings: str) -> dict:
    """Return observed exports and Pango bindings; empty evidence fails closed."""
    rows = [line.split() for line in dynsym.splitlines()]
    rows = [r for r in rows if len(r) >= 8 and re.fullmatch(r"\d+:", r[0])]
    exported = sorted({
        r[7] for r in rows
        if r[4] in {"GLOBAL", "WEAK"} and r[5] in {"DEFAULT", "PROTECTED"}
        and r[6] != "UND" and re.match(r"^(?:IA__)?Fc", r[7])
    })
    pango = sorted({
        (m["source"], m["target"], m["symbol"])
        for m in BINDING.finditer(bindings)
        if m["source"].rsplit("/", 1)[-1].startswith("libpango")
    })
    targets = sorted({target for _, target, _ in pango})
    failures = []
    if not rows:
        failures.append("missing dynsym rows")
    if exported:
        failures.append("bundled Fontconfig symbols exported")
    if not pango:
        failures.append("missing Pango Fontconfig bindings")
    if len(targets) != 1 or not re.fullmatch(
        r"libfontconfig\.so(?:\.\d+)*", targets[0].rsplit("/", 1)[-1] if targets else ""
    ):
        failures.append("Pango Fontconfig bindings do not resolve to one shared library")
    return {
        "status": "FAIL" if failures else "PASS",
        "failures": failures,
        "exported_symbols": exported,
        "pango_targets": targets,
        "pango_bindings": [dict(source=s, target=t, symbol=n) for s, t, n in pango],
        "scope": "observed bindings only; not proof of crash root-cause closure",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dynsym", type=Path, required=True)
    parser.add_argument("--bindings", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    inputs = {name: path.read_bytes() for name, path in (
        ("dynsym", args.dynsym), ("bindings", args.bindings)
    )}
    result = inspect(*(inputs[name].decode("utf-8", errors="replace") for name in inputs))
    result["inputs"] = {
        name: {"path": str(getattr(args, name)), "sha256": hashlib.sha256(data).hexdigest()}
        for name, data in inputs.items()
    }
    with args.out.open("x", encoding="utf-8", newline="\n") as output:
        output.write(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(f"{result['status']}: {len(result['exported_symbols'])} exports, "
          f"{len(result['pango_bindings'])} Pango bindings, targets={result['pango_targets']}")
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
