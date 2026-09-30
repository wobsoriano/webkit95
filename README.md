# webkit95

A macOS browser on `WKWebView`, written in Swift and dressed as Windows 95 era Internet Explorer 3 and 4, with an AI assistant in the left Explorer Bar that runs [fx](https://fx.sh) over the Agent Client Protocol (ACP). It is an homage and not affiliated with Microsoft. All icons and art are original.

Status, decisions and next steps are in [docs/STATUS.md](docs/STATUS.md).

## What it does

- A drawn Windows 95 window frame, menu bar, toolbar, address bar, status bar and dialogs, all in whole pixels with a bundled pixel font.
- No tabs, like the original. New pages and pop ups open in new windows and keep `window.opener`.
- Downloads, Find, text size, View Source in a Notepad style window, favorites, and a 1996 start page.
- An Assistant Explorer Bar that runs `fx acp`. Untrusted page text can be included in the prompt, so the app forces fx into ask mode and every tool request waits in a Windows 95 message box that shows the full request.

## Requirements

- macOS 14 or later, Xcode with Swift 6.
- Optional, [fx](https://fx.sh) for the assistant. Install it with `curl -fsSL https://fx.sh/setup.sh | bash`, then run `fx` and type `/provider` to connect a provider.

## Build and run

```
swift test              # unit tests
scripts/bundle.sh       # builds build/webkit95.app
scripts/run.sh          # runs it with temp favorites and downloads
```

`WEBKIT95_AGENT_MODEL` picks the fx model. Free gateway models can log prompts, so keep private pages out of the chat while one is selected. `WEBKIT95_AGENT_COMMAND` runs another ACP agent, and the tests use a fake one.

## Tests

```
swift test                                                   # 55 app and 87 agent tests
WEBKIT95_REAL_AGENT=1 swift test --filter RealFxTests        # needs fx and a provider
scripts/smoke.sh                                             # end to end, app stays in the background
scripts/device-qa.sh                                         # real clicks and keys, waits until you are idle
```

`scripts/smoke.sh` drives the app through a token protected loopback socket that only exists in debug builds when `WEBKIT95_CONTROL=1` is set. See [docs/control.md](docs/control.md).

## Safety notes

- fx runs with a private HOME so it cannot read your other agents' skill folders, see [docs/agent-notes.md](docs/agent-notes.md).
- Release builds (`WEBKIT95_RELEASE=1 scripts/bundle.sh`) have no control socket and no Web Inspector.

## Fonts

Ark Pixel 12px, SIL Open Font License 1.1, see `Resources/Fonts/OFL-ArkPixel.txt`.
