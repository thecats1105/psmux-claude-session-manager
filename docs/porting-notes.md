# Porting notes

How `tmux-claude-session-manager` was ported from bash/tmux to PowerShell 7 and
[psmux](https://github.com/psmux/psmux), what broke along the way, and what is
still owed upstream.

The README documents the plugin for *users*. This file is the engineering
record: what is **verified**, what was **refuted**, and what psmux itself needs
to fix. Everything here was established by direct experiment on **psmux 3.3.7
(`05cc5d4`)**, Windows 11, PowerShell 7.

Contents:

1. [What the port is](#1-what-the-port-is)
2. [psmux behaviours that shaped the design](#2-psmux-behaviours-that-shaped-the-design)
3. [Problems found, and how they were fixed](#3-problems-found-and-how-they-were-fixed)
4. [Upstream: popup mode's problems, and how to report them](#4-upstream-popup-modes-problems-and-how-to-report-them)
5. [Remaining work](#5-remaining-work)
6. [Syncing with upstream](#6-syncing-with-upstream)

---

## 1. What the port is

A full rewrite. The bash implementation was removed (`git rm`; still in
history). `jq` is gone — PowerShell parses Claude's JSON directly.

| File | Role |
|---|---|
| `claude_session_manager.ps1` | Entry point — reads options, installs the three key bindings |
| `scripts/helpers.ps1` | Option reader, session hash, context lookup, mode resolution, `Get-ClaudeExe` |
| `scripts/state.ps1` | JSON state file (origin window, parent client, entry mode) |
| `scripts/agents.ps1` | Row builder — Claude JSON × pane table × parent-chain join |
| `scripts/launch.ps1` | `prefix`+`y` |
| `scripts/session.ps1` | The dedicated session's actual command — runs Claude, then hands its client back on exit (§3.4) |
| `scripts/list.ps1` | `prefix`+`u` |
| `scripts/detach.ps1` | `prefix`+`d` — smart detach, stock everywhere else (§3.5) |
| `scripts/picker.ps1` | fzf picker + jump |
| `scripts/attach.ps1` | Popup attach wrapper — the fix that makes popup mode work at all |
| `scripts/preview.ps1` | fzf preview (`capture-pane` → transcript fallback) |
| `scripts/kill.ps1` | fzf `ctrl-x` |

Two structural differences from the tmux original are worth calling out,
because they are not stylistic:

- **Agent → pane pairing cannot use the tty.** tmux joins pid → tty → pane.
  On Windows `#{pane_tty}` is a synthetic label derived from the pane id
  (`%5` → `/dev/pty5`) that no process actually carries. `#{pane_pid}` *is* a
  real Windows pid — of the pane's shell — so `agents.ps1` walks the parent
  chain up from each `claude.exe` until it lands on one.
- **State cannot live in psmux options.** It has to survive being read back
  from a *different* session than the one that wrote it, which no option scope
  does. It lives in `%LOCALAPPDATA%\psmux-claude-session-manager\state.json`.

### Verified working

Load & bindings · pid→pane join · launcher (session creation, attach,
agent registration) · duplicate-popup guard · picker popup starting fzf ·
preview on both paths · fzf sub-commands through `cmd.exe` · state file
round-trip · smart `prefix`+`d` in both modes and in an ordinary session ·
client hand-back on Claude exit · all scripts parse clean.

### Not yet verified — needs real keypresses

- `enter` jump, both kinds (dedicated resume; loose → focus in place)
- `ctrl-x` kill + reload
- `prefix`+`u` pressed **from inside** a session popup (the detach-and-reopen
  path)

These are the highest-value manual tests remaining. The dedicated jump is also
the code path exposed to psmux #483 (§3.2).

---

## 2. psmux behaviours that shaped the design

Several of these contradict the psmux docs, and two contradict things asserted
earlier in this work — flagged as corrections where so.

| Behaviour | Consequence |
|---|---|
| `attach-session` refuses to run inside a popup (`PSMUX_SESSION` set) — *"sessions should be nested with care"*, popup closes instantly | `attach.ps1` clears `PSMUX_SESSION`/`PSMUX_TARGET_SESSION` first. **This was the original port's failure.** |
| `run-shell` does not expand `#{...}`; the format string arrives literally | Scripts call `display-message -p` for their own context; nothing is passed through a binding |
| From a **config file**, `run-shell` only accepts a bare `.ps1` path | A `pwsh -NoProfile -File "..."` command line is silently ignored — no error, the plugin just never loads. Works fine from the CLI, which makes this expensive to find |
| `source-file` applies `bind-key` lines but does **not** re-run `run-shell` | Reloading config wipes plugin bindings without reinstalling them. Restart psmux after config changes |
| psmux strips backslashes in command strings | Every embedded path is forward-slashed |
| A popup runs no shell profile | `~/.local/bin` is off PATH, so `claude` is unresolvable → `Get-ClaudeExe` falls back to known install locations |
| **Runtime `set-option` depends on scope** (corrected — this file previously claimed runtime `set` is discarded outright). `set-option -g @foo bar` is silently discarded. `set-option -t <session> @foo bar`, run *from that session's own pane*, **persists**, is read back by `show-options -t <session>`, and overrides global for that session | `Get-PsmuxOption` reads `-g`, then layers `-t <session>` over it. Reading only `-g` makes a session-scoped setting invisible — the plugin silently runs its default while the user sees their option set (§3.6) |
| A runtime `set-option -t <session> @foo bar` issued from an **external, unattached process** (a plain CLI call, as opposed to a command typed inside that session's own pane) writes the **global** table regardless of `-t` | Measured with a throwaway option name: it appeared in both `-t <session>` and `-g` immediately. Do not build a session-scope test fixture this way — and clean up both scopes if you do |
| `show-options` cannot filter to one `@` option (`-g @foo`, `-g -v @foo`, `-gqv @foo` all dump everything; `show-option` singular does not exist) | Options are read by parsing the whole table |
| Pane/window ids are **per-session** (`%1`, `@1` repeat across sessions) | Every target is written `session:window.pane` |
| `capture-pane` returns empty for a pane in a **detached** session | Preview falls back to the transcript tail |
| `capture-pane` cannot see a popup at all — a popup is not a pane and appears in no psmux listing | Popup contents were read via the Win32 console API (`AttachConsole` + `ReadConsoleOutputCharacterW`), validated against `capture-pane` on a path where both work |
| `display-popup` is asynchronous (returns immediately) | No retry loop is possible; "is a popup open?" is answered by `(attached)` in `list-sessions` |
| **Correction:** a popup running an **ordinary command** is not a client and does not appear in `list-clients`. A popup that **attaches a session** *is* a real client and *does* appear — at the popup's own dimensions | Measured: host client `[120x29]`, popup-nested attach `[78x17]`, both sessions `(attached)` at once, and `list-clients` returned the popup's row. The false half of the old claim was what `Restore-ClaudeClients` originally relied on to be a no-op in popup mode (§3.4) |
| `list-clients` reports **only the single most-recently-active client**, never the full roster, even with several genuinely attached to different sessions | The row's session field is accurate; it just omits every other client. `Get-PsmuxClientsOn` inherits this — it can return empty for a session that has a client, if another client attached elsewhere more recently. Harmless for one-user-one-client; a caveat for two terminals on one server |
| `list-clients -F '<fmt>'` silently ignores `-F` | Fields are parsed out of the default line |
| `list-clients -t <session>` does **not** filter — it re-labels the current client with the target session name, printing a row for a session that has never been attached, and prints its error to *stdout* for an unknown session | Unusable. Only the bare form is used |
| `detach-on-destroy` is accepted, stored, and readable but is a **no-op** | Measured with a real client on `on`/`off`/`previous`: the client detached when its session died in all three cases. It also does not appear in the full `show-options -g` dump. There is no built-in way to stop a dying session from dropping its client (§3.4) |
| An untargeted `detach-client`, with a session popup open, detaches the **outer** client, not the popup's nested one | The stock `prefix`+`d` therefore drops you off the server instead of closing the overlay (§3.5) |
| `send-keys` into a session that has a **popup-nested attach client** is silently dropped (exit 0, no effect) | Verified against both a `pwsh` and a `claude` pane, with session *and* pane targets; works normally when the session is detached or driven by an ordinary client. This is what makes every "clean the line up afterwards" workaround impossible (§4.2). The plugin uses no `send-keys` — keep it that way |
| `display-popup -w/-h` given a **percentage** resolves it against the window being displayed, not the client | Attaching a session into the popup shrinks that session, permanently and compoundingly (§3.3) |
| `new-session`'s command argument is a **single string**, not argv words | Multiple array elements are joined with spaces and run through the pane's default shell (`pwsh.exe -NoLogo -Command "<joined>"`) — verified by reading the spawned pane's own `CommandLine`. The wrapper is passed as one pre-quoted element |
| psmux copies the invoking client's env into new panes — **non-deterministically per variable** | `CLAUDE_PID` propagated 6/6, `COLORFGBG` 2/6. To set a variable reliably use `new-session -e`. `show-environment` is the *wrong* instrument for checking this: it reports psmux's `update-environment` state, not the pane's OS process env |
| An agent inheriting a parent Claude's identity never registers with the supervisor | `launch.ps1` strips `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_CHILD_SESSION`, … (keeps `CLAUDE_CONFIG_DIR`). Without this the launched agent is invisible to the picker |
| Client names are **not stable across server restarts** (`/dev/pts/1` one day, `/dev/pts/0` the next), and `display-message -p -t <client>` is wrong — `-t` is a pane target, so psmux answers *"no server running on session '/dev/pts/N'"* | Use plain `display-message -p` for the active client, or `-c <client>` — which prefixes its own arguments to the output, so take the last token |
| A **control-mode client** (`psmux -C attach -t <session>`) registers a real client with no TTY, and `display-popup -c <it>` reproduces the popup bugs exactly | This is what made the whole investigation automatable without a human terminal. Note control-mode clients do **not** appear in `list-clients` either |

### A PowerShell trap, not a psmux one

`Invoke-Psmux` output carries a **trailing blank-line array element**, so a
plain `.Count` on it is off by one — a genuinely single-pane session reads back
as 2. Found while writing the pane guard in `Restore-ClaudeClients`, which now
filters blank lines before counting. Every other `.Count` check in the codebase
happens to use `foreach`/regex, which skips blanks for free, which is why this
had never surfaced.

---

## 3. Problems found, and how they were fixed

### 3.1 OSC colour replies leak into Claude's prompt

**Status: cannot be fixed in the plugin. Avoided by defaulting to `switch`.**
Upstream report owed — see §4.2.

Opening a session in a popup leaves the prompt polluted with terminal palette
replies (`docs/porting-screenshot.png`):

```
]10;rgb:cdcd/d6d6/f4f4\]11;rgb:1e1e/1e1e/2e2e\]4;0;rgb:4545/4747/5a5a\ ...
```

Cosmetic — `Ctrl+U` clears it — but it happened on every launch.

**The colour query is not Claude's. It belongs to the nested attach client.**
The decisive observation: start a session on a bare `pwsh` — no Claude anywhere
— and pop a nested attach onto it. The pane is clean before the attach and
polluted 2–3 s after. `strings` on the binary shows the psmux **client**
emitting `ESC]10;?` / `ESC]11;?` at startup.

So a nested attach client runs *inside a psmux pane*; psmux answers that
client's palette query by injecting console input records (the mechanism added
by [#473](https://github.com/psmux/psmux/issues/473), `b96f6de`, because ConPTY
filters OSC out of the input pipe); and those records land in the attached
session's pane, where whatever is running there echoes them as literal text.

#473 predicted this in its own text: foreground/lifetime checks *"reduce, but
cannot eliminate, the risk that another process attached to the same console
consumes those records"*, and multi-client sessions *"resolve to the most
recent reporter"*. The popup path puts a second client on the session and more
than one process on the same console input buffer.

**Measured** (detection = regex `\]\d+;rgb` over `capture-pane -p`):

| Path / condition | Result |
|---|---|
| Popup + nested `attach-session` (baseline) | **10/10 polluted** |
| Plain `new-window … claude` in the attached session | **0/10 polluted** |
| Claude **directly in a popup**, no `attach-session` | **0/4 polluted** (vs 4/4 for popup-attach, interleaved) |
| `switch-client` instead of nesting | **0/3 shell, 0/2 Claude** |
| `allow-passthrough off` | 2/2 polluted — no effect |
| `COLORFGBG=15;0` via `new-session -e`, propagation verified per run | 6/6 polluted — no effect |
| `PSMUX_HOST_COLORS`, 4 formats × session env, nested-client env, and server env | 9/9 polluted, values unchanged — no effect at any scope |

A popup on its own is fine, and so is a freshly created session. **The nested
attach is the whole trigger.**

#### Refuted mitigations — do not re-test

`send-keys C-u` · `send-keys Escape` · `attach-session -r` · read-only then
flip to read-write · `refresh-client` · `refresh-client -S` · `refresh-client
-C` size jiggle · `resize-window` jiggle · `CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT=1`
· `TERM` = dumb/vt100/xterm/unset · `COLORTERM` unset · `NO_COLOR=1` ·
`allow-passthrough off` · `COLORFGBG` · `PSMUX_HOST_COLORS` at every scope.

The `send-keys` ones never had a chance — see the `send-keys` row in §2.
App-side suppression is a dead end too; #473 already records that
`TERM`/`COLORTERM`/`COLORFGBG` cannot stop an application that actively
queries.

#### Two dead ends worth recording

**Priming the palette does not work — there is no cache.** The plan was to
exploit "the second attach comes back clean". Counting OSC blocks rather than
testing for presence settles it: on a bare `pwsh` pane a throwaway attach
leaves 1 block and the real attach leaves 2. Every nested attach re-injects.
The apparently clean re-attach was **Claude absorbing the injection** — once it
is up and reading stdin it swallows the reply instead of echoing it. The first
attach always lands while Claude is still starting.

**"The reported colours are wrong" was a harness artifact — corrected.** An
earlier reading of this bug held that the injected values are always psmux's
own defaults (`cccc/cccc/cccc`), never the user's palette, and concluded the
reply never reaches the real terminal. `docs/porting-screenshot.png`, captured
in the user's actual terminal, shows the **real** catppuccin values
(`cdcd/d6d6/f4f4`, `1e1e/1e1e/2e2e`) being injected. The `cccc` readings came
from control-mode and console-attached harnesses, where there is no real
terminal to answer and psmux falls back to its defaults. **Do not build the
upstream report on a wrong-palette claim** — the defect is *where the reply is
delivered*, not what it contains.

#### Measurement notes

- **Count OSC blocks, do not test for presence.** Presence cannot distinguish
  "nothing new was injected" from "the app repainted over it".
- **Run Claude in a directory it already trusts.** In an untrusted directory it
  stalls on the folder-trust dialog, never issues a palette query, and every
  condition scores a misleading "clean".
- Confirm colour readings against the raw pane text: `capture-pane` wraps long
  values across lines, and a naive regex then reports a value as absent.

### 3.2 psmux #483 breaks the dedicated jump — *fixed*

[#483](https://github.com/psmux/psmux/issues/483) (open, 3.3.7):
`switch-client -t` accepts a window- or pane-scoped target, exits 0, and
silently ignores it.

`picker.ps1` used `switch-client -c <client> -t "<session>:<windowIndex>"` to
put the outer client back on the launching window, so that jump silently did
nothing. Reproduced directly: a client parked on `w483:0`, given
`switch-client -t w483:2`, exits 0 and stays on `:0`.

**Fixed** by switching to the *session*, then `select-window` as a separate
call — the two-step now used by `picker.ps1`, `detach.ps1` and
`Restore-ClaudeClients` alike. Verified: the two-step form lands on `:2`.

### 3.3 Popup percentage sizing silently destroys sessions — *fixed*

The most damaging bug found in the whole port, and invisible for a long time
because every earlier experiment used a fresh session.

`display-popup -w 90% -h 90%` resolves the percentage against **the window
being displayed**, not the client. Attaching a session into the popup therefore
resizes that session to 90% of its *current* size — and the new size sticks, so
every re-open shrinks it again. Measured on one session, five opens:

```
120x30 → 106x24 → 93x18 → 81x13 → 70x8 → 61x4
```

A handful of `prefix`+`y` presses leaves the user's Claude session at 61×4.

**Fixed** by `Resolve-PopupSize` in `helpers.ps1`: a `NN%` option becomes
absolute cells against `#{client_width}`/`#{client_height}` before the popup
opens. Non-percentage and unparseable values pass through untouched. Verified
through the real plugin scripts: **stable at 106×24 across four opens**, where
the percentage form drifted every time.

### 3.4 A dying session dropped the client off the server — *fixed*

**Symptom.** Under `switch` mode, exiting Claude (`Ctrl+D`) killed the
session's only pane, which killed the session — and psmux detached the client
from the **server**, not just the session. The terminal fell back to a bare
shell; the only way back was `psmux attach`. Popup mode never showed this,
because the client that dies with a popup's nested attach is a throwaway.

**Cause.** No built-in psmux mechanism keeps a client attached across its
session dying; `detach-on-destroy` is inert (§2).

**Fix: make the dying session save its own client before it dies.** The
session's command is no longer the bare `@claude_command` — it is
`scripts/session.ps1`, which runs Claude *in the foreground* (so the wrapper is
Claude's parent and outlives it) and then calls `Restore-ClaudeClients` before
letting its own process exit and the session die behind it. That function:

0. Resolves the mode the session was **entered** under (§3.6) and returns
   immediately unless it is `switch`. The gate is required, not an
   optimisation: a popup's nested attach client *does* register in
   `list-clients`, so an empty client list is not a reliable popup detector.
1. Guards on the session having exactly one pane — a second window or pane
   means the session survives and moving the client would be wrong.
2. Bails if there is no recorded origin, or the origin session is gone; the
   client then just detaches, which is the correct fallback when there is
   nowhere sane to send it.
3. For each client on the session: `switch-client` to the origin session, then
   `select-window` — two calls, per #483.

**Verified end-to-end with real Claude**, launched through the actual wrapper
path: `claude agents --json` picked it up as `kind: interactive`, `agents.ps1`
produced a correct row, and killing the `claude.exe` pid (standing in for
`Ctrl+D`) left the client alive on the recorded origin window.

**`agents.ps1` risk, checked and clear.** The wrapper inserts one more `pwsh`
between the pane and Claude: `claude.exe → pwsh.exe (session.ps1) → pwsh.exe
(== #{pane_pid})`, a depth-2 walk versus the old depth-1, well inside
`Find-Pane`'s 8-hop bound.

### 3.5 Stock `detach-client` takes the outer client — *fixed*

§3.4 fixed *Claude exiting*. It did not fix what a user actually hit:
`prefix`+`d`, the stock `bind-key -T prefix d detach-client`. That gesture is
*detach*, not Claude exiting — a path the §3.4 wrapper never runs on, since
nothing exits.

**Root cause, measured.** With a session popup open, an untargeted
`detach-client` detaches the **outer** client rather than the popup's own
nested attach. Pressed to "go back", it drops the whole client off the server.

**Fix: replace the stock binding, rather than trying to out-guess "current
client".** `scripts/detach.ps1`, bound over `@claude_detach_key` (default
`'d'`, empty opts out):

- No context, or a session that does not start with `@claude_session_prefix`:
  plain `detach-client` — stock behaviour preserved everywhere outside a
  plugin session.
- `switch` mode: `switch-client` to the recorded origin, then `select-window`.
  No detach at all.
- `popup` mode: `detach-client -s <session>` — session-scoped, the primitive
  `list.ps1` already uses to close a session popup. This is the actual fix: it
  never asks *which client is this?* A popup-nested attach is the only client
  that can be on that specific `claude-*` session, so targeting the session
  sidesteps the ambiguity instead of trying to resolve it.

Verified with a real client in all three cases: plain detach in an ordinary
session (client process exited), origin restored and client alive in `switch`
mode, and in `popup` mode the popup session's `session_attached` dropped to 0
while the host's stayed 1 and its client stayed alive.

### 3.6 Which mode a session was *entered* under — *fixed*

`detach.ps1` and `Restore-ClaudeClients` both run with `#{session_name}`
resolved to the **Claude** session, not the session the launch key was pressed
in. Since session-scoped options override global (§2), re-reading
`@claude_jump_mode` from in there can see a genuinely different table than
`launch.ps1` did, letting entry mode and exit mode disagree.

Fixed in two layers:

1. `launch.ps1` resolves the mode once, in the launching session's context, and
   records it in `state.json` next to the origin. Both return paths prefer that
   recorded value.
2. `Get-ClaudeEntryMode` handles origins with no recorded mode (written by an
   earlier version) by falling back to **what is observably true** rather than
   what is configured:

   | Observed | Means | Because |
   |---|---|---|
   | origin session `(attached)` | `popup` | the outer client never left it; the popup's nested client holds the Claude session |
   | origin session not attached | `switch` | the client moved to the Claude session |
   | no usable origin | `switch` | every caller re-checks the origin and falls through to a plain detach; a wrong `popup` would detach by session and take the real client with it |

The fallback matters more than it looks. The first cut fell back to a fresh
`Get-ClaudeJumpMode` read — the one read that cannot work from in there. On
live state this resolved `popup` for a session genuinely entered under
`switch`, which would have run `detach-client -s <claude session>` against the
user's own terminal: the original bug, reappearing on legacy state. Measured
5/5 across all four cases plus recorded-mode-wins.

### 3.7 ppm loads a conflicting plugin

Not a code problem — an environment one, and the user's call, since it is their
dotfile tree.

ppm auto-loads `~/.psmux/plugins/tmux-antigravity-session-manager/`, an earlier
abandoned port that binds the same `y`/`u`. This plugin wins only because its
config line runs *after* ppm's `run`. Verified 4/4 at server start, but it is
order-dependent; removing that plugin directory would make it robust.

### 3.8 A second prefix+y from inside the Claude session corrupted its own origin — *fixed*

**Symptom, reported by a user running `switch` mode with `prefix` rebound to
`Ctrl+t`:** `prefix`+`y` once, then `prefix`+`y` again *from inside the Claude
session it just opened*, then `prefix`+`d` no longer returns to the original
session — no matter how many times it's pressed.

**Cause.** The original bash `launch.sh` had an unconditional guard, checked
before anything else: `[[ "$(tmux display-message -p '#S')" == "$prefix"* ]]`
— if the session the key was pressed in is itself a plugin session, bail out.
The port narrowed this into a **popup-mode-only** check
(`$jumpMode -eq 'popup' -and (Test-PsmuxSessionAttached $session)`, keyed on
the *target* session's attach state) and lost the general case. `detach.ps1`
kept its own equivalent guard (`$context.Session.StartsWith($prefix)`);
`launch.ps1` did not.

Without it, in `switch` mode: the second `prefix`+y press resolves
`$context.Path` to the Claude pane's own cwd, which hashes to the *same*
session it's already in, so the create branch is skipped — but the script
still reaches `Set-ClaudeOrigin -Session $session -Context $context ...`. At
that point `$context.Session` **is** the Claude session, so the origin
recorded for it becomes itself. `detach.ps1`'s `switch` branch then
`switch-client`s to `origin.Session` (itself) and `select-window`s to a window
inside itself — a no-op every time, so `prefix`+d can never reach the real
origin again. The stale popup-only guard didn't fire because it only checks
the popup path.

**Fixed** by restoring the general, mode-independent guard at the top of
`launch.ps1` — `$context.Session.StartsWith($prefix)` — the same check
`detach.ps1` already used, in the same place the original bash plugin had it.

---

## 4. Upstream: popup mode's problems, and how to report them

### 4.0 Why popup mode is the degraded path

`popup` mode is the UX this plugin was originally built around: overlay the
Claude session on top of whatever you are doing. On psmux 3.3.7 it sits on top
of **four separate defects**, and all four have the same root:

> `display-popup -E` running `attach-session` puts a **second client** on the
> session, inside a pane of the first. psmux's client model does not expect
> that arrangement, so anything that has to resolve *which client* — or deliver
> something *to* a client — picks the wrong one or silently gives up.

The plugin works around all four, but only by paying for each one separately.
`switch` mode has none of them, because there is no nested attach at all. That
is why **`switch` is now the default** (`@claude_jump_mode`), with `popup`
still fully supported for anyone who wants the overlay.

| # | Defect | Severity | Plugin workaround |
|---|---|---|---|
| §4.1 | `display-popup` percentage sizing permanently shrinks the attached session | **Data loss** — destroys a working session in ~5 opens | `Resolve-PopupSize` converts to absolute cells |
| §4.2 | Nested attach's OSC colour reply is injected into the session's pane | Cosmetic, but on every open | None possible |
| §4.3 | Untargeted `detach-client` takes the outer client | **Drops you off the server** | `detach-client -s <session>` |
| §4.4 | `send-keys` into such a session is silently dropped | Silent no-op | Uses no `send-keys` |

Three further defects are not popup-specific but were found on the way, and are
worth reporting for their own sake: §4.5 `list-clients`, §4.6
`detach-on-destroy`, §4.7 external `set-option -t`.

### Filing plan

File **separately**, in this order — severity first, and each one stands alone
with a repro that needs no Claude, no plugin, and no PowerShell beyond `psmux`
itself:

1. §4.1 (data loss)
2. §4.3 (drops the client off the server)
3. §4.4 (silent no-op)
4. §4.2 (regression from #473 — reference it, and its own prediction of this)
5. §4.5, §4.6, §4.7 (correctness/API, no urgency)

Every report should state: **psmux 3.3.7 (`05cc5d4`), Windows 11, PowerShell 7
as default-shell**, and — for §4.1–§4.4 — that the arrangement is
`display-popup -E` running `attach-session` on a second session, with
`PSMUX_SESSION`/`PSMUX_TARGET_SESSION` cleared so the attach is permitted at
all. Note in §4.1–§4.4 that a **control-mode client** (`psmux -C attach`) hosts
the popup fine, so the maintainer can reproduce headlessly.

Do **not** claim, in §4.2, that the injected colour values are wrong — see the
correction in §3.1.

### 4.1 `display-popup -w/-h` percentage resolves against the wrong target

**Claim.** A percentage passed to `display-popup -w`/`-h` is resolved against
the window being displayed rather than the client. When the popup attaches a
session, that session is resized to a percentage of *itself*, and the new size
persists after the popup closes — so it shrinks again on every open.

**Repro.**

```sh
psmux new-session -d -s victim
psmux display-message -p -t victim '#{window_width}x#{window_height}'   # 120x30
# repeat 5x, from an attached client:
psmux display-popup -E -w 90% -h 90% 'psmux attach-session -t victim'
psmux display-message -p -t victim '#{window_width}x#{window_height}'
```

**Expected.** The popup occupies 90% of the client; `victim` is unchanged after
the popup closes.

**Actual.** `120x30 → 106x24 → 93x18 → 81x13 → 70x8 → 61x4`.

**Impact.** Destroys a working session with a handful of key presses. This is
the one to lead with.

### 4.2 Nested attach's OSC colour reply is delivered into the session's pane

**Claim.** A psmux client started *inside a psmux pane* emits `ESC]10;?` /
`ESC]11;?` at startup. psmux answers by injecting console input records
(#473's `WriteConsoleInputW` path). With a second client on the session, those
records reach the wrong consumer and are echoed into the attached session's
pane as literal text.

**Repro** — no Claude required, which is the point:

```sh
psmux new-session -d -s victim pwsh -NoProfile -NoLogo
psmux display-popup -E -w 80 -h 20 'psmux attach-session -t victim'
sleep 3
psmux capture-pane -p -t victim | grep -E '][0-9]+;rgb'
```

**Expected.** Nothing. The client that asked should consume its own reply.

**Actual.** The pane contains `]10;rgb:…\]11;rgb:…\]4;0;rgb:…\` — 10/10 runs.
Clean 0/10 for the same session driven by an ordinary client, and 0/4 for
Claude run *directly* in a popup with no `attach-session`.

**Evidence to attach.** `docs/porting-screenshot.png`; the 0/10-vs-10/10 A/B;
the fact that a bare `pwsh` pane is polluted identically to a Claude pane, so
it is not application behaviour.

**Reference #473 directly.** Its own text anticipates exactly this: the
foreground/lifetime checks *"reduce, but cannot eliminate, the risk that
another process attached to the same console consumes those records"*, and
multi-client sessions *"resolve to the most recent reporter"* — flagged there
as *"a fair follow up if they bite anyone in practice."* They have.

**List the refuted workarounds** (§3.1) so the maintainer does not re-suggest
them; in particular `send-keys`-based cleanup cannot work, for the independent
reason in §4.4.

### 4.3 Untargeted `detach-client` detaches the outer client

**Claim.** With a popup-nested attach present, `detach-client` given no target
resolves to the outer client rather than the popup's own.

**Repro.** From a client attached to session `A`, open
`display-popup -E 'psmux attach-session -t B'`, then from inside the popup
press the stock `prefix`+`d`.

**Expected.** The popup's client detaches; the overlay closes; the outer client
stays on `A`.

**Actual.** The outer client detaches from the **server**. The terminal returns
to a bare shell and the user must `psmux attach` again.

**Note for the report.** `detach-client -s <session>` targets correctly, which
is both the workaround and a hint at where the client resolution goes wrong.

### 4.4 `send-keys` into a popup-attached session is silently dropped

**Claim.** While a session has a popup-nested attach client, `send-keys`
targeting that session (or a pane in it) exits 0 and does nothing.

**Repro.** Attach `B` inside a popup as above, then
`psmux send-keys -t B 'echo hello' Enter` from outside. Verified with both
`pwsh` and `claude` panes, and with session *and* pane targets.

**Expected.** The keys arrive.

**Actual.** Exit 0, no effect. Works normally when `B` is detached or driven by
an ordinary client.

**Impact.** Nothing can be scripted into a session while its popup is open —
and it is the reason the obvious workaround for §4.2 is unavailable.

### 4.5 `list-clients` is unreliable

Three distinct problems in one command; probably one issue with three sections.

- **Only the most-recently-active client is listed**, never the full roster,
  even with several clients genuinely attached to different sessions
  (`list-sessions` shows them all as `(attached)`). The printed row's session
  field is accurate; the others are simply omitted.
- **`-F '<fmt>'` is ignored** — the default line is printed regardless.
- **`-t <session>` does not filter.** It re-labels the current client with the
  target session name, so a session that has never been attached still prints a
  row; an unknown session name prints its error to *stdout*.

**Repro.** Attach real clients to two sessions in turn, then compare
`list-sessions` against `list-clients`, `list-clients -F '#{client_name}'`, and
`list-clients -t <never-attached-session>`.

### 4.6 `detach-on-destroy` is accepted but inert

`set-option [-g] detach-on-destroy on|off|previous` exits 0 and reads back
correctly via `show-options -g detach-on-destroy`, but does not appear in the
full `show-options -g` dump and has no effect: measured with a real client on
all three values, the client detached from the server when its session was
killed in every case.

**Repro.** Set the option, attach a real client to session `B`, `kill-session
-t B`, observe the client process. **Expected** for `off`/`previous`: the
client survives and moves to another session.

**Why it matters.** It is the documented answer to "don't drop my client when
its session dies", so its silence costs real time — and forces the workaround
in §3.4.

### 4.7 External `set-option -t <session>` writes global scope

`set-option -t <session> @foo bar` issued from an unattached external process
(a plain CLI invocation, not a command typed inside that session's pane) writes
the **global** table regardless of `-t`; the value then shows up in both
`show-options -t <session>` and `show-options -g`. The same command typed
inside the session's own pane is correctly session-scoped.

**Repro.** From outside psmux: `psmux set-option -t 0 @probe hello`, then
`psmux show-options -g | grep @probe`.

**Impact.** Silently leaks per-session configuration into every session. Also
makes session-scope test fixtures impossible to build from a script, which is
how this was found.

---

## 5. Remaining work

1. **The manual keypress tests in §1** — the only untested paths, and the most
   valuable thing left. `enter`-jump exercises the rewritten §3.2 code.
2. **File §4 upstream**, in the order given in the filing plan.
3. **§3.7** — decide whether to remove the conflicting ppm plugin directory.

## 6. Syncing with upstream

Upstream is bash/tmux; this is a full rewrite, so `git merge`/`cherry-pick`
don't apply. Syncing means reading `git log main..upstream/main` on the
`upstream` remote and re-applying, by hand, whatever still has a PowerShell
equivalent.

**Reviewed and applied through `upstream/main` @ `ac3470e`** (2026-07-26,
5 commits back to the merge-base `7dc8877`):

| Upstream commit | Applied as |
|---|---|
| `8ee9a5c` fix(launch): shell-quote session name in the display-popup command | Quoted `$Session`/`$session` in both embedded command strings — `Enter-ClaudeSession`'s popup branch (`helpers.ps1`) and the `new-session` wrapper command (`launch.ps1`). Same root cause as upstream: `@claude_session_prefix` is user-set and the session name is embedded in a string a child shell/`pwsh` re-parses |
| `55bd4f6` fix(launch): report a missing directory instead of an empty popup | Added a `Test-Path` guard in `launch.ps1`'s create branch only, mirroring upstream's placement — an existing session stays attachable even if its launch directory is gone |
| `76cc206` refactor(helpers): drop cut subprocess from session_hash | N/A — `Get-SessionHash` already hashes via `[System.Security.Cryptography.MD5]` with no subprocess |
| `485a889` refactor(launch): Drop explanatory comments | N/A — upstream's own style choice, not carried over |

Next sync should start from `git log ac3470e..upstream/main` (or re-fetch and
diff from whatever this table's newest hash is).
