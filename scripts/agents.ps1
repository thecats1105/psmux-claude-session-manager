# Emit one picker row per running Claude that lives in a psmux pane.
#
# Claude self-reports its status: each session writes its own state to disk and a
# supervisor daemon aggregates it, which `claude agents --json` publishes. So this
# needs no Claude Code hooks.
#
# Identity is the Claude process, not the psmux session. The tmux original joined
# pid -> tty -> pane, which is impossible here: psmux's #{pane_tty} is a synthetic
# label derived from the pane id (%5 -> /dev/pty5) that no Windows process carries.
# #{pane_pid} however is a real Windows pid — of the pane's *shell*. So we walk the
# parent chain up from each Claude until we land on a pane's shell:
#
#   claude.exe (34280) -> pwsh.exe (36416) == #{pane_pid} of pane %5
#
#   Row: rank \t target \t pid \t kind \t session \t sessionId \t icon \t age \t loc \t path
#   Columns 1-6 are hidden from the display via fzf's --with-nth.

. "$PSScriptRoot/helpers.ps1"

$ErrorActionPreference = 'Stop'

# --- running Claude agents -------------------------------------------------
# PowerShell parses the JSON itself, so unlike the tmux original this needs no jq.
$claude = Get-ClaudeExe
if (-not $claude) { exit 0 }

try {
    $json = & $claude agents --json 2>$null | Out-String
    if ([string]::IsNullOrWhiteSpace($json)) { exit 0 }
    $agents = @($json | ConvertFrom-Json | Where-Object { $_.kind -eq 'interactive' })
}
catch {
    exit 0
}
if ($agents.Count -eq 0) { exit 0 }

# --- psmux panes, keyed by the pid of the shell running in them -------------
$paneByPid = @{}
foreach ($line in (Invoke-Psmux list-panes -a -F '#{pane_pid}|#{session_name}|#{window_index}|#{pane_index}|#{pane_id}|#{window_id}')) {
    $f = $line -split '\|'
    if ($f.Count -lt 6) { continue }

    $panePid = 0
    if (-not [int]::TryParse($f[0], [ref]$panePid)) { continue }

    $paneByPid[$panePid] = [pscustomobject]@{
        Session     = $f[1]
        WindowIndex = $f[2]
        PaneIndex   = $f[3]
        PaneId      = $f[4]
        WindowId    = $f[5]
        # Targets must be session-qualified: psmux reuses %n and @n per session.
        Target      = "$($f[1]):$($f[2]).$($f[3])"
    }
}
if ($paneByPid.Count -eq 0) { exit 0 }

# Walk up from a pid until we hit a process that owns a pane. Depth is bounded
# because an orphaned process can otherwise chain all the way to the root.
function Find-Pane {
    param([int]$ProcessId)

    $current = $ProcessId
    for ($depth = 0; $depth -lt 8; $depth++) {
        if ($paneByPid.ContainsKey($current)) { return $paneByPid[$current] }

        $proc = Get-Process -Id $current -ErrorAction SilentlyContinue
        if (-not $proc) { return $null }

        $parent = $null
        try { $parent = $proc.Parent } catch { }
        if (-not $parent) { return $null }

        $current = $parent.Id
    }
    $null
}

$prefix = Get-PsmuxOption '@claude_session_prefix' 'claude-'
$esc = [char]27
$now = Get-Date
$rows = [System.Collections.Generic.List[object]]::new()

foreach ($agent in $agents) {
    $pane = Find-Pane -ProcessId $agent.pid
    if (-not $pane) { continue }   # this Claude is not running inside psmux

    switch ($agent.status) {
        'waiting' { $icon = "$esc[33m●$esc[0m waiting"; $rank = 0 }  # yellow - needs input
        'idle'    { $icon = "$esc[32m●$esc[0m idle   "; $rank = 1 }  # green  - done, your turn
        'busy'    { $icon = "$esc[31m●$esc[0m working"; $rank = 3 }  # red    - busy, leave it
        default   { $icon = "$esc[90m●$esc[0m   ?    "; $rank = 2 }  # grey   - unrecognised status
    }

    # The age column is the mtime of the agent's transcript — its last sign of
    # life. `claude agents --json` reports only startedAt, never last activity.
    $ageMinutes = -1
    $age = '-'
    $transcript = Get-TranscriptPath $agent.sessionId
    if ($transcript) {
        try {
            $ageMinutes = [int]((($now) - (Get-Item -LiteralPath $transcript).LastWriteTime).TotalMinutes)
            if ($ageMinutes -lt 0) { $ageMinutes = 0 }
            $age = "${ageMinutes}m"
        }
        catch { }
    }

    $kind = if ($pane.Session.StartsWith($prefix)) { 'dedicated' } else { 'loose' }

    $path = [string]$agent.cwd
    if ($path.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) {
        $path = '~' + $path.Substring($HOME.Length)
    }

    $rows.Add([pscustomobject]@{
            Rank      = $rank
            SortAge   = if ($ageMinutes -lt 0) { 0 } else { $ageMinutes }
            Line      = @(
                $rank
                $pane.Target
                $agent.pid
                $kind
                $pane.Session
                $agent.sessionId
                $icon
                ('{0,5}' -f $age)
                $pane.Target
                $path
            ) -join "`t"
        })
}

# rank asc (what needs you floats up), then age asc so whatever just went idle
# sits at the top of its group.
$rows | Sort-Object Rank, SortAge | ForEach-Object { $_.Line }
