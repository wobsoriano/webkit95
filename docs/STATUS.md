# webkit95 status

webkit95 is a macOS browser on WKWebView, written in Swift, dressed as Windows 95 era Internet
Explorer 3 and 4. It is an homage, not affiliated with Microsoft. All art is original.

## Build and run

```sh
swift test                       # unit tests (Webkit95Kit and the agent library)
scripts/bundle.sh                # build/webkit95.app, debug, ad hoc signed
scripts/run.sh                   # runs it with temp favorites and downloads, log in build/run.log
open build/webkit95.app          # a normal launch with your real favorites and ~/Downloads
scripts/smoke.sh                 # end to end checks, app stays in the background
scripts/shots.sh [name ...]      # screenshots into build/shots (2x and exact 1x)
scripts/device-qa.sh             # real clicks and keys, only after 60 s of user idle
WEBKIT95_RELEASE=1 scripts/bundle.sh   # release build, no control socket, no Web Inspector
```

The assistant runs `fx acp` (https://fx.sh). Install fx with
`curl -fsSL https://fx.sh/setup.sh | bash`, then connect a provider by running `fx` and typing
`/provider`, or set `AI_GATEWAY_API_KEY`, `VERCEL_OIDC_TOKEN` and `FX_PROVIDER`, which the app passes
to fx untouched. `WEBKIT95_AGENT_MODEL` picks the model (`fx acp --model <id>`).
`WEBKIT95_AGENT_COMMAND` runs another ACP agent; tests and scripts use the fake agent.

fx's ACP modes are ask and code (its default, which runs routine work unasked). The app always puts
the session in ask mode before the first prompt, and stops the assistant if fx does not offer ask,
refuses it, or leaves it twice. Every permission request waits for the user. See docs/agent-notes.md.

fx runs with a private HOME (`~/Library/Application Support/webkit95/fx-home`, holding only its own
`.fx` folder and a symlink to `~/Library/Keychains` for the stored login) and a workspace under the
temp folder. fx otherwise discovers skills from `~/.claude/skills` and similar folders and, judging
by its own report, adds a roughly 21 KB catalog of their names and descriptions to every request.
That leaked private skill names to the model provider, so do not remove the isolation. The cost is
that assistant sessions do not appear in a terminal's `fx sessions`.

## Declutter (done 2026-09-30)

View > Declutter Page (Cmd+Shift+D), Undo Declutter and Auto Declutter This Site. TypeSafe's Jev
(`POST https://api.typesafe.ai/v1/systemone`, `jev-latest`, key from `TYPESAFE_API_KEY` or `JEV_KEY`
in the environment or, once per launch, the login shell) labels up to 60 bounded element
descriptions; no URL, title, article text, form values, cookies or raw HTML are sent. Elements are
hidden only for ad, promotion, newsletter, social or cookie with probability and confidence both at
least 0.9, after protections and a hide guard, through a random attribute, an owned style element
and reversible inline overrides in their own content world. Decisions are cached per template
(origin, policy version, page kind, route family, shell marker), zero rule results included. Full
write up, data sent and limits: docs/declutter.md. Credits: THIRD_PARTY_NOTICES.md (kitze/unclutter,
MIT).

- Unit: 77 declutter tests in Tests/Webkit95KitTests/DeclutterTests.swift (selector grammar,
  protections, candidates, request body, the strict response parser with duplicate id detection and
  fuzzing, guard, template keys, cache, sites, messages, endpoint, key, client over a fake
  transport) and 2 login shell variable probe tests.
- Smoke: scripts/smoke-declutter.sh against scripts/fakejev.py (consent and Cancel, apply,
  protected elements visible, exact DOM after Undo, idempotent re-runs, cache hit on a second
  article with zero calls, Auto on reload, password, payment and start page skips, 401, 429,
  timeout, malformed, oversized, redirect, unknown and duplicate ids, cookie wall with scroll lock,
  missing key, and that recorded request bodies hold no URL, title, article text, form value,
  cookie or HTML).
- Real: 10 Jev calls on 5 synthetic and 3 public pages (allrecipes, BBC technology, Wikipedia), no
  protected element or main text lost, 0.22 to 0.65 s per call, about 71,000 input tokens in all
  (about 0.003 USD). The table is in docs/declutter.md. Two fixes came out of it (overlay text in the
  text guard, "cookie" false positives).
- Open risks: hiding is cosmetic (requests still load); late loaded clutter is not rechecked; no
  re-analyze command, so a redesign keeps a stale template until the policy version changes; any
  password input in the DOM, even a hidden login modal, skips the page; short element text does
  leave the machine (redaction covers URLs, emails and long numbers only); Jev's labels on real
  sites include judgment calls (a recipe rating bar hidden as social); main frame only; the release
  build path was not run end to end (the endpoint rule is unit tested).

## Layout

- `Sources/Webkit95Kit`: pure logic, no AppKit. URL input, favorites and typed address stores,
  download naming, the window state value, the menu table (menus, command ids, shortcuts,
  keyboard movement), dialog focus, the Win95 palette, bevels and pixel art, the start and error
  pages and the scrollbar CSS, the control token, and the chat model.
- `Sources/webkit95`: AppKit views and glue. Every Win95 part is a flipped NSView that draws
  whole pixels without anti aliasing (`Draw.swift`, `Controls.swift`, `ScrollBar.swift`,
  `Menus.swift`, `Dialogs.swift`, `Bars.swift`, `Window.swift`), the browser window controller,
  downloads, the Notepad source window, the Explorer Bar assistant, and the dev control socket.
- `Sources/Webkit95Agent`: the ACP client for fx, which enforces ask mode (docs/agent-notes.md).
- `Resources/Fonts`: Ark Pixel 12px proportional and monospaced (SIL OFL 1.1) with the license.
- `scripts/icons/gen.py`: generates `Sources/Webkit95Kit/Icons.swift`; `scripts/icons/run.sh`
  renders contact sheets.

## How it is verified

- `swift test`: 132 Webkit95Kit tests and 89 agent library tests pass at the last run (3 real fx
  tests are skipped unless `WEBKIT95_REAL_AGENT=1`; with it they pass against fx 0.0.12 on the
  free gateway model).
- `scripts/smoke.sh`: 165 checks pass (98 plus 67 for Declutter) against the real app driven through the control socket (2 more
  are skipped, the opt-in camera check and the fx-not-found check that needs fx to be absent), with
  the app in the background and never activated. It covers navigation, history, the address list,
  menus, the Win95 context menu, popups with `window.opener`, `postMessage` and `window.close()`,
  blocked popups, new windows, alert, confirm (Tab, arrows, Escape, Return), prompt, downloads
  with exact bytes, quarantine, unique names and cancel, Find, text size, View Source,
  toolbar and status bar toggles, favorites, the error page and box, About, the assistant
  (ask mode before the first prompt, streaming, page text in the prompt, the permission box with
  fx's options, reject, allow once and allow for this session, a mode flip stopped then refused),
  the assistant failing closed (no ask mode, no provider, fx not found) with Restart, and clean
  quits.
- `scripts/device-qa.sh`: 18 checks with real clicks and keys behind the idle, frontmost,
  inside window and topmost window gates.
- `scripts/shots.sh`: screenshots read and judged at 1x (see docs/build-notes.md).

## Decisions worth knowing

- The window is borderless. A titled window with a transparent title bar still gets rounded
  corners on macOS 27, which clips the square Win95 frame. Move, resize, zoom, minimize and close
  are driven from the drawn frame and title bar.
- Text uses Ark Pixel at 12 pt, where its 1/12 em grid lands on whole pixels at 1x and 2x. Bold
  is drawn by repeating the glyphs one pixel to the right, as bitmap fonts did.
- Web page scrollbars come from an injected `::-webkit-scrollbar` style. WebKit on macOS draws no
  scrollbar buttons, so the arrows are painted into the scrollbar background and do not scroll
  when clicked.
- The page's context menu keeps WebKit's items but is drawn as a Win95 menu.
- Downloads keep WebKit's own quarantine attribute.

## Known issues and open risks

- The camera and microphone Win95 box is not verified. WebKit asks macOS first, and a dev build
  started from a terminal is attributed to the terminal (an earlier smoke run raised "Allow
  Ghostty to access your camera?"). `SMOKE_MEDIA=1 scripts/smoke.sh` runs the check when someone
  is at the machine.
- Scrollbar arrows on web pages are pictures. Scrollbars in webkit95's own views work fully.
- Web form controls keep WebKit's look, except on the start page.
- Printing uses the macOS print panel.
- Verified against the real fx 0.0.12 on 2026-09-30 with the free gateway model
  `inclusionai/ling-3.1-flash-free` (docs/build-notes-fxreal.md, docs/fx-wire-capture.md): the
  handshake reaches Ready in ask mode, a prompt streams and ends end_turn, fx sends
  session/request_permission in ask mode with the options allow_once, allow_always and
  reject_once, and Reject or Stop leaves the tool unrun. `FX_PERMISSION_MODE` had no visible
  effect on the mode fx reports; the client's own set_mode is what puts the session in ask.
- fx can stream its own diagnostics as assistant text before the model's reply. Those now fold into
  one collapsed "fx diagnostics" item (a prefix rule, only before the model's first output in a
  turn). The free model's first token took 2 s to 148 s in the recorded runs.
- Not verified after moving the workspace under the temp folder: a full real reply in the rebuilt
  app (the real fx tests and probes did run with that layout).
- Still NOT VERIFIED against the real fx: the allow paths (Allow once, Allow for this session), a
  mode change reported by fx itself (current_mode_update never arrived in any capture), the
  set_config_option path (fx also offers modes, so the client never takes it), and the Codex and
  Grok providers.

## Next

1. A real network level ad blocker later, for example filter lists converted to WebKit content rules
   (AdGuard's SafariConverterLib is the first candidate to evaluate).
2. Verify the allow paths against the real fx (Allow once, Allow for this session) and a real reply
   after the workspace move.
3. Verify the camera and microphone box with someone at the machine (`SMOKE_MEDIA=1 scripts/smoke.sh`).
4. Declutter follow ups: recheck late loaded clutter (a bounded mutation observer as in Unclutter),
   a re-analyze command for a stale template, and a per rule keep visible choice.
5. Group fx's own message chunks by `messageId` if a reliable rule appears, and consider a Claude
   or other ACP agent profile if wanted.
