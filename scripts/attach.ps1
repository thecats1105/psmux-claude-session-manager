# Attach to a session from inside a psmux popup.
#
# This wrapper is why the plugin works at all. psmux injects PSMUX_SESSION and
# PSMUX_TARGET_SESSION into a popup's environment, and attach-session refuses to
# run when it sees them:
#
#   psmux: sessions should be nested with care, unset PSMUX_SESSION to force
#
# The popup then closes instantly and the session never appears. Clearing both
# variables first makes the attach succeed. Never call `psmux attach-session`
# directly from a popup command — always go through here.

param([Parameter(Mandatory = $true)][string]$Session)

. "$PSScriptRoot/helpers.ps1"

Remove-Item env:PSMUX_SESSION -ErrorAction SilentlyContinue
Remove-Item env:PSMUX_TARGET_SESSION -ErrorAction SilentlyContinue

& (Get-PsmuxExe) attach-session -t $Session
