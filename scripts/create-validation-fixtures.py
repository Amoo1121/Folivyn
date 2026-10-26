#!/usr/bin/env python3
"""Create disposable, independently authored files for native acceptance checks."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import uuid


def main():
    root = Path(__file__).resolve().parent.parent
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run = root / "build" / "validation-runs" / f"{stamp}-{uuid.uuid4().hex[:8]}"
    run.mkdir(parents=True, exist_ok=False)

    unicode_text = "中文输入测试 👩🏽‍💻 cafe\u0301\r\nsecond line\r\n"
    files = {
        "sample.py": b'# Folivyn acceptance fixture\nmessage = "hello"\nprint(message)\n',
        "sample.json": '{\n  "name": "Folivyn",\n  "count": 3,\n  "text": "中文 🦊"\n}\n'.encode(),
        "sample.csv": b'name,value\nalpha,00123\n"with,comma","two words"\n',
        "reload.txt": b"disk version one\n",
        "unicode.txt": unicode_text.encode(),
        "utf8-bom.txt": b"\xef\xbb\xbf" + unicode_text.encode(),
        "utf16-le.txt": b"\xff\xfe" + unicode_text.encode("utf-16-le"),
        "utf16-be.txt": b"\xfe\xff" + unicode_text.encode("utf-16-be"),
        "invalid-utf8.txt": b"\xc0\xaf",
        "too-large.txt": b"x" * (10 * 1024 * 1024 + 1),
        "many-lines.py": b"# line\n" * 20_001,
    }
    for size in (100 * 1024, 1024 * 1024, 10 * 1024 * 1024):
        line = b"message = 'Folivyn performance fixture'\n"
        files[f"source-{size}.py"] = (line * (size // len(line) + 1))[:size]

    manifest = {}
    for name, contents in files.items():
        (run / name).write_bytes(contents)
        manifest[name] = {"bytes": len(contents), "sha256": hashlib.sha256(contents).hexdigest()}
    (run / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(run)


if __name__ == "__main__":
    main()
