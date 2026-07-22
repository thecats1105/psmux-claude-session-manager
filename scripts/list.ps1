# Open the agent picker in a popup.
#
# Takes no arguments — psmux does not expand #{...} in a run-shell argument, so
# we query the current client ourselves.

. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/state.ps1"

$prefix = Get-PsmuxOption '@claude_session_prefix' 'claude-'

# Absolute, not '90%' — see Resolve-PopupSize. The picker popup does not attach
# a session, so it is not itself at risk, but it must stay the same size as the
# session popup or the two overlays jump around.
$width = Resolve-PopupSize (Get-PsmuxOption '@claude_popup_width' '90%') 'width'
$height = Resolve-PopupSize (Get-PsmuxOption '@claude_popup_height' '90%') 'height'
$root = Get-PluginRoot

$context = Get-PsmuxContext

# open_picker: show the picker popup on $Host_, or on the default client when
# $Host_ is empty.
function Open-Picker {
    param([string]$Host_)

    $cmd = "pwsh -NoProfile -File `"$root/scripts/picker.ps1`""
    if ($Host_) {
        Invoke-Psmux display-popup -c $Host_ -E -w $width -h $height $cmd | Out-Null
    }
    else {
        Invoke-Psmux display-popup -E -w $width -h $height $cmd | Out-Null
    }
}

if ($context -and $context.Session -and $context.Session.StartsWith($prefix)) {
    # Pressed from inside a session popup: close that popup first, so the picker
    # opens full-size on the outer client instead of cramped inside it.
    #
    # The tmux original needed a retry loop here, because display-popup returned
    # before tmux had finished tearing the closing overlay down. psmux's
    # display-popup is asynchronous — it returns immediately either way — so that
    # loop could never have worked and is gone; a short settle is enough.
    Invoke-Psmux detach-client -s $context.Session | Out-Null
    Start-Sleep -Milliseconds 150

    Open-Picker (Get-ClaudeParent)
    exit 0
}

# Normal case: this client is the host.
if ($context) { Set-ClaudeParent $context.Client }
Open-Picker $(if ($context) { $context.Client } else { '' })
