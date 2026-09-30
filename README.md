# webkit95

webkit95 is a macOS browser built on `WKWebView` and styled after Internet Explorer 3 and 4 on Windows 95. The left Explorer Bar holds an AI assistant that talks to [fx](https://fx.sh) over the Agent Client Protocol (ACP). It is an homage. Microsoft has nothing to do with it, and all icons and art are original.

Status, decisions and next steps are in [docs/STATUS.md](docs/STATUS.md).

## Features

- The app draws the window frame, menu bar, toolbar, address bar, status bar and dialogs itself, in whole pixels, with a bundled pixel font.
- There are no tabs. A link or script that opens a new page opens a new window and keeps `window.opener`, so sign in pop ups work.
- It has downloads, Find, text size, View Source in a Notepad style window, favorites and a 1996 start page.
- Declutter, in the View menu (Cmd+Shift+D), hides ads, cookie banners, newsletter boxes, promotions and share buttons. TypeSafe's Jev model labels short descriptions of page elements. The page address, title, article text and form values are never sent. Decisions are saved per page template, so a repeat visit makes no API call. Auto Declutter This Site runs it after every load on sites you pick. Hiding is cosmetic, so ad and tracker requests still load. See [docs/declutter.md](docs/declutter.md).
- The Assistant runs `fx acp` and can send the current page's text with your prompt (a checkbox, on by default). Page text is untrusted, so the app puts fx in ask mode before the first prompt. Every tool request stops in a Windows 95 message box that shows the full request until you allow or reject it.

## Requirements

- macOS 14 or later and Xcode with Swift 6.
- A TypeSafe API key, if you want Declutter. Add `export TYPESAFE_API_KEY=...` to your shell profile. webkit95 reads it from its environment, or once per launch from your login shell, keeps it in memory and sends it only to api.typesafe.ai.
- fx, if you want the assistant. Install it with `curl -fsSL https://fx.sh/setup.sh | bash`, then run `fx` and type `/provider` to connect a provider.

## Build and run

```
swift test              # unit tests
scripts/bundle.sh       # builds build/webkit95.app
scripts/run.sh          # runs it with temporary favorites and downloads folders
```

`open build/webkit95.app` launches it with your real favorites and `~/Downloads`.

`WEBKIT95_AGENT_MODEL` sets the fx model. Free gateway models can log prompts, so avoid private pages while you use one. `WEBKIT95_AGENT_COMMAND` runs a different ACP agent instead of fx. The tests use it to run a fake agent.

## Tests

```
swift test                                                   # 132 app and 89 agent tests
WEBKIT95_REAL_AGENT=1 swift test --filter RealFxTests        # needs fx and a provider
scripts/smoke.sh                                             # end to end, the app stays in the background
SMOKE_ONLY=declutter scripts/smoke.sh                        # only Declutter, against the fake scripts/fakejev.py
DECLUTTER_REAL=1 python3 scripts/declutter-eval.py out.jsonl /declutter/cookie-wall.html   # real Jev, paid calls
scripts/device-qa.sh                                         # real clicks and keys, waits until you are idle
```

`scripts/smoke.sh` drives the app through a loopback socket protected by a per launch token. The socket exists only in debug builds started with `WEBKIT95_CONTROL=1`. See [docs/control.md](docs/control.md).

## Safety

- fx runs with a private HOME. Otherwise it scans `~/.claude/skills` and similar folders and, by its own report, adds a catalog of their names and descriptions to each request. See [docs/agent-notes.md](docs/agent-notes.md).
- Release builds (`WEBKIT95_RELEASE=1 scripts/bundle.sh`) have no control socket and no Web Inspector, and always send Declutter requests to https://api.typesafe.ai.

## Font and third party code

The Ark Pixel 12px font is used under the SIL Open Font License 1.1. The license is in `Resources/Fonts/OFL-ArkPixel.txt`.

Declutter ports ideas and short code from [kitze/unclutter](https://github.com/kitze/unclutter) (MIT). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
