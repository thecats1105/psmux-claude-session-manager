# Kill the Claude process behind a picker row (fzf's ctrl-x).
#
# Kills the Claude process itself, not its pane: a dedicated session dies with
# its last window, and a loose pane keeps the shell that hosted it.

param([int]$ProcessId)

if ($ProcessId -gt 0) {
    Stop-Process -Id $ProcessId -ErrorAction SilentlyContinue
}
