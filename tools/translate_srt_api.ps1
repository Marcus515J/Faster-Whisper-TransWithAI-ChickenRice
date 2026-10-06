param(
    [Parameter(Position = 0)]
    [string]$InputPath = "",
    [string]$OutputPath = "",
    [string]$BaseUrl = "",
    [string]$ApiKey = "",
    [string]$Model = "",
    [int]$BatchSize = 20,
    [int]$MaxRetries = 3,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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
        if ($lines.Count -lt 3) {
            throw "Invalid SRT block: expected index, timestamp, and text."
        }

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
        if (-not $sourceText) {
            throw "Empty subtitle at index $indexValue"
        }

        $entries.Add([pscustomobject]@{
            id = $indexValue
            index_line = $indexText
            timestamp = $timestamp
            ja = $sourceText
        }) | Out-Null
    }

    for ($i = 0; $i -lt $entries.Count; $i++) {
        if ($entries[$i].id -ne ($i + 1)) {
            throw "SRT indices must be contiguous from 1. Found $($entries[$i].id) at position $($i + 1)."
        }
    }

    return $entries
}

function Get-DefaultOutputPath([string]$Path) {
    $directory = Split-Path $Path -Parent
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    return Join-Path $directory ($name + ".zh.srt")
}

function Get-ProgressPath([string]$Path) {
    return $Path + ".progress.json"
}

function Load-Progress([string]$Path) {
    $map = @{}
    if (-not (Test-Path $Path)) {
        return $map
    }

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
    if (-not $value) {
        throw "Base URL is required."
    }
    if ($value -match '/chat/completions$') {
        return $value
    }
    return $value + "/chat/completions"
}

function Get-PlainTextFromSecureString([Security.SecureString]$Secure) {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Resolve-ApiSettings {
    $configPath = Join-Path $PSScriptRoot "translation_api_config.json"

    if (Test-Path $configPath) {
        try {
            $config = (Read-Utf8Text $configPath) | ConvertFrom-Json
            if (-not $script:BaseUrl -and $config.base_url) { $script:BaseUrl = [string]$config.base_url }
            if (-not $script:Model -and $config.model) { $script:Model = [string]$config.model }
            if (-not $script:ApiKey -and $config.api_key) { $script:ApiKey = [string]$config.api_key }
        }
        catch {
            throw "translation_api_config.json is invalid."
        }
    }

    if (-not $script:BaseUrl) { $script:BaseUrl = [string]$env:CHICKENRICE_TRANSLATE_BASE_URL }
    if (-not $script:Model) { $script:Model = [string]$env:CHICKENRICE_TRANSLATE_MODEL }
    if (-not $script:ApiKey) { $script:ApiKey = [string]$env:CHICKENRICE_TRANSLATE_API_KEY }

    if (-not $script:BaseUrl) { $script:BaseUrl = Read-Host "OpenAI-compatible Base URL (for example https://api.example.com/v1)" }
    if (-not $script:Model) { $script:Model = Read-Host "Model name" }
    if (-not $script:ApiKey) {
        $secure = Read-Host "API key" -AsSecureString
        $script:ApiKey = Get-PlainTextFromSecureString $secure
    }

    if (-not $script:BaseUrl -or -not $script:Model -or -not $script:ApiKey) {
        throw "Base URL, model, and API key are all required."
    }
}

function Strip-CodeFence([string]$Text) {
    $value = $Text.Trim()
    if ($value -match '^```(?:json)?\s*([\s\S]*?)\s*```$') {
        return $matches[1].Trim()
    }
    return $value
}

function Convert-TranslationResponse([string]$Content, [object[]]$Targets) {
    $jsonText = Strip-CodeFence $Content
    try {
        $parsed = $jsonText | ConvertFrom-Json
    }
    catch {
        throw "Model response was not valid JSON."
    }

    $items = @()
    foreach ($parsedItem in $parsed) {
        $items += $parsedItem
    }

    if ($items.Count -ne $Targets.Count) {
        throw "Model returned $($items.Count) item(s); expected $($Targets.Count)."
    }

    $expectedIds = @($Targets | ForEach-Object {[int]$_.id})
    $seen = @{}
    $result = @{}
    foreach ($item in $items) {
        $id = 0
        if (-not [int]::TryParse([string]$item.id, [ref]$id)) {
            throw "Model returned an invalid id."
        }
        if ($expectedIds -notcontains $id) {
            throw "Model returned unexpected id $id."
        }
        if ($seen.ContainsKey($id)) {
            throw "Model returned duplicate id $id."
        }
        if ($null -eq $item.zh) {
            throw "Model response for id $id has no zh field."
        }

        $seen[$id] = $true
        $result[$id] = ([string]$item.zh).Trim()
    }

    foreach ($id in $expectedIds) {
        if (-not $seen.ContainsKey($id)) {
            throw "Model omitted id $id."
        }
    }
    return $result
}

function Invoke-TranslationBatch(
    [object[]]$Targets,
    [object[]]$BeforeContext,
    [object[]]$AfterContext,
    [string]$Endpoint
) {
    $systemPrompt = @'
You translate Japanese movie subtitles into natural Simplified Chinese.
Return ONLY a JSON array. Every output object must contain exactly: {"id": <integer>, "zh": "<translated text>"}.
Rules:
1. Return exactly one object for every target id, in the same order. Never add, remove, merge, or split ids.
2. Translate only subtitle text. Never output timestamps, notes, explanations, markdown, or code fences.
3. Preserve intentional repetition, tone, short responses, names, and sexual dialogue when present. Do not sanitize the dialogue.
4. Use nearby context to resolve pronouns and wording, but never invent dialogue that is not supported by the Japanese source.
5. If a target is clearly only a non-verbal sound or meaningless ASR noise with no spoken semantic content, set zh to an empty string. Do this only when highly confident.
6. If the Japanese is garbled or uncertain, translate conservatively rather than fabricating a fluent sentence.
'@

    $payload = [ordered]@{
        context_before = @($BeforeContext | ForEach-Object {[ordered]@{id = $_.id; ja = $_.ja}})
        targets = @($Targets | ForEach-Object {[ordered]@{id = $_.id; ja = $_.ja}})
        context_after = @($AfterContext | ForEach-Object {[ordered]@{id = $_.id; ja = $_.ja}})
    }
    $userPrompt = "Translate the target subtitles. Context items are for understanding only and must not appear in the output.`n" + ($payload | ConvertTo-Json -Depth 8 -Compress)

    $requestBody = [ordered]@{
        model = $script:Model
        temperature = 0.1
        messages = @(
            [ordered]@{role = "system"; content = $systemPrompt},
            [ordered]@{role = "user"; content = $userPrompt}
        )
    }
    $headers = @{
        Authorization = "Bearer $($script:ApiKey)"
        "Content-Type" = "application/json; charset=utf-8"
    }

    $bodyJson = $requestBody | ConvertTo-Json -Depth 10 -Compress
    $response = Invoke-RestMethod -Method Post -Uri $Endpoint -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($bodyJson)) -TimeoutSec 300
    if ($null -eq $response.choices -or $response.choices.Count -lt 1) {
        throw "API response has no choices."
    }

    $content = [string]$response.choices[0].message.content
    if (-not $content) {
        throw "API response content is empty."
    }
    return Convert-TranslationResponse $content $Targets
}

function Build-Srt([object[]]$Entries, [hashtable]$Translations) {
    $blocks = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Entries) {
        if (-not $Translations.ContainsKey([int]$entry.id)) {
            throw "Missing translation for id $($entry.id)."
        }

        $zh = [string]$Translations[[int]$entry.id]
        if (-not $zh) {
            $zh = [char]0x200B
        }
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
    $sample = "1`r`n00:00:01,000 --> 00:00:02,500`r`nkonnichiwa`r`n`r`n2`r`n00:00:03,000 --> 00:00:04,000`r`nhai`r`n"
    $entries = @(Parse-Srt $sample)
    if ($entries.Count -ne 2) { throw "Self-test parse count failed." }

    $translations = @{1 = "hello"; 2 = ""}
    $output = Build-Srt $entries $translations
    Assert-TimelineLocked $entries $output
    if ($output -notmatch '00:00:01,000 --> 00:00:02,500' -or $output -notmatch 'hello') {
        throw "Self-test output failed."
    }

    $response = '[{"id":1,"zh":"hello"},{"id":2,"zh":"yes"}]'
    $parsedResponse = Convert-TranslationResponse $response $entries
    if ($parsedResponse[1] -ne "hello" -or $parsedResponse[2] -ne "yes") {
        throw "Self-test response validation failed."
    }
    Write-Host "SRT translation self-test passed." -ForegroundColor Green
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

if (-not $InputPath) {
    throw "Input SRT path is required."
}
$InputPath = (Resolve-Path -LiteralPath $InputPath).Path
if ([System.IO.Path]::GetExtension($InputPath).ToLowerInvariant() -ne ".srt") {
    throw "Input must be an .srt file."
}
if ($BatchSize -lt 1 -or $BatchSize -gt 60) {
    throw "BatchSize must be between 1 and 60."
}
if ($MaxRetries -lt 1 -or $MaxRetries -gt 8) {
    throw "MaxRetries must be between 1 and 8."
}
if (-not $OutputPath) {
    $OutputPath = Get-DefaultOutputPath $InputPath
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if ($OutputPath -eq $InputPath) {
    throw "Output path must be different from the source SRT."
}

$sourceText = Read-Utf8Text $InputPath
$entries = @(Parse-Srt $sourceText)
if ($entries.Count -eq 0) {
    throw "No subtitle entries found."
}

Resolve-ApiSettings
$endpoint = Normalize-Endpoint $BaseUrl
$progressPath = Get-ProgressPath $OutputPath
$translations = Load-Progress $progressPath

foreach ($key in @($translations.Keys)) {
    if ([int]$key -lt 1 -or [int]$key -gt $entries.Count) {
        $translations.Remove($key)
    }
}

Write-Host "Source: $InputPath"
Write-Host "Output: $OutputPath"
Write-Host "Model: $Model"
Write-Host "Entries: $($entries.Count)"
if ($translations.Count -gt 0) {
    Write-Host "Resuming from checkpoint: $($translations.Count) translated entry/entries."
}

for ($start = 0; $start -lt $entries.Count; $start += $BatchSize) {
    $end = [Math]::Min($entries.Count - 1, $start + $BatchSize - 1)
    $targets = @($entries[$start..$end] | Where-Object {-not $translations.ContainsKey([int]$_.id)})
    if ($targets.Count -eq 0) {
        continue
    }

    $beforeStart = [Math]::Max(0, $start - 3)
    $before = if ($start -gt 0) { @($entries[$beforeStart..($start - 1)]) } else { @() }
    $afterEnd = [Math]::Min($entries.Count - 1, $end + 3)
    $after = if ($end -lt $entries.Count - 1) { @($entries[($end + 1)..$afterEnd]) } else { @() }

    $attempt = 0
    $batchResult = $null
    while ($attempt -lt $MaxRetries -and $null -eq $batchResult) {
        $attempt++
        try {
            Write-Host ("Translating {0}-{1}/{2} (attempt {3})..." -f ($start + 1), ($end + 1), $entries.Count, $attempt)
            $batchResult = Invoke-TranslationBatch $targets $before $after $endpoint
        }
        catch {
            Write-Warning ("Batch failed: " + $_.Exception.Message)
            if ($attempt -ge $MaxRetries) { throw }
            Start-Sleep -Seconds ([Math]::Min(8, 2 * $attempt))
        }
    }

    foreach ($id in $batchResult.Keys) {
        $translations[[int]$id] = [string]$batchResult[$id]
    }
    Save-Progress $progressPath $translations
}

$outputText = Build-Srt $entries $translations
Assert-TimelineLocked $entries $outputText
$tempOutput = $OutputPath + ".tmp"
Write-Utf8NoBom $tempOutput $outputText
Move-Item -LiteralPath $tempOutput -Destination $OutputPath -Force
Remove-Item -LiteralPath $progressPath -Force -ErrorAction SilentlyContinue

Write-Host "Translation completed." -ForegroundColor Green
Write-Host "Timeline lock verified: $($entries.Count) indices and timestamps unchanged." -ForegroundColor Green
Write-Host "Saved: $OutputPath" -ForegroundColor Green
