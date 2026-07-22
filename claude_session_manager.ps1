# psmux-claude-session-manager
#
# List, monitor status, and jump across nested Claude Code sessions from a
# single popup. psmux runs this file at config load (`run-shell '... .ps1'`);
# it reads user options and installs the key bindings.

. "$PSScriptRoot/scripts/helpers.ps1"

$launchKey = Get-PsmuxOption '@claude_launch_key' 'y'
$listKey = Get-PsmuxOption '@claude_list_key' 'u'
$detachKey = Get-PsmuxOption '@claude_detach_key' 'd'
$root = Get-PluginRoot

# Paths are forward-slashed: psmux strips backslashes out of bind-key command
# strings, which would otherwise mangle every Windows path here.
#
# The scripts take no arguments. psmux does not expand #{pane_current_path} and
# friends inside a run-shell argument (it passes them through literally), so
# each script asks psmux for its own context via `display-message -p`.
Invoke-Psmux bind-key $launchKey "run-shell 'pwsh -NoProfile -File `"$root/scripts/launch.ps1`"'" | Out-Null
Invoke-Psmux bind-key $listKey "run-shell 'pwsh -NoProfile -File `"$root/scripts/list.ps1`"'" | Out-Null

# Replaces the stock `detach-client` binding on the same key (default 'd')
# with a version that returns you to the launching window from a
# plugin-launched session instead of dropping the whole client off the
# server — see scripts/detach.ps1. An empty value opts out and leaves
# whatever binding is already on that key untouched.
if ($detachKey) {
    Invoke-Psmux bind-key $detachKey "run-shell 'pwsh -NoProfile -File `"$root/scripts/detach.ps1`"'" | Out-Null
}
