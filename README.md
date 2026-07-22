# psmux-claude-session-manager

Run many [Claude Code](https://claude.com/claude-code) sessions across your
projects, each in its own [psmux](https://github.com/psmux/psmux) session — then
**list them, see which are done vs. still working, and jump to one** from a
single popup. Native Windows, no WSL.

This is a PowerShell port of
[craftzdog/tmux-claude-session-manager](https://github.com/craftzdog/tmux-claude-session-manager)
for psmux, the Windows terminal multiplexer.

If you launch Claude per-directory (one nested session per project), you quickly
end up with a dozen of them and no way to tell which are finished without opening
each one. This plugin gives you:

- 🔢 **A central picker** (`prefix` + `u`) listing every running Claude agent —
  several in one project, and any running loose in an ordinary pane.
- 🟢 **Live status** per agent — `working` / `waiting` / `idle` — read straight
  from `claude agents --json`, so you instantly see which need you. No setup.
- 👁️ **A live preview** of each agent's screen right in the picker, falling back
  to the agent's transcript when its session is detached.
- 🎯 **Smart jump** — selecting an agent takes you straight to it, and
  `prefix` + `d` brings you back to the window you came from.
- 🚀 **A launcher** (`prefix` + `y`) that opens/attaches a Claude session for the
  current directory.
- ❌ **Quick kill** (`ctrl-x`) of a finished agent from the picker.

Status needs no configuration. Claude Code publishes each agent's own state and
the picker reads it — there are no hooks to install.

## Prerequisites

- **[psmux](https://github.com/psmux/psmux) ≥ 3.3** — `scoop install psmux`
- **PowerShell 7+** (`pwsh`) — psmux's default shell
- **[fzf](https://github.com/junegunn/fzf)** — the picker UI
- **[Claude Code](https://claude.com/claude-code)** ≥ 2.1.139 — for the
  `claude agents` command (`claude --version` to check)
- Windows 10 / 11

`jq` is **not** required (unlike the tmux original) — PowerShell parses the JSON.

## Install

```powershell
git clone https://github.com/thecats1105/psmux-claude-session-manager "$HOME\.psmux\plugins\psmux-claude-session-manager"
```

Add to your psmux config (`~/.psmux.conf`, `~/.tmux.conf`, or
`~/.config/psmux/psmux.conf`), then reload with
`psmux source-file <your-config>`:

```tmux
run-shell 'C:/Users/<you>/.psmux/plugins/psmux-claude-session-manager/claude_session_manager.ps1'
```

> **Give `run-shell` the `.ps1` path on its own.** From a config file a full
> `pwsh -NoProfile -File "..."` command line is silently ignored — the plugin
> simply never loads, with no error. (That form does work from the CLI, which
> makes this an easy hour to lose.)

> **Use forward slashes** in that path. psmux strips backslashes out of command
> strings, so a `C:\...` path arrives mangled.

> **Load it last.** If you use `ppm`, put this line *after* ppm's `run`. Any other
> plugin that binds `y`/`u` — an older session-manager port, for instance — will
> otherwise take those keys.

> **Keybinding note:** by default the plugin binds `prefix` + `y` (launch) and
> `prefix` + `u` (list). If your config binds those elsewhere, either change the
> options below, or make sure the plugin loads **after** your own bindings so the
> one you want wins.

## Usage

| Key            | Action                                                                          |
| -------------- | ------------------------------------------------------------------------------- |
| `prefix` + `y` | Launch (or re-attach to) a Claude session for the current directory |
| `prefix` + `u` | Open the agent picker                                                           |
| `prefix` + `d` | Detach — from inside a Claude session, returns you to the window you launched it from instead; stock detach everywhere else (see [`@claude_jump_mode`](#full-screen-or-popup-claude_jump_mode)) |

Inside the picker:

| Key                       | Action                                                |
| ------------------------- | ----------------------------------------------------- |
| `enter`                   | Jump to the agent (see [How it works](#how-it-works)) |
| `ctrl-x`                  | Kill the highlighted agent                            |
| `↑` / `↓`, type to filter | fzf navigation                                        |

Agents needing your attention (`waiting`, `idle`) sort to the top.

Every running Claude gets its own row — the picker identifies each by its process,
not by its psmux session. So several agents in one project all show up separately,
as does a Claude you started by hand in an ordinary pane.

## Options

Set any of these **in your psmux config** before the plugin loads (defaults shown):

```tmux
set -g @claude_launch_key     'y'        # prefix key: launch/open for current dir
set -g @claude_list_key       'u'        # prefix key: open the picker
set -g @claude_detach_key     'd'        # prefix key: smart detach (empty = don't bind)
set -g @claude_command        'claude'   # command run in new sessions
set -g @claude_args           ''         # extra args appended to the command
set -g @claude_session_prefix 'claude-'  # psmux session name prefix
set -g @claude_popup_width     '90%'     # popup width  (popup mode only)
set -g @claude_popup_height    '90%'     # popup height (popup mode only)
set -g @claude_fzf_options    ''         # extra options passed to the fzf picker
set -g @claude_jump_mode      'switch'   # 'switch' full-screen, or 'popup' overlay (see below)
```

For example, to skip permission prompts in launched sessions:

```tmux
set -g @claude_args '--dangerously-skip-permissions'
```

> Set options from the **config file** where you can — a **global** (`-g`)
> runtime `set-option -g @foo bar` exits 0 but silently discards the value, so
> it will not be seen. A **session**-scoped runtime `set -t <session> @foo
> bar`, from inside a session's own pane, does persist and is picked up (it
> overrides a global value for that session) — but it is easy to set one this
> way by accident and forget, since nothing marks the option as
> session-local afterwards. If a setting doesn't seem to be taking effect
> globally, check `show-options -t <session>` for a stray override before
> assuming the config file didn't load.

### Full-screen or popup: `@claude_jump_mode`

**`switch` is the default.** Your client moves to the Claude session, which
takes over the whole screen. `prefix`+`d` — or exiting Claude — brings you
straight back to the window you launched from.

```tmux
set -g @claude_jump_mode 'popup'    # overlay instead
```

`popup` shows the session as an overlay on top of your current window, which is
the UX the tmux original was built around. It works, and the plugin actively
works around every problem listed below — but on psmux 3.3.7 that path sits on
top of four separate upstream defects, all of them rooted in the same thing:
a popup with `attach-session` running inside it is a **second client** on the
session, and psmux's client handling does not expect that.

| What you see | Why | What the plugin does |
| ------------ | --- | -------------------- |
| A burst of colour-reply text in the prompt on first open — `]10;rgb:…\]11;rgb:…\]4;0;rgb:…\` | psmux answers the *nested client's* own palette query by injecting it as console input, where it lands in the session's pane as literal text | Nothing can prevent it; it is cosmetic and clears with `Ctrl+U` |
| Your session would shrink a little on every open, permanently | A `%` popup size resolves against the window being displayed, not the client, so attaching re-sizes the session it just attached | Sizes are converted to absolute cells before the popup opens |
| The stock `prefix`+`d` would drop you off the server instead of closing the overlay | With a popup open, an untargeted `detach-client` takes the **outer** client, not the popup's | `prefix`+`d` closes the popup by targeting the session |
| Nothing can be typed into the session from outside while the popup is open | `send-keys` into a popup-attached session is silently dropped | The plugin uses no `send-keys` |

`switch` has none of these, because there is no nested attach to go wrong.
That is the whole reason it is the default. The trade-off is the overlay: you
get the full screen instead of a window on top of your work.

Full write-ups, measurements, and the upstream reports these should turn into
are in [`docs/porting-notes.md`](docs/porting-notes.md) §4.

`prefix`+`d` returns you to the launching window in **either** mode — it
replaces the stock detach binding with one that recognises a Claude session,
and behaves exactly like stock detach everywhere else. Set
`@claude_detach_key ''` to leave your own detach binding alone.

### Customizing the fzf picker

`@claude_fzf_options` is passed straight to `fzf`, so you can add your own bindings.

Here is a vim keybinding example:

```tmux
set -g @claude_fzf_options "\
  --prompt 'nav> ' \
  --bind 'j:down' \
  --bind 'k:up' \
  --bind 'q:abort' \
  --bind 'i:unbind(j,k,q,i,a)+change-prompt(filter> )' \
  --bind 'a:unbind(j,k,q,i,a)+change-prompt(filter> )' \
  --bind 'esc:rebind(j,k,q,i,a)+change-prompt(nav> )'"
```

The picker opens in **nav** mode:

| Key       | Action                                                  |
| --------- | ------------------------------------------------------- |
| `j` / `k` | move down / up                                          |
| `i` / `a` | switch to **filter** mode — type to fuzzy-match         |
| `q`       | close the picker                                        |
| `enter`   | jump to the agent (both modes)                          |
| `esc`     | filter mode → back to nav                               |

Only the bound keys are special in nav mode; any other key still filters as you
type. `$CLAUDE_PICKER` is exported by the picker so your own bindings can reload
the list — e.g. `reload($CLAUDE_PICKER --list)`.

## How it works

- The **launcher** creates a detached `claude-<hash-of-dir>` psmux session,
  records the window it came from, and takes you to it — full-screen, or in a
  popup under `@claude_jump_mode 'popup'`. The session runs `claude` through a
  small wrapper (`scripts/session.ps1`) so that when Claude exits, the session
  can hand your client back to that window before it dies, instead of dropping
  it off the server.
- **`claude agents --json`** is the source of truth for what is running and how it
  is doing. Each Claude session self-reports its state (`busy` / `waiting` /
  `idle`) to a supervisor daemon, which that command publishes.
- **`agents.ps1`** pairs each running Claude with the psmux pane it occupies.
  tmux does this by joining pid → tty → pane; that is impossible on Windows,
  where psmux's `#{pane_tty}` is a synthetic label derived from the pane id
  (`%5` → `/dev/pty5`) that no process carries. Instead `#{pane_pid}` is a real
  Windows pid — of the pane's *shell* — so we walk the parent chain up from each
  Claude until we land on one: `claude.exe → pwsh.exe == #{pane_pid} of %5`.
- The **age column** is the mtime of the agent's transcript — its last sign of
  life. `claude agents --json` reports only `startedAt`, never a last-activity
  time. A brand-new agent that has yet to take a turn shows `-`.
- The **picker** renders those rows with a live `capture-pane` preview. psmux
  returns an empty capture for a pane in a *detached* session, so when there is
  nothing to capture the preview falls back to the tail of the agent's
  transcript — which is always readable.
- On `enter` a **dedicated** agent (in a `claude-*` session) is resumed —
  full-screen, or in a popup over the window it was launched from under
  `popup` mode — while a **loose** one (any other pane) is focused in place.
  `ctrl-x` kills the Claude process itself: a dedicated session dies with its
  last window, and a loose pane keeps the shell that hosted it.
- Pressing `prefix` + `u` **from inside a session popup** detaches that popup
  first (closing it), then reopens the picker full-size on the outer host client.
- `prefix` + `d` replaces the stock detach binding with one that recognises a
  Claude session: it returns you to the window you launched from (`switch`
  mode) or closes the overlay (`popup` mode) instead of detaching your whole
  client from the server. The mode it uses is the one the session was actually
  *launched* under, recorded at launch time — not a fresh read — since
  `@claude_jump_mode` can be session-scoped, and re-reading it from inside the
  Claude session itself would see a different session's option table.

### psmux differences worth knowing

Porting this surfaced several places where psmux diverges from tmux. If you are
writing psmux plugins, these cost real time to find:

- **`attach-session` refuses to run inside a popup.** psmux injects
  `PSMUX_SESSION` / `PSMUX_TARGET_SESSION` into the popup environment and bails
  with *"sessions should be nested with care"*, closing the popup instantly.
  `scripts/attach.ps1` clears both variables first — that is the whole fix.
- **`run-shell` does not expand `#{...}`** in its argument; the format string
  arrives literally. Every script here asks psmux for its own context with
  `display-message -p` instead of taking it from the binding.
- **A popup gets no shell profile**, so `~/.local/bin` is missing from its PATH
  and `claude` cannot be found there. `Get-ClaudeExe` falls back to the known
  install locations.
- **psmux copies the invoking client's environment** into a new session. If the
  launcher runs from inside a Claude session, the new agent inherits that
  session's identity, decides it is a nested child, and never registers with the
  supervisor — making it invisible to the picker. The launcher strips those
  variables.
- **`set-option -g @foo bar` is silently discarded at runtime** — but only at
  **global** scope; `set-option -t <session> @foo bar` from a session's own
  pane persists and overrides global for that session, and `show-options`
  cannot filter to a single `@` option either way. State lives in
  `%LOCALAPPDATA%\psmux-claude-session-manager\state.json` instead of options,
  since it has to survive being read back from a *different* session than the
  one that wrote it. Options are read by parsing the full `show-options -g`
  table, layered with `show-options -t <session>` for the current session.
- **Pane and window ids are per-session, not global** — `%1` and `@1` can exist in
  two sessions at once — so every target is written as `session:window.pane`.
- **`display-popup` is asynchronous** (it returns immediately). A popup running
  an ordinary command does not appear in `list-clients`, but a popup that
  *attaches a session* does — as its own client, at the popup's size — and
  either way, attaching flips the session to `(attached)` in `list-sessions`.

## License

[MIT](LICENSE) © Takuya Matsuyama
