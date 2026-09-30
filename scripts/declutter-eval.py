"""Real Declutter evaluation against TypeSafe's Jev. Every page that is not cached costs one paid
API call, so it runs only with DECLUTTER_REAL=1 and stops before DECLUTTER_MAX_CALLS (default 12).

It launches build/webkit95.app in the background (never activated) with a temp support dir and
without TYPESAFE_API_KEY or JEV_KEY in its environment, so the app must find the key through its
one login shell probe. The key never passes through this script. For each page it records what Jev
saw and hid, whether anything protected or main content disappeared, latency, request and response
sizes and token usage, then undoes the hiding.

Usage: DECLUTTER_REAL=1 python3 scripts/declutter-eval.py <out.jsonl> <url or /local/path> ...
Local paths are served by scripts/testserver.py on 127.0.0.1."""

import json
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT, WEB_PORT = "9398", "8801"
TOKEN_FILE = os.path.join(ROOT, "build", "control-eval.token")
APP = os.path.join(ROOT, "build", "webkit95.app", "Contents", "MacOS", "webkit95")
MAX_CALLS = int(os.environ.get("DECLUTTER_MAX_CALLS", "12"))

PROBE = r"""(() => {
  const vis = (e) => e.checkVisibility ? e.checkVisibility() : !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
  const ordinary = (f) => !!f.querySelector('textarea,input[type=password],input[type=search]')
    || [...f.querySelectorAll('input')].filter((i) => !['hidden','checkbox','radio','submit','button','image','reset'].includes((i.type || 'text').toLowerCase())).length > 1;
  const out = {};
  for (const s of ['main', 'article', '[role=main]', 'nav', '[role=navigation]', 'header', 'h1', 'textarea', 'input[type=search]', 'input[type=password]']) {
    out[s] = [...document.querySelectorAll(s)].filter(vis).length;
  }
  out['ordinary form'] = [...document.querySelectorAll('form')].filter(ordinary).filter(vis).length;
  let best = null, n = 0;
  for (const p of document.querySelectorAll('p')) { const l = (p.textContent || '').length; if (l > n) { n = l; best = p; } }
  out['largest paragraph'] = best ? (vis(best) ? 1 : 0) : 0;
  out.text = document.body ? document.body.innerText.length : 0;
  return JSON.stringify(out);
})()"""


def ctl(*args, wait=10):
    env = dict(os.environ, WEBKIT95_CONTROL_PORT=PORT, WEBKIT95_CONTROL_TOKEN_FILE=TOKEN_FILE, CTL_WAIT=str(wait))
    out = subprocess.run([os.path.join(ROOT, "scripts", "ctl.sh"), *args], env=env, capture_output=True, text=True, timeout=wait + 20).stdout
    try:
        return json.loads(out)
    except ValueError:
        return {}


def state():
    return ctl("state")


def wait(pred, seconds):
    end = time.time() + seconds
    while time.time() < end:
        s = state()
        try:
            if s and pred(s):
                return s
        except (KeyError, IndexError):
            pass
        time.sleep(0.3)
    return state()


def js(code):
    # The control protocol is one line per command.
    r = ctl("js", " ".join(code.split("\n")), wait=20).get("result")
    return json.loads(r) if isinstance(r, str) else r


def main():
    if os.environ.get("DECLUTTER_REAL") != "1":
        sys.exit("refusing: set DECLUTTER_REAL=1, each uncached page is a paid Jev call")
    out_path, targets = sys.argv[1], sys.argv[2:]
    scratch = tempfile.mkdtemp(prefix="webkit95-eval.")
    server = subprocess.Popen([sys.executable, os.path.join(ROOT, "scripts", "testserver.py"), WEB_PORT], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    env = {k: v for k, v in os.environ.items() if k not in ("TYPESAFE_API_KEY", "JEV_KEY", "WEBKIT95_JEV_URL", "WEBKIT95_JEV_TIMEOUT", "WEBKIT95_AGENT_COMMAND")}
    env.update(WEBKIT95_CONTROL="1", WEBKIT95_CONTROL_PORT=PORT, WEBKIT95_CONTROL_TOKEN_FILE=TOKEN_FILE, WEBKIT95_BACKGROUND="1",
               WEBKIT95_SUPPORT_DIR=os.path.join(scratch, "support"), WEBKIT95_DOWNLOAD_DIR=os.path.join(scratch, "downloads"),
               WEBKIT95_AGENT_COMMAND="python3 " + os.path.join(ROOT, "Tests", "Webkit95AgentTests", "Resources", "fake_agent.py"))
    log = open(os.path.join(ROOT, "build", "eval.log"), "w")
    app = subprocess.Popen([APP], env=env, stdout=log, stderr=log)
    results = []
    try:
        wait(lambda s: s["windows"], 20)
        ctl("resize", "1100x800")
        for target in targets:
            url = target if target.startswith("http") else "http://127.0.0.1:%s%s" % (WEB_PORT, target)
            if state()["declutter"]["apiCalls"] >= MAX_CALLS:
                print("stop: call budget reached")
                break
            ctl("navigate", url)
            time.sleep(1)
            wait(lambda s: not s["windows"][0]["loading"], 45)
            time.sleep(3 if target.startswith("http") else 0.5)
            before = js(PROBE)
            calls_before = state()["declutter"]["apiCalls"]
            ctl("press", "view.declutter")
            s = wait(lambda s: s["windows"][0]["dialogs"] or s["windows"][0]["declutter"]["phase"] != "running", 5)
            if any(d["kind"] == "declutter-consent" for d in s["windows"][0]["dialogs"]):
                ctl("dialog", "declutter-consent", "ok")
                time.sleep(0.3)
            s = wait(lambda s: s["windows"][0]["declutter"]["phase"] != "running" or s["windows"][0]["dialogs"], 40)
            w = s["windows"][0]
            after = js(PROBE)
            lost = {k: before[k] - after[k] for k in before if k != "text" and after.get(k, 0) < before[k]} if before and after else {}
            row = {
                "target": target, "title": w["title"], "status": w["declutter"]["last"]["status"] or w["status"],
                "dialogs": [d.get("message", d["kind"]) for d in w["dialogs"]],
                "apiCalls": s["declutter"]["apiCalls"] - calls_before,
                "last": w["declutter"]["last"],
                "protectedLost": lost,
                "textBefore": before.get("text") if before else None, "textAfter": after.get("text") if after else None,
            }
            results.append(row)
            print(json.dumps({k: row[k] for k in ("target", "status", "apiCalls", "protectedLost", "dialogs")}))
            for d in w["dialogs"]:
                ctl("dialog", d["kind"], "ok")
            if w["declutter"]["phase"] == "applied":
                ctl("press", "view.undoDeclutter")
                time.sleep(0.5)
        total = state()["declutter"]["apiCalls"]
        print("real API calls this run: %d" % total)
    finally:
        with open(out_path, "w") as f:
            for r in results:
                f.write(json.dumps(r) + "\n")
        ctl("quit")
        try:
            app.wait(10)
        except subprocess.TimeoutExpired:
            app.kill()
        server.kill()


main()
