# Shared helpers for psmux-claude-session-manager.
#
# Dot-sourced by every other script. Nothing in here may throw: these run from
# psmux key bindings, where an unhandled error is invisible to the user.

$script:PsmuxExe = $null
$script:PsmuxOptionCache = $null

# Path to the psmux binary. Resolved once; falls back to the bare name so a
# PATH-only install still works.
function Get-PsmuxExe {
    if (-not $script:PsmuxExe) {
        $cmd = Get-Command psmux -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $script:PsmuxExe = if ($cmd) { $cmd.Source } else { 'psmux' }
    }
    $script:PsmuxExe
}

# Run psmux, discarding stderr. $LASTEXITCODE stays meaningful.
#
# Deliberately declares no parameters: with a param block, psmux's own short
# flags (-a, -g, -p, ...) get bound as PowerShell parameter names instead of
# being passed through. Everything lands in $args.
function Invoke-Psmux {
    & (Get-PsmuxExe) @args 2>$null
}

# Repo root as a forward-slashed path. psmux strips backslashes out of
# bind-key and display-popup command strings, so every path we embed in one
# must use '/'.
function Get-PluginRoot {
    (Split-Path -Parent $PSScriptRoot) -replace '\\', '/'
}

# Parse `@name value` lines (from a show-options table) into
# $script:PsmuxOptionCache. String values are quoted, scalars are not — same
# shape for `-g` and `-t <session>`, so both callers share this.
function Merge-PsmuxOptionLines {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        if ($line -match '^\s*(@\S+)\s+(.*)$') {
            $value = $Matches[2].Trim()
            if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[-1] -eq '"') {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $script:PsmuxOptionCache[$Matches[1]] = $value
        }
    }
}

# Get-PsmuxOption <@name> [default]
#
# psmux cannot query a single user option: `show-options -g @foo`, `-g -v @foo`
# and `-gqv @foo` all dump the entire option table (and `show-option`, singular,
# does not exist at all). So we read the table once and parse the `@name value`
# lines out of it.
#
# Session scope is read too, layered over global (session wins on conflict).
# A runtime `set -t <session> @foo bar` is NOT discarded the way a global-scope
# runtime `set -g` is: it persists, and `show-options -t <session>` reads it
# back, in the same `@name "value"` shape as `-g`. Reading only `-g` therefore
# makes a session-scoped setting invisible — the plugin silently runs its
# default while the user sees their option set. See docs/porting-notes.md §2.
function Get-PsmuxOption {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = ''
    )

    if ($null -eq $script:PsmuxOptionCache) {
        $script:PsmuxOptionCache = @{}
        try {
            Merge-PsmuxOptionLines (Invoke-Psmux show-options -g)

            $session = Invoke-Psmux display-message -p '#{session_name}' | Select-Object -First 1
            if ($session) {
                Merge-PsmuxOptionLines (Invoke-Psmux show-options -t $session)
            }
        }
        catch {
            # Leave whatever was built (possibly just the global table, or
            # nothing); every lookup falls back to its default.
        }
    }

    $value = $script:PsmuxOptionCache[$Name]
    if ([string]::IsNullOrEmpty($value)) { $Default } else { $value }
}

# Path to the claude executable.
#
# A popup is a direct child of the psmux server, so it never runs a shell
# profile — and Claude Code's native installer puts claude in ~/.local/bin by
# adding it to PATH *from the profile*, not from the registry. So inside a
# popup `claude` is simply not on PATH, and a plain PATH lookup makes the whole
# picker exit with "claude is required". Fall back to the known install
# locations before giving up.
function Get-ClaudeExe {
    if ($script:ClaudeExe) { return $script:ClaudeExe }

    $cmd = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $script:ClaudeExe = $cmd.Source; return $script:ClaudeExe }

    $candidates = @(
        (Join-Path $HOME '.local/bin/claude.exe')
        (Join-Path $HOME '.local/bin/claude.cmd')
        (Join-Path $env:APPDATA 'npm/claude.cmd')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            $script:ClaudeExe = $candidate
            return $script:ClaudeExe
        }
    }
    $null
}

# Resolve a popup size option ('90%', '80') to an absolute cell count.
#
# psmux resolves a percentage in `display-popup -w/-h` against the window being
# displayed, not against the client. Attaching a session into the popup
# therefore shrinks that session to 90% of its current size — and because the
# new size sticks, every re-open shrinks it again: measured 120x30 -> 106x24 ->
# 93x18 -> 81x13 -> 70x8 -> 61x4 over five opens of one session, which destroys
# it. Passing absolute values pins the popup and the session stays put (verified
# stable at 106x24 across five opens).
#
# $Dimension is 'width' or 'height'; the percentage is taken against the
# client's own size, which is what the option obviously means.
function Resolve-PopupSize {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][ValidateSet('width', 'height')][string]$Dimension
    )

    if ($Value -notmatch '^\s*(\d+)\s*%\s*$') { return $Value }
    $percent = [int]$Matches[1]

    $fmt = if ($Dimension -eq 'width') { '#{client_width}' } else { '#{client_height}' }
    $size = Invoke-Psmux display-message -p $fmt | Select-Object -First 1
    if ($size -notmatch '^\d+$') { return $Value }   # fall back to the percentage

    $cells = [int]([int]$size * $percent / 100)
    if ($cells -lt 10) { $cells = 10 }
    "$cells"
}

# How the plugin puts you into a Claude session.
#
#   switch  (default) switch-client to the session. There is no nested attach,
#           which is what keeps psmux's popup-attach defects out of the picture
#           altogether: no OSC colour-reply junk in the prompt, no session
#           shrinking on every open, no ambiguity about which client a detach
#           means. Costs the overlay — the session takes over the screen.
#   popup   overlay the session with display-popup + attach-session: the UX the
#           tmux original was built around, and still fully supported. Every
#           upstream defect catalogued in docs/porting-notes.md §4 lives on
#           this path; the plugin works around each one, but `switch` avoids
#           them by construction, which is why it is the default here.
#
# Anything unrecognised falls back to the default.
function Get-ClaudeJumpMode {
    $mode = (Get-PsmuxOption '@claude_jump_mode' 'switch').Trim().ToLowerInvariant()
    if ($mode -eq 'popup') { 'popup' } else { 'switch' }
}

# Which mode a Claude session was actually ENTERED under — the question every
# return path has to answer, and a different question from "what does the
# option say right now".
#
# The mode recorded at launch is authoritative when present. Origins written
# before that field existed have none, and re-reading @claude_jump_mode as the
# fallback is worse than useless from a return path: those run inside the
# Claude session, where #{session_name} is the Claude session, whose option
# table is empty. A session genuinely entered under `switch` therefore reads
# back as `popup`, and the popup branch then detaches what is in fact the
# user's only real client, dropping them off the server — the original bug,
# recurring on legacy state.
#
# So fall back to what is observably true rather than what was configured:
#
#   popup   the outer client never left the origin session, so the origin
#           reads as "(attached)" while the popup's nested client holds the
#           Claude session.
#   switch  the client moved to the Claude session, so the origin is no
#           longer attached.
#
# With no usable origin at all, `switch` is the safe answer: every caller
# re-checks the origin before acting on it and falls through to a plain
# detach, whereas a wrong `popup` would detach by session and take the real
# client with it.
function Get-ClaudeEntryMode {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        $Origin
    )

    if ($null -eq $Origin) { $Origin = Get-ClaudeOrigin $Session }
    if ($Origin -and $Origin.JumpMode) { return $Origin.JumpMode }

    if ($Origin -and $Origin.Session -and (Test-PsmuxSessionAttached $Origin.Session)) { 'popup' } else { 'switch' }
}

# Put $Client into $Session, honouring @claude_jump_mode.
function Enter-ClaudeSession {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [string]$Client,
        [string]$Width = '90%',
        [string]$Height = '90%'
    )

    if ((Get-ClaudeJumpMode) -eq 'switch') {
        if ($Client) { Invoke-Psmux switch-client -c $Client -t $Session | Out-Null }
        else { Invoke-Psmux switch-client -t $Session | Out-Null }
        return
    }

    $root = Get-PluginRoot
    $argv = @('display-popup', '-E')
    if ($Client) { $argv += @('-c', $Client) }
    $argv += @('-w', $Width, '-h', $Height, "pwsh -NoProfile -File `"$root/scripts/attach.ps1`" $Session")
    Invoke-Psmux @argv | Out-Null
}

# Short, stable 8-char hash used to derive a session name from a path.
# Hashes "<path>`n" so the result matches the Unix `printf '%s\n' | md5sum`
# scheme the original plugin used.
function Get-SessionHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("$Path`n")
        $hex = ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        $hex.Substring(0, 8)
    }
    finally {
        $md5.Dispose()
    }
}

# The pane/window/client the key was pressed in.
#
# psmux does NOT expand #{...} in a run-shell argument, so we cannot have the
# binding hand us this context — we ask for it ourselves. From a key binding the
# active pane is the one that pressed the key.
function Get-PsmuxContext {
    $fmt = '#{pane_current_path}|#{session_name}|#{window_id}|#{window_index}|#{pane_index}|#{client_name}'
    $line = Invoke-Psmux display-message -p $fmt | Select-Object -First 1
    if (-not $line) { return $null }

    $f = $line -split '\|'
    if ($f.Count -lt 6) { return $null }

    [pscustomobject]@{
        Path        = $f[0]
        Session     = $f[1]
        WindowId    = $f[2]
        WindowIndex = $f[3]
        PaneIndex   = $f[4]
        Client      = $f[5]
    }
}

# True when the session currently has a client on it — which is how we tell a
# session popup is open, since attaching one flips the session to "(attached)"
# in `list-sessions`.
#
# Read from `list-sessions` rather than `list-clients` on purpose: the latter
# only ever prints the most-recently-active client, so a session with a client
# on it can read as clientless there (see Get-PsmuxClientsOn).
function Test-PsmuxSessionAttached {
    param([Parameter(Mandatory = $true)][string]$Session)

    foreach ($line in (Invoke-Psmux list-sessions)) {
        if ($line -match '^([^:]+):') {
            if ($Matches[1] -eq $Session) { return [bool]($line -match '\(attached\)') }
        }
    }
    $false
}

function Test-PsmuxSessionExists {
    param([Parameter(Mandatory = $true)][string]$Session)
    Invoke-Psmux has-session -t $Session | Out-Null
    $LASTEXITCODE -eq 0
}

# Clients currently attached to $Session, by name.
#
# `list-clients -F` is ignored (see the table above) — it always prints the
# default line `<client>: <session>: <window> [WxH] (utf8) [activity=...]`, so
# client and session are the first two fields split on ': '.
#
# A popup running an ordinary command does NOT show up here — but a popup
# that *attaches a session* (exactly what Enter-ClaudeSession's popup branch
# does) is itself a real client, listed at the popup's own dimensions, not
# the host's. Measured: host at 120x29, popup-nested attach at 78x17, both
# present as separate `(attached)` sessions — the popup one WAS the row
# `list-clients` returned. So this function is not popup-safe on its own;
# Restore-ClaudeClients gates on jump mode instead of relying on an empty
# result here (docs/porting-notes.md §2).
function Get-PsmuxClientsOn {
    param([Parameter(Mandatory = $true)][string]$Session)

    $clients = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Invoke-Psmux list-clients)) {
        $f = $line -split ': '
        if ($f.Count -lt 2) { continue }
        if ($f[1] -eq $Session) { $clients.Add($f[0]) }
    }
    $clients.ToArray()
}

# The `switch` jump-mode bail-out: called by session.ps1 after claude exits,
# right before the session's last window (and the session itself) dies with
# it. `detach-on-destroy` looks like the built-in answer here but is a no-op
# on psmux 3.3.7 — accepted, stored, readable, zero effect, measured with a
# real client on `on`/`off`/`previous` (docs/porting-notes.md §2) — so this is
# the only mechanism that actually keeps the client attached.
#
# Never throws: called from a session's command process, where an error is as
# invisible as it is from a key binding.
function Restore-ClaudeClients {
    param([Parameter(Mandatory = $true)][string]$Session)

    try {
        $origin = Get-ClaudeOrigin $Session

        # Mode gate, checked first and unconditionally — see Get-ClaudeEntryMode
        # for why the mode cannot simply be re-read from in here.
        #
        # The gate is required, not an optimisation: a popup's nested attach
        # client DOES register in list-clients (see Get-PsmuxClientsOn), so an
        # empty client list is not a reliable way to detect popup mode. Without
        # it, closing a popup session would fire switch-client/select-window at
        # the outer client as well.
        if ((Get-ClaudeEntryMode -Session $Session -Origin $origin) -ne 'switch') { return }

        # Guard: only act when this session is actually about to die. If it
        # still has another window, or this window still has another pane,
        # the session survives and moving the client off it would be wrong —
        # count panes across the whole session, not just this one. Invoke-Psmux
        # captures a trailing blank line as its own array element, so blank
        # lines are filtered before counting rather than trusting .Count raw.
        $panes = @(Invoke-Psmux list-panes -s -t $Session | Where-Object { $_.Trim() -ne '' })
        if ($panes.Count -ne 1) { return }

        # No recorded origin, or the origin session is gone: nothing sane to
        # return to, so leave it alone. The client detaches — today's
        # behaviour, and the correct fallback.
        if (-not $origin -or -not $origin.Session -or -not $origin.WindowIndex) { return }
        if (-not (Test-PsmuxSessionExists $origin.Session)) { return }

        foreach ($client in (Get-PsmuxClientsOn $Session)) {
            # psmux #483: switch-client with a window-scoped target exits 0
            # and silently ignores it. Two steps, same as picker.ps1's
            # dedicated jump (docs/porting-notes.md §3.2).
            Invoke-Psmux switch-client -c $client -t $origin.Session | Out-Null
            Invoke-Psmux select-window -t "$($origin.Session):$($origin.WindowIndex)" | Out-Null
        }
    }
    catch {
        # Best-effort: on any failure the client(s) just detach, i.e. today's
        # behaviour.
    }
}

# Full path of a Claude session's transcript, or $null.
#
# Found by glob so we never reproduce Claude's cwd -> project-slug encoding.
# That path is an internal Claude Code detail and may move.
function Get-TranscriptPath {
    param([string]$SessionId)

    if ([string]::IsNullOrWhiteSpace($SessionId)) { return $null }

    $base = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    $projects = Join-Path $base 'projects'
    if (-not (Test-Path -LiteralPath $projects)) { return $null }

    Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "$SessionId.jsonl" } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
}

# Split a user-supplied option string into argv, honouring single and double
# quotes. Stands in for bash's `eval "arr=($opts)"`, which has no PowerShell
# equivalent that is safe to use on config input.
function Split-CommandLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return @() }

    $tokens = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $quote = $null
    $has = $false

    foreach ($ch in $Line.ToCharArray()) {
        if ($quote) {
            if ($ch -eq $quote) { $quote = $null } else { [void]$current.Append($ch) }
        }
        elseif ($ch -eq '"' -or $ch -eq "'") {
            $quote = $ch
            $has = $true
        }
        elseif ($ch -match '\s') {
            if ($has -or $current.Length -gt 0) { $tokens.Add($current.ToString()); [void]$current.Clear(); $has = $false }
        }
        else {
            [void]$current.Append($ch)
        }
    }
    if ($has -or $current.Length -gt 0) { $tokens.Add($current.ToString()) }

    $tokens.ToArray()
}
