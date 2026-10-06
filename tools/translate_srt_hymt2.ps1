param(
    [Parameter(Position = 0)]
    [string]$InputPath = "",
    [string]$OutputPath = "",
    [string]$BaseUrl = "http://127.0.0.1:8080/v1",
    [string]$ApiKey = "local",
    [string]$Model = "HY-MT2-7B-Q8_0",
    [int]$BatchSize = 20,
    [int]$MaxRetries = 2,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:Delimiter = "<|CR_SRT_SPLIT_9B7F|>"

function Read-Utf8Text([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Parse-Srt([string]$Text) {
    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $blocks = [regex]::Split($normalized.Trim(), "`n[ \t]*`n+")
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($block in $blocks) {
        $lines = $block -split "`n"
        if ($lines.Count -lt 3) { throw "Invalid SRT block." }

        $indexText = $lines[0].Trim()
        $indexValue = 0
        if (-not [int]::TryParse($indexText, [ref]$indexValue)) {
            throw "Invalid SRT index: $indexText"
        }

        $timestamp = $lines[1].Trim()
        if ($timestamp -notmatch '^\d{2}:\d{2}:\d{2},\d{3}\s+-->\s+\d{2}:\d{2}:\d{2},\d{3}$') {
            throw "Invalid SRT timestamp at index ${indexValue}: $timestamp"
        }

        $sourceText = (($lines[2..($lines.Count - 1)]) -join "`n").Trim()
        if (-not $sourceText) { throw "Empty subtitle at index $indexValue" }

        $entries.Add([pscustomobject]@{
            id = $indexValue
            index_line = $indexText
            timestamp = $timestamp
            ja = $sourceText
        }) | Out-Null
    }

    for ($i = 0; $i -lt $entries.Count; $i++) {
        if ($entries[$i].id -ne ($i + 1)) {
            throw "SRT indices must be contiguous from 1."
        }
    }
    return $entries
}

function Get-DefaultOutputPath([string]$Path) {
    $directory = Split-Path $Path -Parent
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    return Join-Path $directory ($name + ".hy-mt2.zh.srt")
}

function Get-ProgressPath([string]$Path) {
    return $Path + ".progress.json"
}

function Load-Progress([string]$Path) {
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }

    try {
        $saved = (Read-Utf8Text $Path) | ConvertFrom-Json
        foreach ($property in $saved.PSObject.Properties) {
            $id = 0
            if ([int]::TryParse($property.Name, [ref]$id)) {
                $map[$id] = [string]$property.Value
            }
        }
    }
    catch {
        throw "Progress file is invalid: $Path"
    }
    return $map
}

function Save-Progress([string]$Path, [hashtable]$Map) {
    $ordered = [ordered]@{}
    foreach ($key in ($Map.Keys | Sort-Object {[int]$_})) {
        $ordered[[string]$key] = [string]$Map[$key]
    }
    Write-Utf8NoBom $Path ($ordered | ConvertTo-Json -Depth 4)
}

function Normalize-Endpoint([string]$Url) {
    $value = $Url.Trim().TrimEnd('/')
    if (-not $value) { throw "Base URL is required." }
    if ($value -match '/chat/completions$') { return $value }
    return $value + "/chat/completions"
}

function Strip-CodeFence([string]$Text) {
    $value = $Text.Trim()
    if ($value -match '^```(?:text)?\s*([\s\S]*?)\s*```$') {
        return $matches[1].Trim()
    }
    return $value
}

function Invoke-HyMt2Api([string]$Prompt, [string]$Endpoint) {
    $requestBody = [ordered]@{
        model = $script:Model
        temperature = 0.1
        max_tokens = 2048
        messages = @(
            [ordered]@{role = "user"; content = $Prompt}
        )
    }

    $headers = @{"Content-Type" = "application/json; charset=utf-8"}
    if ($script:ApiKey) {
        $headers["Authorization"] = "Bearer $($script:ApiKey)"
    }

    $bodyJson = $requestBody | ConvertTo-Json -Depth 8 -Compress
    $response = Invoke-RestMethod -Method Post -Uri $Endpoint -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($bodyJson)) -TimeoutSec 300
    if ($null -eq $response.choices -or $response.choices.Count -lt 1) {
        throw "API response has no choices."
    }

    $content = [string]$response.choices[0].message.content
    if ($null -eq $content) { throw "API response content is missing." }
    return Strip-CodeFence $content
}

function Get-NeighborContext([object[]]$Targets) {
    $firstId = [int]$Targets[0].id
    $lastId = [int]$Targets[$Targets.Count - 1].id

    $before = @()
    $beforeFirst = [Math]::Max(1, $firstId - 3)
    if ($firstId -gt 1) {
        $before = @($script:Entries[($beforeFirst - 1)..($firstId - 2)])
    }

    $after = @()
    $afterLast = [Math]::Min($script:Entries.Count, $lastId + 3)
    if ($lastId -lt $script:Entries.Count) {
        $after = @($script:Entries[$lastId..($afterLast - 1)])
    }

    return [pscustomobject]@{Before = $before; After = $after}
}

function Join-ContextText([object[]]$Items) {
    if ($Items.Count -eq 0) { return "(none)" }
    return (($Items | ForEach-Object {[string]$_.ja}) -join "`n")
}

function Invoke-DelimiterBatch([object[]]$Targets, [string]$Endpoint) {
    if ($Targets.Count -lt 2) { throw "Delimiter batch requires at least two targets." }

    $ctx = Get-NeighborContext $Targets
    $beforeText = Join-ContextText $ctx.Before
    $afterText = Join-ContextText $ctx.After
    $sourceText = (($Targets | ForEach-Object {[string]$_.ja}) -join ("`n" + $script:Delimiter + "`n"))

    $prompt = @"
Translate the Japanese subtitle segments in [Source Text] into Simplified Chinese. Output only the translated subtitle segments.

Strict requirements:
1. Every line that consists only of $($script:Delimiter) is a delimiter. Preserve every delimiter from [Source Text] exactly. Do not omit, escape, translate, alter, or move it.
2. Each source segment must correspond to exactly one translated segment in the same order. Do not merge or split segments.
3. Preserve intentional repetition, short replies, names, and explicit, sexual, vulgar, or colloquial wording. Do not sanitize, soften, or euphemize it.
4. If Japanese ASR text is garbled or uncertain, translate conservatively. Do not invent, repair, or add unsupported meaning.
5. Use [Background Before] and [Background After] only for disambiguation. Do not translate or output background text.
6. Do not output explanations, labels, markdown, JSON, timestamps, or subtitle indices.

[Background Before]
$beforeText

[Background After]
$afterText

[Source Text]
$sourceText
"@

    $content = Invoke-HyMt2Api $prompt $Endpoint
    $parts = @([regex]::Split($content, [regex]::Escape($script:Delimiter)))
    if ($parts.Count -ne $Targets.Count) {
        throw "Model returned $($parts.Count) segment(s); expected $($Targets.Count)."
    }

    $result = @{}
    for ($i = 0; $i -lt $Targets.Count; $i++) {
        $result[[int]$Targets[$i].id] = ([string]$parts[$i]).Trim()
    }
    return $result
}

function Invoke-SingleTarget([object]$Target, [string]$Endpoint) {
    $targets = @($Target)
    $ctx = Get-NeighborContext $targets
    $beforeText = Join-ContextText $ctx.Before
    $afterText = Join-ContextText $ctx.After

    $prompt = @"
Translate the Japanese subtitle in [Source Text] into Simplified Chinese. Output only the translated result without any additional explanation.

Strict requirements:
1. Preserve intentional repetition, short replies, names, and explicit, sexual, vulgar, or colloquial wording. Do not sanitize, soften, or euphemize it.
2. If the Japanese ASR text is garbled or uncertain, translate conservatively. Do not invent, repair, or add unsupported meaning.
3. Use the background only for disambiguation. Do not translate or output background text.
4. Do not output labels, markdown, JSON, timestamps, or subtitle indices.

[Background Before]
$beforeText

[Background After]
$afterText

[Source Text]
$([string]$Target.ja)
"@

    $content = Invoke-HyMt2Api $prompt $Endpoint
    return ([string]$content).Trim()
}

function Store-Translations([hashtable]$Result) {
    foreach ($id in $Result.Keys) {
        $script:Translations[[int]$id] = [string]$Result[$id]
    }
    Save-Progress $script:ProgressPath $script:Translations
}

function Invoke-ResilientGroup([object[]]$Targets, [string]$Endpoint) {
    if ($Targets.Count -eq 0) { return }

    if ($Targets.Count -eq 1) {
        $lastError = $null
        for ($attempt = 1; $attempt -le $script:MaxRetries; $attempt++) {
            try {
                Write-Host ("Translating {0}/{1} as single item (attempt {2})..." -f $Targets[0].id, $script:Entries.Count, $attempt)
                $text = Invoke-SingleTarget $Targets[0] $Endpoint
                Store-Translations @{([int]$Targets[0].id) = $text}
                return
            }
            catch {
                $lastError = $_
                Write-Warning ("Single item failed: " + $_.Exception.Message)
                if ($attempt -lt $script:MaxRetries) { Start-Sleep -Seconds (2 * $attempt) }
            }
        }
        throw $lastError
    }

    $lastBatchError = $null
    for ($attempt = 1; $attempt -le $script:MaxRetries; $attempt++) {
        try {
            $first = [int]$Targets[0].id
            $last = [int]$Targets[$Targets.Count - 1].id
            Write-Host ("Translating {0}-{1}/{2} (attempt {3})..." -f $first, $last, $script:Entries.Count, $attempt)
            $result = Invoke-DelimiterBatch $Targets $Endpoint
            Store-Translations $result
            return
        }
        catch {
            $lastBatchError = $_
            Write-Warning ("Batch failed: " + $_.Exception.Message)
            if ($attempt -lt $script:MaxRetries) { Start-Sleep -Seconds (2 * $attempt) }
        }
    }

    $mid = [int][Math]::Floor($Targets.Count / 2)
    if ($mid -lt 1) { throw $lastBatchError }

    $left = @($Targets[0..($mid - 1)])
    $right = @($Targets[$mid..($Targets.Count - 1)])
    Write-Warning ("Splitting failed batch of {0} into {1} + {2}." -f $Targets.Count, $left.Count, $right.Count)
    Invoke-ResilientGroup $left $Endpoint
    Invoke-ResilientGroup $right $Endpoint
}

function Build-Srt([object[]]$Entries, [hashtable]$Translations) {
    $blocks = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Entries) {
        if (-not $Translations.ContainsKey([int]$entry.id)) {
            throw "Missing translation for id $($entry.id)."
        }
        $zh = [string]$Translations[[int]$entry.id]
        if (-not $zh) { $zh = [char]0x200B }
        $blocks.Add("$($entry.index_line)`r`n$($entry.timestamp)`r`n$zh") | Out-Null
    }
    return ($blocks -join "`r`n`r`n") + "`r`n"
}

function Assert-TimelineLocked([object[]]$SourceEntries, [string]$OutputText) {
    $translatedEntries = @(Parse-Srt $OutputText)
    if ($translatedEntries.Count -ne $SourceEntries.Count) {
        throw "Output entry count changed."
    }
    for ($i = 0; $i -lt $SourceEntries.Count; $i++) {
        if ($translatedEntries[$i].index_line -ne $SourceEntries[$i].index_line) {
            throw "Output index changed at position $($i + 1)."
        }
        if ($translatedEntries[$i].timestamp -ne $SourceEntries[$i].timestamp) {
            throw "Output timestamp changed at index $($SourceEntries[$i].id)."
        }
    }
}

function Invoke-SelfTest {
    $sample = "1`r`n00:00:01,000 --> 00:00:02,000`r`none`r`n`r`n2`r`n00:00:03,000 --> 00:00:04,000`r`ntwo`r`n"
    $entries = @(Parse-Srt $sample)
    if ($entries.Count -ne 2) { throw "Self-test parse failed." }

    $joined = "A$($script:Delimiter)B"
    $parts = @([regex]::Split($joined, [regex]::Escape($script:Delimiter)))
    if ($parts.Count -ne 2 -or $parts[0] -ne "A" -or $parts[1] -ne "B") {
        throw "Self-test delimiter split failed."
    }
    Write-Host "Hy-MT2 translator self-test passed." -ForegroundColor Green
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

if (-not $InputPath) { throw "Input SRT path is required." }
$InputPath = (Resolve-Path -LiteralPath $InputPath).Path
if ([System.IO.Path]::GetExtension($InputPath).ToLowerInvariant() -ne ".srt") {
    throw "Input must be an .srt file."
}
if ($BatchSize -lt 2 -or $BatchSize -gt 60) {
    throw "BatchSize must be between 2 and 60."
}
if ($MaxRetries -lt 1 -or $MaxRetries -gt 5) {
    throw "MaxRetries must be between 1 and 5."
}
if (-not $OutputPath) { $OutputPath = Get-DefaultOutputPath $InputPath }
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if ($OutputPath -eq $InputPath) { throw "Output path must differ from input." }

$sourceText = Read-Utf8Text $InputPath
$script:Entries = @(Parse-Srt $sourceText)
if ($script:Entries.Count -eq 0) { throw "No subtitle entries found." }

$script:BaseUrl = $BaseUrl
$script:ApiKey = $ApiKey
$script:Model = $Model
$script:MaxRetries = $MaxRetries
$endpoint = Normalize-Endpoint $BaseUrl
$script:ProgressPath = Get-ProgressPath $OutputPath
$script:Translations = Load-Progress $script:ProgressPath

foreach ($key in @($script:Translations.Keys)) {
    if ([int]$key -lt 1 -or [int]$key -gt $script:Entries.Count) {
        $script:Translations.Remove($key)
    }
}

Write-Host "Source: $InputPath"
Write-Host "Output: $OutputPath"
Write-Host "Model: $Model"
Write-Host "Entries: $($script:Entries.Count)"
Write-Host "Mode: Hy-MT2 delimiter-preserving translation with automatic split fallback"
if ($script:Translations.Count -gt 0) {
    Write-Host "Resuming from checkpoint: $($script:Translations.Count) translated entry/entries."
}

for ($start = 0; $start -lt $script:Entries.Count; $start += $BatchSize) {
    $end = [Math]::Min($script:Entries.Count - 1, $start + $BatchSize - 1)
    $targets = @($script:Entries[$start..$end] | Where-Object {-not $script:Translations.ContainsKey([int]$_.id)})
    if ($targets.Count -eq 0) { continue }
    Invoke-ResilientGroup $targets $endpoint
}

$outputText = Build-Srt $script:Entries $script:Translations
Assert-TimelineLocked $script:Entries $outputText
$tempOutput = $OutputPath + ".tmp"
Write-Utf8NoBom $tempOutput $outputText
Move-Item -LiteralPath $tempOutput -Destination $OutputPath -Force
Remove-Item -LiteralPath $script:ProgressPath -Force -ErrorAction SilentlyContinue

Write-Host "Translation completed." -ForegroundColor Green
Write-Host "Timeline lock verified: $($script:Entries.Count) indices and timestamps unchanged." -ForegroundColor Green
Write-Host "Saved: $OutputPath" -ForegroundColor Green
