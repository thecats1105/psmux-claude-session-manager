# fzf preview for one picker row.
#
# The tmux original previewed with `capture-pane` alone. That does not carry
# over: psmux returns an empty capture for panes in a *detached* session, and
# every dedicated session this plugin creates sits detached until you open it.
# So capture-pane is tried first (it works for the session you are attached to,
# including a session currently open in a popup) and falls back to the tail of
# the agent's transcript, which is always readable.

param(
    [string]$Target,
    [string]$SessionId
)

. "$PSScriptRoot/helpers.ps1"

$esc = [char]27
$dim = "$esc[90m"
$reset = "$esc[0m"
$bold = "$esc[1m"

if ($Target) {
    $captured = @(Invoke-Psmux capture-pane -p -e -t $Target)
    if (($captured -join '').Trim()) {
        # psmux replays the pane's OSC sequences (palette and colour queries) into
        # the capture, minus their ESC prefix — they arrive as literal
        # `]11;rgb:1e1e/1e1e/2e2e\` noise. Strip those (with or without the ESC)
        # while keeping the SGR colours that -e gives us.
        $captured -replace "$esc?\]\d+(;[^\\\a`n]*)?(\\|\a)", ''
        exit 0
    }
}

$transcript = Get-TranscriptPath $SessionId
if (-not $transcript) {
    "${dim}No live pane and no transcript for this agent yet.$reset"
    exit 0
}

"${dim}session detached - showing transcript tail$reset"
''

# Only the tail is parsed: these files grow to megabytes and the preview
# re-renders on every cursor move.
$lines = Get-Content -LiteralPath $transcript -Tail 60 -ErrorAction SilentlyContinue
$out = [System.Collections.Generic.List[string]]::new()

foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    try { $entry = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
    if ($entry.type -ne 'user' -and $entry.type -ne 'assistant') { continue }

    $content = $entry.message.content
    if (-not $content) { continue }

    $text = if ($content -is [string]) {
        $content
    }
    else {
        (@($content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n"
    }
    if ([string]::IsNullOrWhiteSpace($text)) { continue }

    $label = if ($entry.type -eq 'user') { "$esc[36m> you$reset" } else { "$esc[35m> claude$reset" }
    $out.Add("$bold$label$reset")
    foreach ($t in ($text -split "`n")) { $out.Add("  $t") }
    $out.Add('')
}

if ($out.Count -eq 0) {
    "${dim}Transcript has no messages yet.$reset"
}
else {
    # Newest exchanges last, so the preview lands on the most recent turn.
    $out | Select-Object -Last 80
}
