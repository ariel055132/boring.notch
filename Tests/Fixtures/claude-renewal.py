"""Offline Claude control-protocol fixture. Never reads credentials or connects."""
import json
import os
import signal
import sys
import time

mode, report = sys.argv[1:]
with open(report, "w") as file:
    file.write(str(os.getpid()))
if mode == "resist-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode in ("hang", "resist-term"):
    time.sleep(30)
    sys.exit(0)
if mode == "nonzero":
    sys.stderr.write("fixture-private-token")
    sys.exit(1)
if mode == "eof":
    sys.exit(0)
if mode == "malformed":
    print("fixture-private-token", flush=True)
    time.sleep(30)
if mode == "flood":
    print("x" * 8192, flush=True)
    time.sleep(30)


def receive():
    message = json.loads(sys.stdin.readline())
    with open(report + ".requests", "a") as file:
        file.write(json.dumps(message) + "\n")
    assert message["type"] == "control_request"
    return message


def reply(identity, body):
    message = {"type": "control_response", "response": {
        "subtype": "success", "request_id": identity, "response": body}}
    encoded = json.dumps(message) + "\n"
    if mode == "split":
        for offset in range(0, len(encoded), 17):
            sys.stdout.write(encoded[offset:offset + 17])
            sys.stdout.flush()
            time.sleep(0.001)
    else:
        sys.stdout.write(encoded)
        sys.stdout.flush()


first = receive()
assert first["request"] == {"subtype": "initialize"}
if mode == "init-error":
    print(json.dumps({"type": "control_response", "response": {
        "subtype": "error", "request_id": "initialize", "error": "fixture-private-token"}}), flush=True)
    time.sleep(30)
reply("initialize", {})
second = receive()
assert second["request"] == {"subtype": "get_usage", "skip_behaviors": True}
if mode == "unsupported":
    print(json.dumps({"type": "control_response", "response": {
        "subtype": "error", "request_id": "usage", "error": "fixture-private-token"}}), flush=True)
elif mode == "interactive":
    print(json.dumps({"type": "control_request", "request_id": "permission", "request": {"subtype": "can_use_tool"}}), flush=True)
elif mode == "assistant":
    print(json.dumps({"type": "assistant", "message": "fixture-private-token"}), flush=True)
else:
    session = {"total_cost_usd": 0, "total_api_duration_ms": 0, "model_usage": {}}
    body = {"session": session, "rate_limits_available": True, "rate_limits": None, "behaviors": None}
    if mode == "cost":
        session["total_cost_usd"] = 0.01
    if mode == "api-duration":
        session["total_api_duration_ms"] = 1
    if mode == "model":
        session["model_usage"] = {"fixture-model": {"inputTokens": 1}}
    if mode == "bool-zero":
        session["total_cost_usd"] = False
    if mode == "behaviors":
        body["behaviors"] = {}
    if mode == "missing-session":
        del body["session"]
    if mode == "notifications":
        print(json.dumps({"type": "system", "subtype": "init"}), flush=True)
        reply("unrelated", {})
    reply("wrong-id" if mode == "wrong-id" else "usage", body)
time.sleep(30)
