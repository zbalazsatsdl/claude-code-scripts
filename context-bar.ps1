# context-bar.ps1
# Color theme: gray, orange, blue, teal, green, lavender, rose, gold, slate, cyan
$COLOR = "blue"

# Ensure UTF-8 output so block/emoji characters render correctly
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ANSI escape character
$ESC = [char]27

# Color codes
$C_RESET     = "$ESC[0m"
$C_GRAY      = "$ESC[38;5;245m"
$C_BAR_EMPTY = "$ESC[38;5;238m"

switch ($COLOR) {
    "orange"   { $C_ACCENT = "$ESC[38;5;173m" }
    "blue"     { $C_ACCENT = "$ESC[38;5;74m" }
    "teal"     { $C_ACCENT = "$ESC[38;5;66m" }
    "green"    { $C_ACCENT = "$ESC[38;5;71m" }
    "lavender" { $C_ACCENT = "$ESC[38;5;139m" }
    "rose"     { $C_ACCENT = "$ESC[38;5;132m" }
    "gold"     { $C_ACCENT = "$ESC[38;5;136m" }
    "slate"    { $C_ACCENT = "$ESC[38;5;60m" }
    "cyan"     { $C_ACCENT = "$ESC[38;5;37m" }
    default    { $C_ACCENT = $C_GRAY }
}

# Unicode characters via code points (avoids encoding issues with PS5.1)
$CHR_FULL   = [char]0x2588  # full block
$CHR_HALF   = [char]0x2584  # lower half block
$CHR_EMPTY  = [char]0x2591  # light shade
$ICON_DIR   = [char]::ConvertFromUtf32(0x1F4C1)  # folder emoji
$ICON_BRANCH = [char]::ConvertFromUtf32(0x1F500) # shuffle arrows emoji
$ICON_MSG   = [char]::ConvertFromUtf32(0x1F4AC)  # speech bubble emoji

# Read JSON from stdin (works when called as external process)
$inputStr = [Console]::In.ReadToEnd()
$data = $inputStr | ConvertFrom-Json

# Extract model, cwd, dir
$model = if ($data.model.display_name) { $data.model.display_name }
         elseif ($data.model.id)       { $data.model.id }
         else                          { "?" }
$cwd = $data.cwd
$dir = if ($cwd) { Split-Path -Leaf $cwd } else { "?" }

# Git info
$branch     = ""
$git_status = ""

if ($cwd -and (Test-Path $cwd -PathType Container)) {
    $branch = git -C $cwd branch --show-current 2>$null
    if ($branch) {
        # Count uncommitted files
        $porcelain  = @(git -C $cwd --no-optional-locks status --porcelain -uall 2>$null)
        $file_count = $porcelain.Count

        # Check upstream sync status
        $sync_status = ""
        $upstream    = git -C $cwd rev-parse --abbrev-ref '@{upstream}' 2>$null
        if ($upstream) {
            # Last fetch time
            $fetch_head = Join-Path $cwd ".git/FETCH_HEAD"
            $fetch_ago  = ""
            if (Test-Path $fetch_head) {
                $fetch_time = (Get-Item $fetch_head).LastWriteTimeUtc
                $diff       = [int]([DateTime]::UtcNow - $fetch_time).TotalSeconds
                $fetch_ago  = if     ($diff -lt 60)    { "<1m ago" }
                              elseif ($diff -lt 3600)  { "$([int]($diff / 60))m ago" }
                              elseif ($diff -lt 86400) { "$([int]($diff / 3600))h ago" }
                              else                     { "$([int]($diff / 86400))d ago" }
            }

            $counts = git -C $cwd rev-list --left-right --count "HEAD...@{upstream}" 2>$null
            if ($counts) {
                $parts  = ($counts -split '\s+')
                $ahead  = [int]$parts[0]
                $behind = [int]$parts[1]
                $sync_status = if ($ahead -eq 0 -and $behind -eq 0) {
                    if ($fetch_ago) { "synced $fetch_ago" } else { "synced" }
                } elseif ($ahead -gt 0 -and $behind -eq 0) { "$ahead ahead" }
                  elseif ($ahead -eq 0 -and $behind -gt 0) { "$behind behind" }
                  else                                      { "$ahead ahead, $behind behind" }
            } else {
                $sync_status = "no upstream"
            }
        } else {
            $sync_status = "no upstream"
        }

        # Build git status string
        $git_status = if ($file_count -eq 0) {
            "(0 files uncommitted, $sync_status)"
        } elseif ($file_count -eq 1) {
            $single_file = ($porcelain[0] -replace '^...', '').Trim()
            "($single_file uncommitted, $sync_status)"
        } else {
            "($file_count files uncommitted, $sync_status)"
        }
    }
}

# Transcript path and context window
$transcript_path = $data.transcript_path
$max_context     = if ($data.context_window.context_window_size) {
                       [int]$data.context_window.context_window_size
                   } else { 200000 }
$max_k = [int]($max_context / 1000)

function Build-ContextBar {
    param([int]$pct, [string]$pct_prefix)

    $bar_width = 10
    $bar = ""
    for ($i = 0; $i -lt $bar_width; $i++) {
        $progress = $pct - ($i * 10)
        $bar += if     ($progress -ge 8) { "$($script:C_ACCENT)$($script:CHR_FULL)$($script:C_RESET)" }
                elseif ($progress -ge 3) { "$($script:C_ACCENT)$($script:CHR_HALF)$($script:C_RESET)" }
                else                     { "$($script:C_BAR_EMPTY)$($script:CHR_EMPTY)$($script:C_RESET)" }
    }
    return "$bar $($script:C_GRAY)${pct_prefix}${pct}% of $($script:max_k)k tokens"
}

# Parse transcript (JSONL - one JSON object per line)
$entries = @()
if ($transcript_path -and (Test-Path $transcript_path)) {
    $entries = @(Get-Content $transcript_path | Where-Object { $_.Trim() } | ForEach-Object {
        try { ConvertFrom-Json $_ } catch { $null }
    } | Where-Object { $_ -ne $null })
}

$baseline       = 20000
$pct_prefix     = ""
$context_length = 0

if ($entries.Count -gt 0) {
    $relevant = @($entries | Where-Object {
        $_.message.usage -and
        $_.isSidechain       -ne $true -and
        $_.isApiErrorMessage -ne $true
    })

    if ($relevant.Count -gt 0) {
        $last = $relevant[-1]
        $u    = $last.message.usage
        $context_length = [int](if ($u.input_tokens)              { $u.input_tokens }              else { 0 }) +
                          [int](if ($u.cache_read_input_tokens)    { $u.cache_read_input_tokens }    else { 0 }) +
                          [int](if ($u.cache_creation_input_tokens){ $u.cache_creation_input_tokens } else { 0 })
    }

    if ($context_length -gt 0) {
        $pct = [int]($context_length * 100 / $max_context)
    } else {
        $pct        = [int]($baseline * 100 / $max_context)
        $pct_prefix = "~"
    }
    if ($pct -gt 100) { $pct = 100 }
    $ctx = Build-ContextBar -pct $pct -pct_prefix $pct_prefix
} else {
    $pct = [int]($baseline * 100 / $max_context)
    if ($pct -gt 100) { $pct = 100 }
    $ctx = Build-ContextBar -pct $pct -pct_prefix "~"
}

# Build and print main status line
$output = "${C_ACCENT}${model}${C_GRAY} | ${ICON_DIR} ${dir}"
if ($branch) { $output += " | ${ICON_BRANCH} ${branch} ${git_status}" }
$output += " | ${ctx}${C_RESET}"
[Console]::WriteLine($output)

# Last user message (second line)
if ($entries.Count -gt 0) {
    $plain_output = "${model} | ${ICON_DIR} ${dir}"
    if ($branch) { $plain_output += " | ${ICON_BRANCH} ${branch} ${git_status}" }
    $plain_output += " | $('x' * 10) ${pct}% of ${max_k}k tokens"
    $max_len = $plain_output.Length

    $last_user_msg = ""
    $user_entries  = @($entries | Where-Object {
        $_.type -eq "user" -and (
            ($_.message.content -is [string]) -or
            ($_.message.content -is [array] -and
             ($_.message.content | Where-Object { $_.type -eq "text" }).Count -gt 0)
        )
    })

    for ($i = $user_entries.Count - 1; $i -ge 0; $i--) {
        $content = $user_entries[$i].message.content
        $text = if ($content -is [string]) {
            $content
        } else {
            ($content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join " "
        }
        $text = ($text -replace "`n", " " -replace "  +", " ").Trim()

        if ($text -and
            -not $text.StartsWith("[Request interrupted") -and
            -not $text.StartsWith("[Request cancelled")) {
            $last_user_msg = $text
            break
        }
    }

    if ($last_user_msg) {
        if ($last_user_msg.Length -gt $max_len) {
            [Console]::WriteLine("${ICON_MSG} $($last_user_msg.Substring(0, $max_len - 3))...")
        } else {
            [Console]::WriteLine("${ICON_MSG} ${last_user_msg}")
        }
    }
}
