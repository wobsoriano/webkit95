# Declutter checks, sourced by scripts/smoke.sh (uses its ctl, st, check, js, launch_app, quit_app).
# Jev is scripts/fakejev.py on loopback; the app gets a fake key and an empty ZDOTDIR, so neither the
# real key nor the real API is ever involved.

# ---- declutter ------------------------------------------------------------------------------------
JEV_PORT=8799
JEV_URL="http://127.0.0.1:$JEV_PORT"
JEV_RECORD="$SCRATCH/jev-requests.jsonl"
ZDOT="$SCRATCH/zdot"; mkdir -p "$ZDOT"
python3 "$ROOT/scripts/fakejev.py" "$JEV_PORT" "$JEV_RECORD" smoke-fake-key >/dev/null 2>&1 &
JEV_SERVER=$!
for _ in $(seq 1 40); do curl -s "$JEV_URL/__count" >/dev/null && break; sleep 0.1; done
jev_count() { curl -s "$JEV_URL/__count" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])'; }
jev_mode() { curl -s -X POST --data "$1" "$JEV_URL/__mode" >/dev/null; }
# shown '<css>' prints True when the element is displayed.
shown() { js "(() => { const e = document.querySelector('$1'); return !!e && getComputedStyle(e).display !== 'none'; })()"; }
open_page() { ctl navigate "$1" >/dev/null; wait_for 'w[0]["url"]=="'"$1"'" and not w[0]["loading"]' 10; }

DECL_ENV="WEBKIT95_JEV_URL=$JEV_URL/v1/systemone WEBKIT95_JEV_TIMEOUT=2 ZDOTDIR=$ZDOT"
launch_app "python3 $FAKE_AGENT" "$DECL_ENV TYPESAFE_API_KEY=smoke-fake-key"
ARTICLE="$BASE/declutter/news/2026/09/30/city-council-approves-new-park.html"
SAME_TEMPLATE="$BASE/declutter/news/2026/09/29/library-extends-weekend-hours.html"

open_page "$ARTICLE"
check "the synthetic news page loads" 'w[0]["title"].startswith("City Council Approves New Park")' 10
js 'window.__wk95Before = document.documentElement.outerHTML; window.__wk95Before.length' >/dev/null
ctl menu-open 2 >/dev/null
check "View lists Declutter Page, Undo Declutter and Auto Declutter This Site" 'w[0]["menu"]=="menu:View:1"' 5 'w[0]["menu"]'
ctl menu-close >/dev/null
ctl press view.declutter >/dev/null
check "the first Declutter shows the consent box, Cancel is the default" 'any(d["kind"]=="declutter-consent" and d["modal"] and d["default"]=="cancel" for d in w[0]["dialogs"])' 5 'w[0]["dialogs"]'
ctl dialog declutter-consent cancel >/dev/null
sleep 1
check "Cancel does nothing: no request, no consent saved, nothing hidden" 'not w[0]["dialogs"] and s["declutter"]["consented"]==False and w[0]["declutter"]["phase"]=="idle"' 5 's["declutter"], w[0]["declutter"]'
[ "$(jev_count)" = 0 ] && [ ! -e "$SUPPORT/declutter-consent.json" ] && ok "after Cancel the fake Jev saw no request" || bad "after Cancel the fake Jev saw no request" "$(jev_count)"
ctl press view.declutter >/dev/null
wait_for 'any(d["kind"]=="declutter-consent" for d in w[0]["dialogs"])' 5
ctl dialog declutter-consent ok >/dev/null
check "OK saves consent, one request goes out and the status bar reports what was hidden" 'w[0]["declutter"]["phase"]=="applied" and w[0]["status"].startswith("Decluttered: hid ") and s["declutter"]["consented"]' 10 'w[0]["status"], w[0]["declutter"], w[0]["dialogs"]'
[ "$(jev_count)" = 1 ] && ok "exactly one Jev request for the first page" || bad "exactly one Jev request for the first page" "$(jev_count)"
HIDDEN="$(st 'w[0]["status"]')"
for sel in "#cookie-banner" ".newsletter-popup" ".share-bar" "[data-testid=ad-slot-inline]" ".promo-box" "#sidebar-ad"; do
  [ "$(shown "$sel")" = False ] && ok "hidden: $sel" || bad "hidden: $sel" "$HIDDEN"
done
for sel in "article" ".site-nav" ".site-header" ".signin-box" ".comment-form" "textarea" "main"; do
  [ "$(shown "$sel")" = True ] && ok "protected and visible: $sel" || bad "protected and visible: $sel" "hidden"
done
ctl press view.undoDeclutter >/dev/null
check "Undo Declutter brings everything back" 'w[0]["declutter"]["phase"]=="idle" and w[0]["status"]=="Declutter undone"' 5 'w[0]["status"]'
[ "$(js 'document.documentElement.outerHTML === window.__wk95Before')" = True ] && ok "after Undo the DOM serializes exactly as before" \
  || bad "after Undo the DOM serializes exactly as before" "$(js 'document.documentElement.outerHTML.length + " vs " + window.__wk95Before.length')"
ctl press view.declutter >/dev/null
check "Declutter again applies the saved template" 'w[0]["declutter"]["phase"]=="applied" and w[0]["status"].endswith("(saved template)")' 5 'w[0]["status"]'
STYLES1="$(js 'document.querySelectorAll("style").length')"
ctl press view.declutter >/dev/null
check "a third run on the same page" 'w[0]["declutter"]["phase"]=="applied" and w[0]["status"].endswith("(saved template)")' 5 'w[0]["status"]'
[ "$(js 'document.querySelectorAll("style").length')" = "$STYLES1" ] && [ "$(shown "#cookie-banner")" = False ] && ok "re-running is idempotent (one owned style element, same elements hidden)" || bad "re-running is idempotent" "styles $STYLES1 then $(js 'document.querySelectorAll("style").length')"
ctl press view.undoDeclutter >/dev/null
wait_for 'w[0]["declutter"]["phase"]=="idle"' 5
[ "$(js 'document.documentElement.outerHTML === window.__wk95Before')" = True ] && ok "and Undo after repeated runs still restores the exact DOM" || bad "and Undo after repeated runs still restores the exact DOM" "differs"
[ "$(jev_count)" = 1 ] && ok "the saved template needed no further request" || bad "the saved template needed no further request" "$(jev_count)"

open_page "$SAME_TEMPLATE"
ctl press view.declutter >/dev/null
check "a second article with the same template is decluttered from the cache" 'w[0]["declutter"]["phase"]=="applied" and w[0]["status"].endswith("(saved template)")' 5 'w[0]["status"]'
[ "$(jev_count)" = 1 ] && [ "$(shown "#cookie-banner")" = False ] && [ "$(shown "article")" = True ] && ok "with zero API calls" || bad "with zero API calls" "$(jev_count)"

ctl press view.autoDeclutter >/dev/null
check "Auto Declutter This Site turns on for the host and is saved" 'w[0]["declutter"]["auto"] and s["declutter"]["sites"]==["127.0.0.1"]' 5 's["declutter"]'
grep -q '127.0.0.1' "$SUPPORT/declutter-sites.json" 2>/dev/null && ok "declutter-sites.json holds the host" || bad "declutter-sites.json holds the host" "$(cat "$SUPPORT/declutter-sites.json" 2>/dev/null)"
ctl press view.refresh >/dev/null
sleep 0.5
check "with Auto on, a reload declutters by itself after the page loads" 'not w[0]["loading"] and w[0]["declutter"]["phase"]=="applied"' 10 'w[0]["declutter"], w[0]["status"]'
[ "$(jev_count)" = 1 ] && ok "auto mode on a known template makes no API call" || bad "auto mode on a known template makes no API call" "$(jev_count)"
ctl press view.autoDeclutter >/dev/null
check "Auto Declutter turns off again" 'not w[0]["declutter"]["auto"] and s["declutter"]["sites"]==[]' 5 's["declutter"]'

open_page "$BASE/declutter/login.html"
ctl press view.declutter >/dev/null
check "a page with a password field is skipped and says so" 'w[0]["status"]=="Declutter skipped: this page has a password field" and w[0]["declutter"]["phase"]=="idle"' 5 'w[0]["status"]'
open_page "$BASE/declutter/checkout.html"
ctl press view.declutter >/dev/null
check "a page with a payment form is skipped and says so" 'w[0]["status"]=="Declutter skipped: this page has a payment form"' 5 'w[0]["status"]'
[ "$(jev_count)" = 1 ] && [ "$(shown ".promo-box")" = True ] && ok "neither skipped page caused an API call or hid anything" || bad "neither skipped page caused an API call or hid anything" "$(jev_count)"
ctl press go.home >/dev/null
wait_for 'w[0]["title"]=="Welcome to webkit95" and not w[0]["loading"]' 10
ctl press view.declutter >/dev/null
check "the start page is skipped and says so" 'w[0]["status"]=="Declutter skipped: webkit95 pages are not decluttered"' 5 'w[0]["status"]'

# declutter_error '<mode>' '<text in the box>' '<name>' asks the fake for a failure on an uncached page.
DEALS="$BASE/declutter/deals/weekend-roundup.html"
declutter_error() {
  jev_mode "$1"
  local before; before="$(jev_count)"
  open_page "$DEALS?try=$1"
  ctl press view.declutter >/dev/null
  check "$3" 'any(d["kind"]=="declutter-error" and d["modal"] for d in w[0]["dialogs"]) and w[0]["declutter"]["phase"]=="idle"' 10 'w[0]["dialogs"], w[0]["status"]'
  local text; text="$(ctl state | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s["windows"][0]["dialogs"][0]["message"] if s["windows"][0]["dialogs"] else "")')"
  case "$text" in *"$2"*) ok "  its message: $2";; *) bad "  its message: $2" "$text";; esac
  [ "$(shown "[data-testid=leaderboard-ad]")" = True ] && [ "$(jev_count)" = $((before + 1)) ] && ok "  one request, nothing hidden, no crash" || bad "  one request, nothing hidden, no crash" "$(jev_count) requests"
  ctl dialog declutter-error ok >/dev/null
  wait_for 'not w[0]["dialogs"]' 5
}
declutter_error 401 "TypeSafe rejected the API key (HTTP 401)" "a 401 shows the rejected key box"
declutter_error 429 "TypeSafe is busy right now (HTTP 429)" "a 429 shows the busy box"
T0=$(date +%s)
declutter_error timeout "did not answer in time" "a hanging API times out with a box"
[ $(( $(date +%s) - T0 )) -lt 15 ] && ok "  the timeout did not hang the app" || bad "  the timeout did not hang the app" "$(( $(date +%s) - T0 )) s"
declutter_error malformed "could not read" "a malformed body shows a box"
declutter_error oversized "too large" "an oversized body shows a box"
declutter_error redirect "did not follow" "a redirect is refused, the key never follows it"
jev_mode unknown
open_page "$DEALS?try=unknown"
ctl press view.declutter >/dev/null
check "answers for ids nobody asked about and duplicated ids are ignored, the rest applies" 'w[0]["declutter"]["phase"]=="applied" and not w[0]["dialogs"]' 10 'w[0]["status"], w[0]["dialogs"]'
jev_mode ok
open_page "$BASE/declutter/cookie-wall.html"
js 'window.__wk95Before = document.documentElement.outerHTML; getComputedStyle(document.body).overflowY' >/dev/null
ctl press view.declutter >/dev/null
check "a full screen cookie wall is hidden (an overlay's text does not count against the page)" 'w[0]["declutter"]["phase"]=="applied"' 10 'w[0]["status"]'
[ "$(shown "#consent-wall")" = False ] && [ "$(js 'getComputedStyle(document.body).overflowY')" = auto ] && [ "$(shown "article")" = True ] \
  && ok "and its scroll lock is released while the article stays" || bad "and its scroll lock is released while the article stays" "$(js 'getComputedStyle(document.body).overflowY')"
ctl press view.undoDeclutter >/dev/null
wait_for 'w[0]["declutter"]["phase"]=="idle"' 5
[ "$(js 'document.documentElement.outerHTML === window.__wk95Before && getComputedStyle(document.body).overflowY === "hidden"')" = True ] \
  && ok "Undo puts the wall and the scroll lock back exactly" || bad "Undo puts the wall and the scroll lock back exactly" "differs"
check "the app stayed in the background through the declutter checks" 's["active"]==False'

python3 - "$JEV_RECORD" <<'PY' && ok "the fake Jev never received a URL, title, article text, form value, cookie or raw HTML, and always got the fake key" || bad "the fake Jev never received a URL, title, article text, form value, cookie or raw HTML, and always got the fake key" "see above"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
banned = ["127.0.0.1", "city-council", "library-extends", "weekend-roundup", "title-marker-7781", "article-marker-5521",
          "comment-value-marker-3390", "reader-value-marker-8812", "cookie-value-marker-4410", "wk95session", "<div", "<p", "href",
          "Riverside Gazette", "Sign in", "login-panel", "selector", "The city council voted",
          "toc-best-cookie-sheets", "Weekend outlook", "slow moving front"]
problems = []
for r in rows:
    text = json.dumps(r["body"])
    problems += ["banned %r in request %d" % (b, rows.index(r)) for b in banned if b in text]
    if not r["auth_ok"]: problems.append("wrong Authorization header")
    if r["cookie_header"]: problems.append("a Cookie header was sent")
    if r["content_type"] != "application/json": problems.append("content type %r" % r["content_type"])
    els = r["body"]["state"]["elements"]
    if any(set(e) != {"id", "tag", "signals", "text", "position", "count"} for e in els): problems.append("extra element fields")
    if set(r["body"]) != {"model", "state", "questions"}: problems.append("extra top level fields %r" % sorted(r["body"]))
if not rows: problems.append("no requests recorded")
print("\n".join(problems[:10]))
sys.exit(1 if problems else 0)
PY
quit_app "quit after the declutter checks leaves no process behind"

launch_app "python3 $FAKE_AGENT" "$DECL_ENV"
open_page "$BASE/declutter/blog/2026/quiet-morning-walk.html"
BEFORE_NOKEY="$(jev_count)"
ctl press view.declutter >/dev/null
check "without a key the box names the fix" 'any(d["kind"]=="declutter-error" and d["message"].endswith("Set TYPESAFE_API_KEY in your shell profile and relaunch.") for d in w[0]["dialogs"])' 10 'w[0]["dialogs"], w[0]["status"]'
[ "$(jev_count)" = "$BEFORE_NOKEY" ] && ok "and nothing was sent" || bad "and nothing was sent" "$(jev_count)"
ctl dialog declutter-error ok >/dev/null
quit_app "quit after the missing key leaves no process behind"
