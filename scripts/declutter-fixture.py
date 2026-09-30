"""Turns a real Declutter run into a regression fixture for the replay test
(Tests/Webkit95KitTests/DeclutterTests.swift, ReplayTests), so the guard can be tested against the
real page again without another paid call.

Inputs are control socket `state` dumps or scripts/declutter-eval.py rows, any number, merged: the
candidates and decisions come from the first input that has them (a run that called Jev), the
measurement from the first that has one (a run with WEBKIT95_DECLUTTER_DEBUG=1). The fixture keeps
public page structure only: each candidate's id, selector, tag, position and count, its signals cut
to 80 characters (class, id and test id tokens as the control socket already shows them), the
answers in the wire shape, and the measurement (facts, frames, nesting; no text). It refuses to
write anything that looks like an address or an email.

Usage: python3 scripts/declutter-fixture.py <out.json> --page <url> --window WxH [--note text]
       [--expect-plan hide|nothing|refuse] [--expect-skipped N] [--naive-refusal]
       [--expect-hidden sel,sel] [--expect-visible sel,sel] <input.json> ...
--naive-refusal records that summing every matched element's area (the guard before the fix)
would have refused the page, which the replay test then asserts."""

import argparse
import datetime
import json
import re
import sys


def last_of(data):
    if "windows" in data:
        return data["windows"][0]["declutter"]["last"]
    if "last" in data:
        return data["last"]
    return data


def main():
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("--page", required=True)
    p.add_argument("--window", required=True)
    p.add_argument("--note", default="")
    p.add_argument("--expect-plan", default="hide", choices=["hide", "nothing", "refuse"])
    p.add_argument("--expect-skipped", type=int, default=0)
    p.add_argument("--naive-refusal", action="store_true")
    p.add_argument("--expect-hidden", default="")
    p.add_argument("--expect-visible", default="")
    p.add_argument("inputs", nargs="+")
    a = p.parse_args()
    candidates, decisions, measure, rules, statuses = None, None, None, None, []
    for path in a.inputs:
        with open(path) as f:
            last = last_of(json.load(f))
        if last.get("candidates") and last.get("decisions") and candidates is None:
            candidates, decisions = last["candidates"], last["decisions"]
        if last.get("measure") and measure is None:
            measure = last["measure"]
        if last.get("rules") and rules is None:
            rules = last["rules"]
        if last.get("status"):
            statuses.append(last["status"])
    if not (candidates and decisions and measure):
        sys.exit("need candidates and decisions from a run that called Jev, and a measure from a WEBKIT95_DECLUTTER_DEBUG=1 run")
    answers = {}
    for d in decisions:
        entry = {"type": "choice", "choice": d["choice"]}
        if d.get("probability") is not None:
            entry["probabilities"] = {d["choice"]: d["probability"]}
        if d.get("confidence") is not None:
            entry["confidence"] = d["confidence"]
        answers[d["id"]] = entry
    fixture = {
        "page": a.page,
        "captured": datetime.date.today().isoformat(),
        "window": a.window,
        "note": a.note,
        "statusesSeen": statuses,
        "candidates": [{"id": c["id"], "selector": c["selector"], "tag": c["tag"], "position": c["position"],
                        "count": c.get("count", 1), "signals": c.get("signals", "")[:80]} for c in candidates],
        "answers": answers,
        "rules": rules or [],
        "measure": measure,
        "expected": {
            "plan": a.expect_plan,
            "skipped": a.expect_skipped,
            "naiveRefusal": a.naive_refusal,
            "hidden": [s for s in a.expect_hidden.split(",") if s],
            "visible": [s for s in a.expect_visible.split(",") if s],
        },
    }
    text = json.dumps(fixture, indent=1, sort_keys=True)
    # The measurement is numbers by nature; the signals are where a page could leak something.
    signals = json.dumps(fixture["candidates"])
    for pattern, where in ((r"https?://", text), (r"[\w.+-]+@[\w-]+\.\w+", text), (r"\d{6,}", signals)):
        if re.search(pattern, where):
            sys.exit("refusing: the fixture would hold something that looks like an address, an email or a long number (%s)" % pattern)
    with open(a.out, "w") as f:
        f.write(text + "\n")
    print("%s: %d candidates, %d answers, %d rules, %d measured elements" % (
        a.out, len(fixture["candidates"]), len(answers), len(fixture["rules"]), sum(len(r["elements"]) for r in measure["rules"])))


main()
