"""Offline Codex JSON-RPC fixture. Never reads local Codex files or uses the network."""
import json
import os
from pathlib import Path
import signal
import sys
import time

mode, report_path = sys.argv[1:3]
Path(report_path + ".pid").write_text(str(os.getpid()))
if mode == "hang":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)


def emit(message):
    data = (json.dumps(message) + "\n").encode()
    for start in range(0, len(data), 17):
        os.write(1, data[start:start + 17])


for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    with open(report_path, "a") as report:
        report.write(json.dumps(request) + "\n")
    if mode == "exit":
        sys.exit(1)
    if mode == "hang":
        while True:
            time.sleep(0.1)
    if mode == "flood":
        os.write(1, b"x" * 1_100_000)
        continue
    if mode == "malformed":
        os.write(1, b"not-json\n")
        continue
    if method == "initialize":
        emit({"id": request["id"], "result": {"userAgent": "offline-fixture"}})
    elif method == "initialized":
        emit({"method": "account/updated", "params": {"authMode": "chatgpt"}})
    elif method == "account/read":
        account = {"type": "chatgpt", "email": "fixture@example.invalid", "planType": "plus"}
        if mode == "signed-out":
            account = None
        elif mode == "api-key":
            account = {"type": "apiKey"}
        emit({"id": request["id"], "result": {"account": account}})
    elif method == "account/rateLimits/read":
        if mode in ("unsupported", "unauthorized", "rate-limited", "network"):
            code, message = {
                "unsupported": (-32601, "Method not found"),
                "unauthorized": (401, "Unauthorized"),
                "rate-limited": (429, "Too many requests"),
                "network": (-32000, "Network unavailable"),
            }[mode]
            emit({"id": request["id"], "error": {"code": code, "message": message}})
        else:
            bucket = {
                "limitId": "codex",
                "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1_900_000_000},
                "secondary": {"usedPercent": 60, "windowDurationMins": 10080, "resetsAt": 1_900_100_000},
                "credits": {"balance": "12.5", "unlimited": False},
            }
            emit({"method": "account/rateLimits/updated", "params": {"rateLimits": {}}})
            emit({"id": request["id"], "result": {"rateLimits": bucket}})
    elif method == "account/usage/read":
        if mode == "history-failure":
            emit({"id": request["id"], "error": {"code": -32000, "message": "Network unavailable"}})
        else:
            days = None if mode == "history-null" else [
                {"startDate": "2026-09-27", "tokens": 0},
                {"startDate": "2026-09-29", "tokens": 200000},
                {"startDate": "2026-10-02", "tokens": 500000},
            ]
            emit({"id": request["id"], "result": {"summary": {}, "dailyUsageBuckets": days}})
    else:
        raise RuntimeError("Unexpected RPC method: " + method)
