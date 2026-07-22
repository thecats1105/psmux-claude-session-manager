# The command psmux runs for a dedicated Claude session (launch.ps1 wires this
# up in place of the bare @claude_command).
#
# Runs claude in the *foreground*, so this process is claude's parent and
# outlives it. That is what makes the fix possible: once claude exits (e.g.
# Ctrl+D), this script is still alive to act before the session's last window
# — and with it the session itself — dies.
#
# Without this, `switch` mode leaves nothing behind to catch the client: the
# session dies mid-attach and psmux drops the client off the server entirely
# (`detach-on-destroy` is a no-op on psmux 3.3.7 — see docs/porting-notes.md
# §2 — so there is no built-in way to prevent that). `popup` mode never needed
# this — the client that dies with the popup's nested attach is a throwaway —
# and running this wrapper there is still inert, but not because the popup is
# invisible to psmux: a popup that attaches a session IS a real, listed
# client (docs/porting-notes.md §2). Restore-ClaudeClients checks the jump
# mode itself (preferring the mode recorded at launch time — see state.ps1 —
# over a fresh read, since #{session_name} in here means the claude session,
# not the one that launched it) and returns immediately when it is not
# `switch`.
#
# Nothing here may throw: this runs as a session's command, same as a popup —
# stderr goes nowhere a user can see.

param([Parameter(Mandatory = $true)][string]$Session)

. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/state.ps1"

try {
    $command = Get-PsmuxOption '@claude_command' 'claude'
    $extraArgs = Split-CommandLine (Get-PsmuxOption '@claude_args' '')

    # Same reason a popup can't find claude on PATH: a session command gets no
    # shell profile either, so ~/.local/bin (where the native installer puts
    # it) is missing. Fall back to Get-ClaudeExe's known install locations.
    $resolved = Get-Command $command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $exe = if ($resolved) { $resolved.Source } else { Get-ClaudeExe }
    if (-not $exe) { $exe = $command }   # let it fail with the shell's own "not found"

    & $exe @extraArgs
}
catch {
    # Fall through to the restore below regardless of how claude exited.
}

# The session's last window is about to die with this process. Hand any
# client still parked on it back to where it was launched from.
Restore-ClaudeClients -Session $Session
