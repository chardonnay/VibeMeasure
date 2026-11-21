#!/usr/bin/env python3
"""Save usage fields from Antigravity's status line without persisting the transcript."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def section(payload, name, fields):
    value = payload.get(name)
    if not isinstance(value, dict):
        return {}
    return {key: value[key] for key in fields
            if key in value and type(value[key]) in (int, float, bool, str)}


def capture(raw):
    event = json.loads(raw)
    if not isinstance(event, dict) or event.get("product") != "antigravity":
        return
    out = {
        "product": "antigravity",
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "context_window": section(event, "context_window", ("total_input_tokens", "total_output_tokens")),
        "cost": section(event, "cost", ("total_usd",)),
    }
    if isinstance(event.get("plan_tier"), str):
        out["plan_tier"] = event["plan_tier"]
    quota = event.get("quota")
    if isinstance(quota, dict):
        out["quota"] = {
            key: section(quota, key, ("remaining_fraction", "remaining_amount", "reset_time", "reset_in_seconds", "disabled"))
            for key in quota
        }
    root = Path.home() / ".gemini" / "antigravity-cli"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=root, prefix=".vibemeasure-", delete=False) as temp:
        try:
            json.dump(out, temp, allow_nan=False)
            temp.flush()
            os.replace(temp.name, root / "vibemeasure-usage.json")
        finally:
            Path(temp.name).unlink(missing_ok=True)


def main():
    raw = sys.stdin.buffer.read()
    try:
        capture(raw)
    except (ValueError, OSError):
        print("VibeMeasure could not update the usage snapshot.", file=sys.stderr)
    if sys.argv[1:]:
        return subprocess.run(sys.argv[1:], input=raw, check=False).returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
