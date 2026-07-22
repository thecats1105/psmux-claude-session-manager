# Interactive picker for running Claude agents. Runs inside a psmux popup.
#
#   picker.ps1                 fzf picker; on enter, jumps to the chosen agent.
#   picker.ps1 --list          print the rows only (used by fzf's ctrl-x reload).
#
# Rows come from agents.ps1. Two kinds of row jump differently:
#   dedicated  a Claude in a `claude-*` session this plugin launched — resumed in
#              the popup, over the window it was launched from.
#   loose      a Claude running in any other pane — focused in place.

param(
    [switch]$List,
    [int]$Delay = 0
)

. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/state.ps1"

$root = Get-PluginRoot

if ($List) {
    # The reload after a kill waits a beat so the supervisor has dropped the
    # agent from `claude agents --json`.
    if ($Delay -gt 0) { Start-Sleep -Milliseconds $Delay }
    & pwsh -NoProfile -File "$root/scripts/agents.ps1"
    exit 0
}

# jq is not needed on this port — agents.ps1 parses the JSON in PowerShell.
# claude is resolved through Get-ClaudeExe rather than a bare PATH lookup: a
# popup gets no shell profile, and that is where ~/.local/bin joins PATH.
if (-not (Get-Command fzf -ErrorAction SilentlyContinue)) {
    Invoke-Psmux display-message 'psmux-claude-session-manager: fzf is required for the picker' | Out-Null
    exit 0
}
if (-not (Get-ClaudeExe)) {
    Invoke-Psmux display-message 'psmux-claude-session-manager: claude is required for the picker' | Out-Null
    exit 0
}

$env:FZF_DEFAULT_OPTS = ''
$env:CLAUDE_PICKER = "$root/scripts/picker.ps1"

$rows = @(& pwsh -NoProfile -File "$root/scripts/agents.ps1")
if ($rows.Count -eq 0) {
    Invoke-Psmux display-message 'No Claude agents running in psmux' | Out-Null
    exit 0
}

# fzf runs --preview and execute-silent through the system shell (cmd.exe on
# Windows), so each one has to be a fully-formed command line with its script
# path quoted.
$previewCmd = "pwsh -NoProfile -File `"$root/scripts/preview.ps1`" {2} {6}"
$killCmd = "pwsh -NoProfile -File `"$root/scripts/kill.ps1`" {3}"
$reloadCmd = "pwsh -NoProfile -File `"$root/scripts/picker.ps1`" --list --delay 300"

$fzfArgs = @(
    '--ansi'
    '--delimiter', '\t'
    '--with-nth', '7,8,9,10'
    '--reverse'
    '--cycle'
    '--header', 'Claude agents · enter: jump · ctrl-x: kill'
    '--preview', $previewCmd
    '--preview-window', 'up,70%,follow'
    '--bind', "ctrl-x:execute-silent($killCmd)+reload($reloadCmd)"
)
$fzfArgs += Split-CommandLine (Get-PsmuxOption '@claude_fzf_options' '')

$selection = $rows | & fzf @fzfArgs | Select-Object -First 1
if (-not $selection) { exit 0 }

$f = $selection -split "`t"
if ($f.Count -lt 10) { exit 0 }

$target = $f[1]
$kind = $f[3]
$session = $f[4]

$parent = Get-ClaudeParent

if ($kind -eq 'loose') {
    # Focus the pane in place on the outer client. This popup closes on its own
    # when the script exits.
    if ($parent) {
        Invoke-Psmux switch-client -c $parent -t $session | Out-Null
    }
    else {
        Invoke-Psmux switch-client -t $session | Out-Null
    }
    # Targets stay session-qualified: psmux reuses %n and @n across sessions.
    Invoke-Psmux select-window -t ($target -replace '\.\d+$', '') | Out-Null
    Invoke-Psmux select-pane -t $target | Out-Null
    exit 0
}

if ((Get-ClaudeJumpMode) -eq 'switch') {
    # No nested attach: put the outer client straight on the session and let
    # this popup close on exit. The origin window is irrelevant here — the
    # client is going to the session, not back to where it was launched.
    if ($parent) {
        Invoke-Psmux switch-client -c $parent -t $session | Out-Null
    }
    else {
        Invoke-Psmux switch-client -t $session | Out-Null
    }
    exit 0
}

# Move the parent client to the window the session was launched from
# (best-effort), then resume the agent in THIS popup over the top.
$origin = Get-ClaudeOrigin $session
if ($origin -and $parent -and $origin.Session -and $origin.WindowIndex) {
    # psmux #483: switch-client takes a window-scoped target, exits 0 and then
    # silently ignores it. Switch the session, then select the window — the
    # same two-step the `loose` branch above already does.
    Invoke-Psmux switch-client -c $parent -t $origin.Session | Out-Null
    Invoke-Psmux select-window -t "$($origin.Session):$($origin.WindowIndex)" | Out-Null
}

# Same reason as attach.ps1: psmux refuses to attach while these are set.
Remove-Item env:PSMUX_SESSION -ErrorAction SilentlyContinue
Remove-Item env:PSMUX_TARGET_SESSION -ErrorAction SilentlyContinue

& (Get-PsmuxExe) attach-session -t $session
