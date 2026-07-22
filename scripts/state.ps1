# Cross-invocation state for psmux-claude-session-manager.
#
# The tmux original kept this in tmux options (@claude_origin, @claude_parent).
# psmux can persist a runtime `set` too, but only at SESSION scope — a global
# `set-option -g @foo bar` exits 0 but silently discards the value (corrected
# 2026-07-22: this was previously mis-documented as true of runtime `set` in
# general — see docs/porting-notes.md §2). Session scope is no help here
# regardless: this state has to survive being read back from a DIFFERENT
# session than the one it was written from (the claude session reading back
# what the launching session recorded), so it still needs to live outside any
# one session's option table. We keep our own JSON file.
#
#   {
#     "parent":  "client0",
#     "origins": { "claude-ab12cd34": { "session": "0", "window": "@3", "windowIndex": "1", "jumpMode": "switch" } }
#   }
#
# window_id is recorded together with its session because psmux reuses both
# pane and window ids across sessions (@1 can exist in two sessions at once).
#
# jumpMode is the @claude_jump_mode this session was actually LAUNCHED under,
# not just a record of the window. It exists because the mode can no longer be
# re-resolved reliably from inside the claude session: #{session_name} there
# is the claude session, not the launching one, and session-scoped options
# override global — so a fresh Get-ClaudeJumpMode read from in there could see
# a different table than launch.ps1 did. Restore-ClaudeClients and detach.ps1
# both prefer this field and fall back to a fresh Get-ClaudeJumpMode read when
# it is absent, which happens for any origin written by a plugin version
# before this field existed.

function Get-StatePath {
    $dir = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.local' }
    Join-Path (Join-Path $dir 'psmux-claude-session-manager') 'state.json'
}

# Never throws: a corrupt or missing file just reads as empty state.
function Get-State {
    $path = Get-StatePath
    if (-not (Test-Path -LiteralPath $path)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $obj = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($obj -is [hashtable]) { $obj } else { @{} }
    }
    catch {
        @{}
    }
}

# Written to a temp file and moved into place so a concurrent reader never sees
# a half-written document.
function Set-State {
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $path = Get-StatePath
    try {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        $tmp = "$path.$PID.tmp"
        $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
    }
    catch {
        # State is a convenience (it only powers the "jump back to the window
        # you launched from" nicety). Losing it must never break a key binding.
    }
}

# The client that last opened the picker/launcher — the outer host we switch
# back to when jumping to an agent.
function Set-ClaudeParent {
    param([string]$Client)
    if ([string]::IsNullOrWhiteSpace($Client)) { return }
    $state = Get-State
    $state['parent'] = $Client
    Set-State $state
}

function Get-ClaudeParent {
    $client = (Get-State)['parent']
    if ([string]::IsNullOrWhiteSpace($client)) { return $null }

    # A stale client name would make every switch-client fail silently, so
    # confirm it is still attached before handing it out.
    foreach ($line in (Invoke-Psmux display-message -p '#{client_name}')) {
        if ($line -eq $client) { return $client }
    }
    $null
}

# Where a dedicated session was launched from, so the picker can put the outer
# client back on that window before resuming the agent over it. $JumpMode is
# the @claude_jump_mode resolved AT LAUNCH TIME — optional (older callers, or
# a caller with nothing to record, can omit it) but every call site in this
# plugin passes it; see the file header for why the return path needs it.
function Set-ClaudeOrigin {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)]$Context,
        [string]$JumpMode
    )

    $state = Get-State
    if (-not $state.ContainsKey('origins') -or $state['origins'] -isnot [hashtable]) {
        $state['origins'] = @{}
    }
    $entry = @{
        session     = $Context.Session
        window      = $Context.WindowId
        windowIndex = $Context.WindowIndex
    }
    if (-not [string]::IsNullOrWhiteSpace($JumpMode)) { $entry['jumpMode'] = $JumpMode }
    $state['origins'][$Session] = $entry
    Set-State $state
}

function Get-ClaudeOrigin {
    param([Parameter(Mandatory = $true)][string]$Session)

    $origins = (Get-State)['origins']
    if ($origins -isnot [hashtable]) { return $null }
    $entry = $origins[$Session]
    if ($entry -isnot [hashtable]) { return $null }

    [pscustomobject]@{
        Session     = $entry['session']
        Window      = $entry['window']
        WindowIndex = $entry['windowIndex']
        # $null for an origin written before this field existed — callers
        # fall back to a fresh Get-ClaudeJumpMode read.
        JumpMode    = $entry['jumpMode']
    }
}
