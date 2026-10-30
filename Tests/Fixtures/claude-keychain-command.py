"""Offline process fixture. Uses fake bytes only; never opens a real Keychain."""
import json
import os
from pathlib import Path
import signal
import sys
import time

mode, report_path = sys.argv[1:3]
if mode == "resist-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(report_path).write_text(str(os.getpid()))

payload = b"fixture-credential"
if mode == "success":
    for chunk in (payload[:5], payload[5:], b"\n"):
        os.write(1, chunk)
        time.sleep(0.01)
elif mode == "no-newline":
    os.write(1, payload)
elif mode == "two-newlines":
    os.write(1, payload + b"\n\n")
elif mode == "boundary":
    os.write(1, b"x" * 64 + b"\n")
elif mode == "empty":
    pass
elif mode == "newline":
    os.write(1, b"\n")
elif mode in ("failure", "missing", "eof-before-failure"):
    os.write(1, payload + b"\n")
    os.write(2, b"fixture-private-stderr\n")
    if mode == "eof-before-failure":
        os.close(1)
        time.sleep(0.15)
    sys.exit(44 if mode == "missing" else 1)
elif mode == "flood":
    while True:
        os.write(1, b"x" * 8192)
elif mode in ("hang", "resist-term"):
    os.write(1, payload)
    while True:
        time.sleep(0.05)
elif mode == "environment":
    print(json.dumps({"cwd": os.getcwd(), "stdinBytes": len(sys.stdin.buffer.read()),
                      "path": os.environ.get("PATH"), "lang": os.environ.get("LANG"),
                      "homePresent": bool(os.environ.get("HOME"))}))
else:
    raise RuntimeError("Unknown fixture mode")
