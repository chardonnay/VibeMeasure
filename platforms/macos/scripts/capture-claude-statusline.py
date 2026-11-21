#!/usr/bin/env python3
"""Capture Claude Code's weekly quota metadata; optionally pass stdin to an existing statusline command."""

import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def capture(raw):
    event = json.loads(raw)
    if not isinstance(event, dict):
        return
    limits = event.get("rate_limits", {})
    if not isinstance(limits, dict):
        limits = {}
    weekly = {}
    for key, values in limits.items():
        if not re.fullmatch(r"seven_day(?:_[a-z0-9_]+)?", key) or not isinstance(values, dict):
            continue
        percent = values.get("used_percentage")
        if not number(percent) or not 0 <= percent <= 100:
            continue
        weekly[key] = {"used_percentage": percent}
        reset = values.get("resets_at")
        if number(reset):
            weekly[key]["resets_at"] = reset
    root = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=root, prefix=".vibemeasure-", delete=False) as tmp:
        try:
            json.dump({"rate_limits": weekly}, tmp, allow_nan=False)
            tmp.flush()
            os.replace(tmp.name, root / "vibemeasure-weekly.json")
        finally:
            Path(tmp.name).unlink(missing_ok=True)


def main():
    raw = sys.stdin.buffer.read()
    try:
        capture(raw)
    except (ValueError, OSError, OverflowError) as error:
        print(f"VibeMeasure weekly capture skipped ({type(error).__name__})", file=sys.stderr)
    if sys.argv[1:]:
        return subprocess.run(sys.argv[1:], input=raw).returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
