# Dev control socket

The control socket lets `scripts/smoke.sh`, `scripts/shots.sh` and `scripts/device-qa.sh` drive a
running webkit95 without the keyboard or the screen.

## Safety

- It exists only in debug builds. `WEBKIT95_RELEASE=1 scripts/bundle.sh` builds without it.
- It is off unless the app starts with `WEBKIT95_CONTROL=1`.
- It listens on 127.0.0.1 only, port `WEBKIT95_CONTROL_PORT` (default 9395).
- Each launch writes a new random token (32 bytes as hex) to `WEBKIT95_CONTROL_TOKEN_FILE`
  (default `build/control.token`) with mode 0600. The file is created with `O_EXCL | O_NOFOLLOW`
  after an unlink, so a planted file or symlink is never written through.
- Every command line must start with the token. Without it the reply is
  `{"error":"unauthorized: every command starts with the token"}`.
- Any process of the same user can read the token and drive the app, including answering an
  agent permission box. Never turn it on in normal use.

## Protocol

Send one line, `<token> [@<window>] <command> [argument]`, and read one JSON line back.
`@<window>` picks a browser window by index (creation order, from 0). Without it, the command
acts on the key window, or the last window.

`scripts/ctl.sh <command ...>` adds the token and prints the reply.

## Commands

| Command | Effect |
| --- | --- |
| `state` | Windows (title, url, loading, status, zone, dialogs with a permission box's buttons and a message box's text, open menu, find, chat with restartVisible, declutter with its phase, Auto flag and last run: candidates, rules, decisions, sizes, latency, tokens), Notepad windows, downloads, favorites, typed addresses, declutter (API call count, consent, Auto hosts, saved templates), whether the app is active. |
| `navigate <text>` | Types `<text>` into the address bar and presses Return. |
| `press <command id>` | Runs a menu command by id, for example `go.back`, `view.textSize.largest`, `favorites.open <url>`. Ids are in `Command.id` in `Sources/Webkit95Kit/MenuModel.swift`. Disabled commands answer with an error. |
| `js <code>` | Evaluates JavaScript in the page and returns `{"result": ...}`. |
| `click-element <css>` / `context-element <css>` | Posts a left or right click on the element straight into the web view. The page sees a user gesture. Nothing goes through the global event stream. |
| `dialog <kind> <button id> [text]` | Presses a button in the dialog of that kind. The optional text goes into the dialog's first field first. |
| `dialog-key tab\|return\|escape\|left\|right\|space` | Sends one key to the top dialog. |
| `menu-open <index>` / `menu-press <label>` / `menu-close` | Opens a Win95 menu bar menu, presses a row in the deepest open menu, closes menus. |
| `address-list` | Opens the address drop down. |
| `chat-send <text>`, `chat-include on\|off`, `chat-stop`, `chat-restart`, `chat-toggle <id>` (opens or closes a Thinking or fx diagnostics item) | Drives the Assistant. With the fake agent, the text picks a scenario (see the top of `fake_agent.py`), for example `mode`, `tool` or `flip`. |
| `permit reject\|once\|session` | Answers the open permission box. |
| `frame <part>` | Screen rect (points, top left origin) of `menu:<i>`, `toolbar:<command id>`, `titlebar`, `close`, `maximize`, `address`, `splitter`, `grip`, `window`, `dialog:<button id>` or `element:<css>`. Used by device QA to aim real clicks. |
| `front` / `back` / `notepad-front` | Orders a window in front of other apps without activating webkit95, or back. |
| `resize WxH`, `maximize`, `close-window` | Window geometry. |
| `gallery` / `gallery-close` | Opens the Win95 component gallery window. |
| `quit` | Quits the app. |
