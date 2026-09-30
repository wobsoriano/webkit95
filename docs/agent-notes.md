# Webkit95Agent notes

The assistant's ACP client. It runs `fx acp` (https://fx.sh) and holds the session in fx's ask
mode, because the page text it sends is untrusted input to an agent that runs tools.

## Running fx

- Install fx: `curl -fsSL https://fx.sh/setup.sh | bash`. The binary lands in `~/.local/bin`
  unless `FX_INSTALL_DIR` says otherwise.
- Connect a provider before starting the assistant: run `fx` in a terminal and type `/provider`
  or run `fx setup` (fx 0.0.12 keeps an API key in the macOS login keychain), or set
  `AI_GATEWAY_API_KEY`, `VERCEL_OIDC_TOKEN` and `FX_PROVIDER` in the app's environment. The app
  passes them to fx untouched and never logs or stores them. fx has no documented free model, so a
  real run uses your provider.
- `WEBKIT95_AGENT_MODEL` becomes `fx acp --model <id>`. It must be one plain id (letters, digits,
  `._/:@+-`, no leading dash), else the assistant is Unavailable and says so.
- `WEBKIT95_AGENT_COMMAND` runs another ACP agent through `/bin/sh -c`. Tests and scripts point it
  at `Tests/Webkit95AgentTests/Resources/fake_agent.py`. The ask mode rules below still apply.
- fx is spawned directly (no shell), in its own process group, with the app's environment, HOME
  replaced by the private fx home below, and the working directory set to
  `$TMPDIR/webkit95-agent-workspace` (mode 0700), which fx uses as its workspace. A bare `fx` is looked up on the login shell PATH (4 s probe), then
  `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.bun/bin`, `~/.cargo/bin`.

## Why fx gets its own HOME

Do not remove this. fx discovers skills in workspace roots and in user roots under HOME
(`~/.fx/skills`, `~/.config/opencode/skills`, `~/.codex/skills`, `~/.claude/skills`,
`~/.agents/skills`, `~/.claw/skills`), and it has no switch to turn that off. It then sends a catalog
of every skill's name and description to the model with each request. Run with the user's real
HOME, fx reported `[context] skill catalog shortened 104 descriptions: effective=20968 bytes` and
the pong prompt cost 14739 input tokens: about 21 KB of the user's private work skills went to a
third party gateway on every browser question, and fx's warnings about those folders showed up as
chat text. With the private HOME the same prompt cost 8664 input tokens and fx reported no catalog
(docs/build-notes-fxhome.md).

- The private HOME is `~/Library/Application Support/webkit95/fx-home`, mode 0700, holding only:
  - `.fx`, a real directory where fx keeps this assistant's own sessions and usage. It cannot be a
    symlink to `~/.fx`: fx 0.0.12 rejects a symlinked `.fx` or `.fx/settings.json`
    (`config user: durable_path_unsafe`, and `fx acp` fails initialize with "Failed to load startup
    state"). So sessions from the browser do not appear in `fx sessions` in a terminal, and settings
    made with `/provider` in a terminal fx (anything fx writes to `~/.fx/settings.json`) do not
    reach the assistant. Use `FX_PROVIDER` and the other variables for those.
  - `Library/Keychains`, a symlink to `~/Library/Keychains`. The Security framework finds the login
    keychain, where fx keeps its API key, through HOME. Without the link fx reports its auth as
    missing.
- The workspace must stay outside the user's home. fx also looks for skills in every folder above
  its workspace (the workspace is not a git repository, and fx walked up to `/Users/<you>` and
  found `~/.claude/skills` there even with the private HOME). With the workspace at
  `~/Library/Application Support/webkit95/agent-workspace` the real app still showed the 104
  description catalog. With a workspace under TMPDIR (`/var/folders/...`) and the private HOME,
  the real fx tests and the scratch probes showed no catalog. The workspace holds nothing: fx keeps
  its sessions in the private HOME, and the app never resumes one.
- `IsolatedHome.prepare` creates what is missing before each launch and never replaces anything:
  a `.fx` that is a symlink or a file, a real `Library/Keychains` directory, or a link pointing
  elsewhere leaves the assistant Unavailable with "The assistant's private fx home is not as
  expected: <path> ... Move it aside, then press Restart."
- Only HOME changes. `AI_GATEWAY_API_KEY`, `VERCEL_OIDC_TOKEN`, `FX_PROVIDER`, TMPDIR and the rest of
  the app's environment still reach fx; PATH is the search path above.
- The `WEBKIT95_AGENT_COMMAND` agent keeps the app's HOME unless `WEBKIT95_AGENT_ISOLATE_HOME=1`,
  which the smoke run uses to check the layout with the fake agent.

## Permission modes

fx has three permission modes: `ask` asks before sensitive actions, `auto` (the default) runs
routine work directly and has a model review the rest, and `full-access` checks nothing. Over ACP
they appear as the modes `ask` and `code` (auto). fx 0.0.12 advertises both in session/new, as
`modes` (ask and code, names Ask and Code) and again as a `mode` config option of category `mode`,
and reported `currentModeId: ask` in every capture, whatever `FX_PERMISSION_MODE` said
(docs/fx-wire-capture.md). The client does not rely on that.

The client forces ask:

- The child gets `FX_PERMISSION_MODE=ask`, overriding any inherited value. Against fx 0.0.12 the
  variable made no visible difference; it stays as a backstop only.
- session/new must advertise ask, as `modes.availableModes[].id` or as a select config option of
  category `mode`. The client then sends `session/set_mode` (or `session/set_config_option`) for
  ask. `ready` is emitted, and prompts are accepted, only after the agent confirms: a successful
  set_mode answer (fx answers `result: null` and sends no current_mode_update), or a
  set_config_option answer whose mode option reads ask.
- It fails closed, killing fx and showing Unavailable with Restart, when ask is not advertised,
  the switch is refused, or no answer arrives within 10 s.
- A later `current_mode_update` or `config_option_update` naming another mode cancels the running
  turn at once and selects ask again. That happens once per session; another departure, or a
  refused or unanswered switch back, kills fx.
- Permission requests are never answered automatically. Each is held until the user picks a
  button, the turn is cancelled, or the client shuts down. The buttons map by ACP kind
  (allow_once, allow_always, reject_once, reject_always). fx sends the options `allow_once` "Allow
  once", `allow_always` "Allow for this session" and `reject_once` "Reject", ids equal to kinds.
  Only an option without a kind is matched by its label (Yes, "Yes, and don't ask again", No, and
  those three names).
- The request's detail is the tool call's raw input (the command line when it is only a command,
  else pretty JSON), else the text in its content, else its locations, else its title, with fields
  from earlier tool_call updates for the same id filled in. fx's shell tool sends
  `{action: run, command: ...}`, shown as the command line, sometimes with a `cwd`, then shown as
  JSON so the directory is visible. Hidden characters are escaped and it is capped at 4000
  characters.
- A rejected request comes back as `tool_call_update` with status failed and fx's
  `tool_permission_denied` text; a cancelled one gets no tool update, only the cancelled stop
  reason.
- Update kinds the library does not surface (fx's available_commands_update right after
  session/new, session_info_update and usage_update after every reply) produce no event.

## Errors the user sees

- fx missing: "fx not found. Install it with: curl -fsSL https://fx.sh/setup.sh | bash, then
  connect a provider by running fx and typing /provider."
- ACP auth_required (-32000), or an initialize, session/new or prompt error, or startup stderr,
  that mentions a provider, authentication, credentials, login, signing in or an API key: "fx has
  no provider connected. Run fx in a terminal and type /provider." fx 0.0.12 without a provider
  fails initialize with -32600 "fx needs access to Vercel AI Gateway. Run fx login to sign in, fx
  setup to use an API key, or set AI_GATEWAY_API_KEY."; that line is shown too.
- The Explorer Bar status line reads Unavailable, and the reason is an error line in the
  transcript.
- fx streams its own diagnostics as assistant text before the model answers (`[context] skill
  catalog ...`, `[context] project instructions ...`, `[context] MCP ...`, `skill discovery
  warning: ...`). With the private HOME the skill ones no longer appear. Any that still arrive go
  into one collapsed "fx diagnostics" item with a [+] expander, never into the answer. Only a chunk
  that starts with one of those prefixes counts, and only before the model's first text, thought
  or tool call in the turn (`ChatModel.isFxDiagnostic`), so an answer is never folded away.

## How it fits together

- `AcpClient` owns an AsyncStream inbox. Public methods, stdout messages, stderr lines, the launch
  result, child exit, stop deadlines and ask deadlines all become `Input` values on it.
- One detached task runs `AgentMachine.step(input) -> [Effect]` and performs the effects (emit,
  send, closeStdin, signal, scheduleStopDeadline, scheduleAskDeadline, launch). Events come out of
  that task only.
- `Launcher.launch` runs on its own thread: resolve (PATH probe once per process), posix_spawn in a
  new process group, then reader threads and a reaper thread feed the inbox.
- `Child.reap` waits with WNOWAIT, kills the whole group while the zombie still pins the pid, then
  reaps. `deinit` also kills the group synchronously in case the app is quitting.

## Tests

- `swift test` runs the offline tests against `fake_agent.py`, which speaks fx 0.0.12's wire shapes
  as captured in docs/fx-wire-capture.md (modes plus the mode config option, set_mode answering
  null, available_commands_update, message ids, session_info_update and usage_update, fx's option
  ids and names), starts in code so the switch to ask is proven, and has flags for each fail closed
  path. `--trace <file>` records every method it receives, which is how the tests prove no prompt
  went out before ask was confirmed.
- `WEBKIT95_REAL_AGENT=1 swift test --filter RealFxTests` runs against the real fx: handshake in
  ask mode, a synthetic prompt, and a held, then denied, permission. It needs fx and a provider,
  and uses the free gateway model `inclusionai/ling-3.1-flash-free` unless `WEBKIT95_AGENT_MODEL`
  says otherwise. Verified on 2026-09-30 against fx 0.0.12 (docs/build-notes-fxreal.md).
