# Launch (or re-attach to) a Claude session for the current pane's directory,
# shown in a popup.
#
# Takes no arguments: psmux does not expand #{...} in a run-shell argument, so
# the binding cannot hand us the pane's path — we ask psmux for it ourselves.

. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/state.ps1"

$context = Get-PsmuxContext
if (-not $context) { exit 0 }

$prefix = Get-PsmuxOption '@claude_session_prefix' 'claude-'

# Resolved once, here, while #{session_name} is still the launching session —
# and recorded below so the return path (Restore-ClaudeClients, detach.ps1)
# uses this same mode rather than re-resolving it from inside the claude
# session, where #{session_name} means something different. See state.ps1.
$jumpMode = Get-ClaudeJumpMode

# Absolute, not '90%': a percentage would be resolved against the session being
# attached and would shrink it on every open. See Resolve-PopupSize.
$width = Resolve-PopupSize (Get-PsmuxOption '@claude_popup_width' '90%') 'width'
$height = Resolve-PopupSize (Get-PsmuxOption '@claude_popup_height' '90%') 'height'

$session = $prefix + (Get-SessionHash $context.Path)

# Refuse to open a popup inside an existing one, detected by the session
# flipping to "(attached)" in list-sessions once a popup attaches it.
#
# Popup mode only: under `switch` there is no popup to duplicate, and an
# attached session just means a client is already looking at it — switching
# there again is exactly what was asked for.
if ($jumpMode -eq 'popup' -and (Test-PsmuxSessionAttached $session)) {
    Invoke-Psmux display-message '🫪 Popup window already open' | Out-Null
    exit 0
}

if (-not (Test-PsmuxSessionExists $session)) {
    # psmux copies the invoking client's environment into the new session. If we
    # were started from inside a Claude session, the new agent inherits that
    # session's identity, decides it is a nested child, and never registers with
    # the supervisor — so `claude agents --json` never reports it and it is
    # invisible to the picker. Drop those variables so the agent stands alone.
    # CLAUDE_CONFIG_DIR is deliberately kept: it points at the user's config.
    foreach ($name in @(
            'CLAUDECODE'
            'CLAUDE_CODE_SESSION_ID'
            'CLAUDE_CODE_CHILD_SESSION'
            'CLAUDE_CODE_ENTRYPOINT'
            'CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT'
            'CLAUDE_PID'
            'CLAUDE_JOB_DIR'
        )) {
        Remove-Item "env:$name" -ErrorAction SilentlyContinue
    }

    # The session runs a wrapper, not @claude_command directly: session.ps1
    # resolves @claude_command/@claude_args itself, runs claude in the
    # foreground, and on exit returns any client still on this session to the
    # window it was launched from before the session dies with its last
    # window. See scripts/session.ps1 and Restore-ClaudeClients in
    # helpers.ps1. Get-PluginRoot is forward-slashed: psmux strips backslashes
    # out of command strings.
    $root = Get-PluginRoot
    $newArgs = @('new-session', '-d', '-s', $session, '-c', $context.Path,
        "pwsh -NoProfile -File `"$root/scripts/session.ps1`" $session")
    Invoke-Psmux @newArgs | Out-Null
}

# Record which window launched it (and under which mode), so the picker and
# the smart detach key can both jump back here later.
Set-ClaudeOrigin -Session $session -Context $context -JumpMode $jumpMode
Set-ClaudeParent $context.Client

Enter-ClaudeSession -Session $session -Client $context.Client -Width $width -Height $height
