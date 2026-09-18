#!/usr/bin/env python3
"""Check that split_text never exceeds the limit and never loses text."""

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("xtts_server", HERE / "xtts_server.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

LIMIT = 220
CASES = {
    "empty": "",
    "whitespace": "   \n\n  ",
    "short": "Hello there.",
    "many sentences": "One. Two! Three? Four; five: six.",
    "one huge word": "a" * 700,
    "no punctuation": " ".join(["word"] * 400),
    "long answer": "The serializer is the bottleneck. " * 40,
    "newlines only": "Line one\n\nLine two\nLine three",
    "exact limit": "b" * LIMIT,
    "limit plus one": "c" * (LIMIT + 1),
}

failures = []
for name, text in CASES.items():
    chunks = module.split_text(text, LIMIT)
    oversized = [c for c in chunks if len(c) > LIMIT]
    empty = [c for c in chunks if not c.strip()]
    kept = "".join("".join(c.split()) for c in chunks)
    source = "".join(text.split())
    if oversized:
        failures.append(f"{name}: {len(oversized)} chunk(s) over {LIMIT}")
    if empty:
        failures.append(f"{name}: {len(empty)} empty chunk(s)")
    if kept != source:
        failures.append(f"{name}: text changed, {len(source)} in and {len(kept)} out")

for failure in failures:
    print(f"FAIL {failure}", file=sys.stderr)
print(f"{len(CASES) - len({f.split(':')[0] for f in failures})} of {len(CASES)} cases clean")
sys.exit(1 if failures else 0)
