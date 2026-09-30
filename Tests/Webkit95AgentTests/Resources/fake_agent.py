"""Minimal fx style ACP agent over nd-JSON stdio for Webkit95Agent tests and the smoke run.

Wire shapes follow fx 0.0.12 as captured in docs/fx-wire-capture.md: session/new answers modes (ask
and code) plus a mode config option of category mode and is followed by available_commands_update,
session/set_mode answers null, message chunks carry a messageId, every reply ends with
session_info_update and usage_update, and the prompt result carries usage. Permission options are
fx's allow_once, allow_always and reject_once with the names Allow once, Allow for this session and
Reject. One difference on purpose: the session starts in code (fx's auto), so the tests prove the
client switches to ask before it prompts. A prompt in any mode but ask is answered with an error
and traced as prompt-in-<mode>.

The last prompt block picks a scenario: stream, tool, hang, crash, caps, blocks, pids, framing, fs,
fail, page, mode, authfail, flip, toolref, home (replies home:<HOME>), diag (fx's context and skill discovery
notes, a thought, then pong, as the real fx sends them before a reply). "tool <json>" sends <json> as the permission request's
rawInput, "toolcall <json>" merges <json> into its toolCall. The reply chunk is outcome:<kind>.

Flags: --trace <file> appends each method received. --fail-session and --auth-session make
session/new fail, --auth-exit exits at session/new with a provider error on stderr. --no-modes,
--no-ask, --config-mode (mode only as a config option), --refuse-mode, --silent-mode (set_mode never
answered), --refuse-reassert (only the first set_mode succeeds), --no-kinds (options without kind).
"""

import json
import os
import subprocess
import sys
import time

client_capabilities = None
cancelled = False
next_request_id = 1000
pending_request_id = None
next_message_id = 0
mode = "code"
mode_requests = 0
trace_path = sys.argv[sys.argv.index("--trace") + 1] if "--trace" in sys.argv else None

OPTIONS = [
    {"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"},
    {"optionId": "allow_always", "name": "Allow for this session", "kind": "allow_always"},
    {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"},
]

MODES = [
    {"id": "code", "name": "Code", "description": "Write and modify code with full tool access"},
    {"id": "ask", "name": "Ask", "description": "Request permission before making any changes"},
]

DENIED = {
    "error": {
        "type": "tool_permission_denied",
        "tool_name": "shell",
        "message": "Permission denied by user",
        "reason": "user_denied",
        "denied": True,
        "suggestion": "The tool did not run. Do not retry unchanged; explain the denial or use a safer allowed alternative.",
    }
}


def flag(name):
    return name in sys.argv


def trace(line):
    if trace_path:
        with open(trace_path, "a") as f:
            f.write(line + "\n")


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def respond(request_id, result):
    send({"jsonrpc": "2.0", "id": request_id, "result": result})


def error(request_id, code, message):
    send({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})


def update(session_id, payload):
    send({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {"sessionId": session_id, "update": payload},
    })


def chunk(session_id, text, kind="agent_message_chunk"):
    global next_message_id
    payload = {"sessionUpdate": kind, "content": {"type": "text", "text": text}}
    if kind == "agent_message_chunk":
        next_message_id += 1
        payload["messageId"] = "%032x" % next_message_id
    update(session_id, payload)


def raw(data, pause=0.0):
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    if pause:
        time.sleep(pause)


def chunk_line(session_id, text):
    return json.dumps({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
            "sessionId": session_id,
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}},
        },
    }, ensure_ascii=False).encode("utf-8")


def framing(session_id):
    raw(chunk_line(session_id, "crlf") + b"\r\n")
    split = chunk_line(session_id, "split") + b"\n"
    raw(split[:17], 0.05)
    raw(split[17:])
    raw(chunk_line(session_id, "a b c\u0085d") + b"\n")
    multibyte = chunk_line(session_id, "héllo \U0001F980") + b"\n"
    cut = multibyte.index("\U0001F980".encode("utf-8")) + 2
    raw(multibyte[:cut], 0.05)
    raw(multibyte[cut:])
    raw(b"{not json\n\n\xff\xfe\n[1,2\n" + b'{"jsonrpc":"2.0","method":"session/update","params":{}}\n')
    raw(chunk_line(session_id, "end") + b"\n")


def mode_option():
    return {
        "id": "mode",
        "name": "Session Mode",
        "category": "mode",
        "type": "select",
        "currentValue": mode,
        "options": [
            dict(value=m["id"], name=m["name"], description=m["description"], permissionMode="auto" if m["id"] == "code" else "ask")
            for m in MODES
            if not (flag("--no-ask") and m["id"] == "ask")
        ],
    }


def read_message():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    message = json.loads(line)
    if "method" in message:
        trace(message["method"])
    return message


def select_mode(message):
    """Answers session/set_mode or session/set_config_option, unless --silent-mode."""
    global mode, mode_requests
    mode_requests += 1
    params = message["params"]
    wanted = params.get("modeId", params.get("value"))
    if flag("--silent-mode"):
        return
    if flag("--refuse-mode") or (flag("--refuse-reassert") and mode_requests > 1):
        error(message["id"], -32602, "mode change not allowed")
        return
    mode = wanted
    if message["method"] == "session/set_config_option":
        respond(message["id"], {"configOptions": [mode_option()]})
        update(params["sessionId"], {"sessionUpdate": "config_option_update", "configOptions": [mode_option()]})
    else:
        respond(message["id"], None)


def wait_for(predicate):
    """Reads until predicate matches, noting session/cancel and serving mode changes on the way."""
    global cancelled
    while True:
        message = read_message()
        method = message.get("method")
        if method == "session/cancel":
            cancelled = True
            if pending_request_id is not None:
                send({"jsonrpc": "2.0", "method": "$/cancel_request", "params": {"requestId": pending_request_id}})
        elif method in ("session/set_mode", "session/set_config_option"):
            select_mode(message)
        elif method == "session/prompt":
            error(message["id"], -32600, "one prompt at a time")
        if predicate(message):
            return message


def report_mode(session_id, new_mode):
    global mode
    mode = new_mode
    if flag("--config-mode"):
        update(session_id, {"sessionUpdate": "config_option_update", "configOptions": [mode_option()]})
    else:
        update(session_id, {"sessionUpdate": "current_mode_update", "currentModeId": mode})


def run_tool(session_id, tool_call):
    global next_request_id, pending_request_id
    update(session_id, {
        "sessionUpdate": "tool_call",
        "toolCallId": "t1",
        "name": "shell",
        "title": "Run ls",
        "kind": "execute",
        "status": "pending",
    })
    next_request_id += 1
    request_id = next_request_id
    options = [{k: v for k, v in o.items() if k != "kind"} for o in OPTIONS] if flag("--no-kinds") else OPTIONS
    pending_request_id = request_id
    send({
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "session/request_permission",
        "params": {"sessionId": session_id, "toolCall": dict({"toolCallId": "t1", "name": "shell"}, **tool_call), "options": options},
    })
    reply = wait_for(lambda m: m.get("id") == request_id and "method" not in m)
    pending_request_id = None
    outcome = reply["result"]["outcome"]
    if outcome["outcome"] == "selected":
        selected = next(o.get("kind", o["name"]) for o in OPTIONS if o["optionId"] == outcome["optionId"])
    else:
        selected = "cancelled"
    if selected.startswith("allow"):
        update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"})
    elif selected != "cancelled":
        update(session_id, {
            "sessionUpdate": "tool_call_update",
            "toolCallId": "t1",
            "status": "failed",
            "content": [{"type": "content", "content": {"type": "text", "text": json.dumps(DENIED)}}],
        })
    chunk(session_id, "outcome:" + selected)


def handle_prompt(params):
    global cancelled, next_request_id
    cancelled = False
    session_id = params["sessionId"]
    blocks = params["prompt"]
    scenario = blocks[-1].get("text", "")
    if scenario == "stream":
        chunk(session_id, "thinking", "agent_thought_chunk")
        for word in ("one", "two", "three"):
            chunk(session_id, word)
        update(session_id, {"sessionUpdate": "mystery_update", "anything": True})
        chunk(session_id, "four")
    elif scenario == "tool":
        run_tool(session_id, {"title": "Run ls"})
    elif scenario.startswith("tool "):
        run_tool(session_id, {"title": "Run ls", "rawInput": json.loads(scenario[len("tool "):])})
    elif scenario.startswith("toolcall "):
        run_tool(session_id, json.loads(scenario[len("toolcall "):]))
    elif scenario == "toolref":
        update(session_id, {
            "sessionUpdate": "tool_call",
            "toolCallId": "t1",
            "name": "shell",
            "title": "bash",
            "kind": "execute",
            "status": "pending",
            "rawInput": {"action": "run", "command": "ls -la ~"},
        })
        run_tool(session_id, {})
    elif scenario == "hang":
        chunk(session_id, "working")
        wait_for(lambda m: m.get("method") == "session/cancel")
    elif scenario == "flip":
        report_mode(session_id, "code")
        chunk(session_id, "flipped")
        wait_for(lambda m: m.get("method") == "session/cancel")
    elif scenario == "crash":
        sys.stderr.write("boom: fatal error in fake agent\n")
        sys.stderr.flush()
        os._exit(3)
    elif scenario == "caps":
        chunk(session_id, json.dumps(client_capabilities, sort_keys=True))
    elif scenario == "blocks":
        chunk(session_id, str(len(blocks)))
    elif scenario == "framing":
        framing(session_id)
    elif scenario == "page":
        chunk(session_id, blocks[0].get("text", ""))
    elif scenario == "mode":
        chunk(session_id, "mode:" + mode)
    elif scenario == "home":
        chunk(session_id, "home:" + os.environ.get("HOME", ""))
    elif scenario == "diag":
        chunk(session_id, "[context] skill catalog shortened 104 descriptions: effective=20968 bytes source=compiled default\n")
        chunk(session_id, 'skill discovery warning: candidate "/Users/someone/.claude/skills/example" was skipped because its metadata is invalid (unsupported_multiline); use one safe name and an optional inline description or a >, >-, or | block, then reload skills')
        chunk(session_id, "The user wants the word pong.", "agent_thought_chunk")
        chunk(session_id, "pong")
    elif scenario == "fs":
        next_request_id += 1
        request_id = next_request_id
        send({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "fs/read_text_file",
            "params": {"sessionId": session_id, "path": "/etc/hosts"},
        })
        reply = wait_for(lambda m: m.get("id") == request_id and "method" not in m)
        chunk(session_id, "fs:%s" % reply.get("error", {}).get("code"))
    elif scenario == "fail":
        return -32603, "model unavailable"
    elif scenario == "authfail":
        return -32603, "No provider credentials found"
    elif scenario == "pids":
        helper = subprocess.Popen(["sleep", "300"])
        chunk(session_id, "%d %d" % (os.getpid(), helper.pid))
    update(session_id, {"sessionUpdate": "session_info_update", "title": scenario[:40], "updatedAt": "2026-09-30T14:14:44Z"})
    update(session_id, {"sessionUpdate": "usage_update", "used": 14783, "size": 262144, "cost": {"amount": 0, "currency": "USD"}})
    return "cancelled" if cancelled else "end_turn"


def new_session(message):
    if flag("--fail-session"):
        return error(message["id"], -32603, "no sessions today")
    if flag("--auth-session"):
        return error(message["id"], -32000, "Authentication required")
    if flag("--auth-exit"):
        sys.stderr.write("Error: no provider is connected. Run fx and type /provider.\n")
        sys.stderr.flush()
        os._exit(1)
    result = {"sessionId": "sess-1"}
    if flag("--config-mode"):
        result["configOptions"] = [mode_option()]
    elif not flag("--no-modes"):
        result["modes"] = {"currentModeId": mode, "availableModes": [m for m in MODES if not (flag("--no-ask") and m["id"] == "ask")]}
        result["configOptions"] = [mode_option()]
    respond(message["id"], result)
    update("sess-1", {"sessionUpdate": "available_commands_update", "availableCommands": []})


def main():
    global client_capabilities
    while True:
        message = read_message()
        method = message.get("method")
        if method == "initialize":
            client_capabilities = message["params"].get("clientCapabilities")
            respond(message["id"], {
                "protocolVersion": 1,
                "agentCapabilities": {
                    "loadSession": True,
                    "promptCapabilities": {"image": True, "audio": False, "embeddedContext": True},
                    "mcpCapabilities": {"http": True, "sse": True},
                    "sessionCapabilities": {"list": {}, "resume": {}, "close": {}},
                },
                "agentInfo": {"name": "fake-agent", "title": "fake-agent", "version": "0.0.1"},
                "authMethods": [],
            })
        elif method == "session/new":
            new_session(message)
        elif method in ("session/set_mode", "session/set_config_option"):
            select_mode(message)
        elif method == "session/prompt":
            if mode != "ask":
                trace("prompt-in-" + mode)
                error(message["id"], -32603, "prompted in mode " + mode)
                continue
            outcome = handle_prompt(message["params"])
            if isinstance(outcome, tuple):
                error(message["id"], outcome[0], outcome[1])
            else:
                respond(message["id"], {"stopReason": outcome, "usage": {"inputTokens": 14760, "outputTokens": 23, "reasoningTokens": 0}})


main()
