# Smart prefix+d (@claude_detach_key, default 'd' — the stock detach-client
# key). Bound by claude_session_manager.ps1 in place of the stock native
# binding, so it can special-case a plugin-launched session before falling
# through to a plain detach everywhere else.
#
# Root cause this fixes, measured directly: with a session popup open, the
# STOCK `bind-key -T prefix d detach-client` (no target) detaches the OUTER
# client, not the popup's own nested attach. Pressing prefix+d to go back
# instead dropped the user off the server entirely, forcing a `psmux attach`
# to get back in. The fix does not try to out-guess which client "current
# client" means from inside a popup — it never asks. The popup branch below
# detaches by SESSION (`-s`), the same primitive list.ps1 already uses to
# close a session popup, which only ever has the popup's own nested attach on
# it, so there is no ambiguity to get wrong.
#
# Nothing here may throw: this runs from a key binding, where an error is
# invisible to the user.

. "$PSScriptRoot/helpers.ps1"
. "$PSScriptRoot/state.ps1"

try {
    $context = Get-PsmuxContext
    $prefix = Get-PsmuxOption '@claude_session_prefix' 'claude-'

    if (-not $context -or -not $context.Session -or -not $context.Session.StartsWith($prefix)) {
        # Stock behaviour, preserved everywhere outside a plugin-launched
        # session — this key must not surprise anyone who never uses Claude.
        Invoke-Psmux detach-client | Out-Null
        exit 0
    }

    $origin = Get-ClaudeOrigin $context.Session

    # How this session was ENTERED, not what the option says now: from in here
    # #{session_name} is the CLAUDE session, not the session the launch key was
    # pressed in, and session-scoped options override global
    # (docs/porting-notes.md §2), so a fresh read can disagree with reality.
    # Getting this wrong in the `switch` direction is the whole original bug —
    # see Get-ClaudeEntryMode.
    $mode = Get-ClaudeEntryMode -Session $context.Session -Origin $origin

    if ($mode -eq 'switch') {
        if ($origin -and $origin.Session -and $origin.WindowIndex -and (Test-PsmuxSessionExists $origin.Session)) {
            # psmux #483: switch-client with a window-scoped target exits 0
            # and silently ignores it. Two steps, same as picker.ps1's
            # dedicated jump and Restore-ClaudeClients (docs/porting-notes.md
            # §3.2).
            if ($context.Client) { Invoke-Psmux switch-client -c $context.Client -t $origin.Session | Out-Null }
            else { Invoke-Psmux switch-client -t $origin.Session | Out-Null }
            Invoke-Psmux select-window -t "$($origin.Session):$($origin.WindowIndex)" | Out-Null
        }
        else {
            # No usable origin: nothing sane to switch back to, so fall back
            # to a plain detach rather than leaving the user stuck.
            Invoke-Psmux detach-client | Out-Null
        }
        exit 0
    }

    # popup: close the overlay by detaching whoever is on THIS session.
    Invoke-Psmux detach-client -s $context.Session | Out-Null
}
catch {
    # Best effort: a broken detach binding must never be worse than none.
}
