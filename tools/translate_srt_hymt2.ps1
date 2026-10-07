param(
    [Parameter(Position = 0)]
    [string]$InputPath = "",
    [string]$OutputPath = "",
    [string]$BaseUrl = "http://127.0.0.1:8080/v1",
    [string]$ApiKey = "local",
    [string]$Model = "HY-MT2-7B-Q8_0",
    [string]$PromptConfigPath = "",
    [int]$BatchSize = 20,
    [int]$MaxRetries = 2,
    [int]$ShortSegmentChars = 0,
    [string]$LlamaServerPath = "H:\0AI\llama.cpp\llama-server.exe",
    [string]$LocalModelPath = "H:\0AI\models\HY-MT2-7B-Q8_0.gguf",
    [int]$ServerStartupTimeoutSec = 180,
    [switch]$UseExistingServer,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:Delimiter = "<|CR_SRT_SPLIT_9B7F|>"
$script:ManagedServerProcess = $null
$script:ManagedServerStdout = ""
$script:ManagedServerStderr = ""
$script:PromptRevision = "hymt2-stage2-v4"
$script:TermJaSeishi = ([string][char]0x305B) + ([string][char]0x30FC) + ([string][char]0x3057)
$script:TermZhSperm = ([string][char]0x7CBE) + ([string][char]0x5B50)
$script:TerminologyLine = "$($script:TermJaSeishi) translates to $($script:TermZhSperm)"
$script:SystemRole = "You are a professional Japanese-to-Simplified-Chinese film subtitle translator. Preserve source meaning, tone, register, names, explicit content, and conversational intent. Never censor, sanitize, or euphemize source content."
$script:StylePrompt = "Use natural, concise Simplified Chinese suitable for on-screen film subtitles. Prefer spoken Chinese over stiff literal wording, but do not add meaning that is absent from the Japanese."
$script:FilmNotes = ""
$script:ExtraTerminologyLines = @()

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

function Load-PromptConfig([string]$Path) {
    if (-not $Path) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Prompt config was not found: $Path"
    }

    try {
        $cfg = (Read-Utf8Text $Path) | ConvertFrom-Json
    }
    catch {
        throw "Prompt config is invalid JSON: $Path"
    }

    if ($cfg.PSObject.Properties.Name -contains "system_role") {
        $script:SystemRole = [string]$cfg.system_role
    }
    if ($cfg.PSObject.Properties.Name -contains "style_prompt") {
        $script:StylePrompt = [string]$cfg.style_prompt
    }
    if ($cfg.PSObject.Properties.Name -contains "film_notes") {
        $script:FilmNotes = [string]$cfg.film_notes
    }

    if ($cfg.PSObject.Properties.Name -contains "terminology") {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($term in @($cfg.terminology)) {
            if ($null -eq $term) { continue }
            if (-not ($term.PSObject.Properties.Name -contains "source") -or -not ($term.PSObject.Properties.Name -contains "target")) {
                throw "Each terminology item must contain source and target."
            }
            $source = ([string]$term.source).Trim()
            $target = ([string]$term.target).Trim()
            if (-not $source -or -not $target) {
                throw "Terminology source and target must not be empty."
            }
            if ($source -eq $script:TermJaSeishi) {
                $script:TerminologyLine = "$source translates to $target"
            }
            else {
                $lines.Add("$source translates to $target") | Out-Null
            }
        }
        $script:ExtraTerminologyLines = @($lines)
    }
}

function Get-PromptGuidance {
    $sections = New-Object System.Collections.Generic.List[string]
    $terms = @($script:TerminologyLine) + @($script:ExtraTerminologyLines)
    $terms = @($terms | Where-Object { $_ -and ([string]$_).Trim() })
    if ($terms.Count -gt 0) {
        $sections.Add("Reference the following translations:`n" + ($terms -join "`n")) | Out-Null
    }
    if ($script:StylePrompt -and $script:StylePrompt.Trim()) {
        $sections.Add("Translation style:`n" + $script:StylePrompt.Trim()) | Out-Null
    }
    if ($script:FilmNotes -and $script:FilmNotes.Trim()) {
        $sections.Add("Film/context notes:`n" + $script:FilmNotes.Trim() + "`nUse these notes only when supported by the subtitle text. Do not invent details from the notes.") | Out-Null
    }
    return ($sections -join "`n`n")
}

function Get-Sha256Hex([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-TranslationFingerprint([string]$SourceText) {
    $payload = [ordered]@{
        prompt_revision = $script:PromptRevision
        source_sha256 = Get-Sha256Hex $SourceText
        model = $script:Model
        batch_size = $BatchSize
        short_segment_chars = $ShortSegmentChars
        system_role = $script:SystemRole
        style_prompt = $script:StylePrompt
        film_notes = $script:FilmNotes
        terminology = @($script:TerminologyLine) + @($script:ExtraTerminologyLines)
    }
    return Get-Sha256Hex ($payload | ConvertTo-Json -Depth 6 -Compress)
}

function Get-DefaultOutputPath([string]$Path) {
    $directory = Split-Path $Path -Parent
    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    return Join-Path $directory ($name + ".hy-mt2.zh.srt")
}

function Get-ProgressPath([string]$Path, [string]$Fingerprint) {
    return $Path + "." + $Fingerprint.Substring(0, 12) + ".progress.json"
}

function Load-Progress([string]$Path, [string]$ExpectedFingerprint) {
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }

    try {
        $saved = (Read-Utf8Text $Path) | ConvertFrom-Json
    }
    catch {
        throw "Progress file is invalid: $Path"
    }

    if (-not ($saved.PSObject.Properties.Name -contains "fingerprint")) {
        throw "Progress file has no translation fingerprint and will not be reused: $Path"
    }
    if ([string]$saved.fingerprint -ne $ExpectedFingerprint) {
        throw "Progress fingerprint does not match the current source/model/prompt settings: $Path"
    }
    if (-not ($saved.PSObject.Properties.Name -contains "translations")) {
        throw "Progress file is missing translations: $Path"
    }

    foreach ($property in $saved.translations.PSObject.Properties) {
        $id = 0
        if ([int]::TryParse($property.Name, [ref]$id)) {
            $map[$id] = [string]$property.Value
        }
    }
    return $map
}

function Save-Progress([string]$Path, [hashtable]$Map) {
    $ordered = [ordered]@{}
    foreach ($key in ($Map.Keys | Sort-Object {[int]$_})) {
        $ordered[[string]$key] = [string]$Map[$key]
    }

    $payload = [ordered]@{
        schema_version = 2
        fingerprint = $script:TranslationFingerprint
        prompt_revision = $script:PromptRevision
        translations = $ordered
    }
    Write-Utf8NoBom $Path ($payload | ConvertTo-Json -Depth 8)
}

function Normalize-Endpoint([string]$Url) {
    $value = $Url.Trim().TrimEnd('/')
    if (-not $value) { throw "Base URL is required." }
    if ($value -match '/chat/completions$') { return $value }
    return $value + "/chat/completions"
}

function Test-IsLoopbackUrl([string]$Url) {
    try {
        $uri = [uri]$Url
        return $uri.Host -in @("127.0.0.1", "localhost", "::1")
    }
    catch {
        return $false
    }
}

function Get-HealthEndpoint([string]$Url) {
    $uri = [uri]$Url
    return "$($uri.Scheme)://$($uri.Authority)/v1/health"
}

function Test-HyMt2ServerReady([string]$Url) {
    try {
        $response = Invoke-RestMethod -Method Get -Uri (Get-HealthEndpoint $Url) -TimeoutSec 2
        return ([string]$response.status -eq "ok")
    }
    catch {
        return $false
    }
}

function Get-ServerLogTail {
    $chunks = New-Object System.Collections.Generic.List[string]
    foreach ($path in @($script:ManagedServerStderr, $script:ManagedServerStdout)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            $tail = (Get-Content -LiteralPath $path -Tail 20 -ErrorAction SilentlyContinue | Out-String).Trim()
            if ($tail) { $chunks.Add($tail) | Out-Null }
        }
    }
    return ($chunks -join "`n")
}

function Start-ManagedLocalServer([string]$Url) {
    if (-not (Test-Path -LiteralPath $LlamaServerPath)) {
        throw "llama-server was not found: $LlamaServerPath"
    }
    if (-not (Test-Path -LiteralPath $LocalModelPath)) {
        throw "Hy-MT2 model was not found: $LocalModelPath"
    }
    if (Test-HyMt2ServerReady $Url) {
        throw "A server is already listening at $Url. Stop it first, or use -UseExistingServer for deliberate debugging."
    }

    $runtimeDir = Join-Path (Split-Path $LocalModelPath -Parent) ".hymt2-runtime"
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    $runId = [guid]::NewGuid().ToString("N")
    $script:ManagedServerStdout = Join-Path $runtimeDir ("llama-server-$runId.out.log")
    $script:ManagedServerStderr = Join-Path $runtimeDir ("llama-server-$runId.err.log")

    $arguments = @(
        "-m", $LocalModelPath,
        "-ngl", "999",
        "-c", "8192",
        "--host", "127.0.0.1",
        "--port", "8080"
    )

    Write-Host "Starting local Hy-MT2 server on demand..."
    $script:ManagedServerProcess = Start-Process -FilePath $LlamaServerPath -ArgumentList $arguments -WorkingDirectory (Split-Path $LlamaServerPath -Parent) -WindowStyle Hidden -RedirectStandardOutput $script:ManagedServerStdout -RedirectStandardError $script:ManagedServerStderr -PassThru

    $deadline = (Get-Date).AddSeconds($ServerStartupTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ($script:ManagedServerProcess.HasExited) {
            $tail = Get-ServerLogTail
            if ($tail) { throw "llama-server exited before becoming ready.`n$tail" }
            throw "llama-server exited before becoming ready."
        }
        if (Test-HyMt2ServerReady $Url) {
            Write-Host "Local Hy-MT2 server is ready." -ForegroundColor Green
            return
        }
        Start-Sleep -Seconds 1
    }

    $tail = Get-ServerLogTail
    if ($tail) { throw "Timed out waiting for llama-server after $ServerStartupTimeoutSec second(s).`n$tail" }
    throw "Timed out waiting for llama-server after $ServerStartupTimeoutSec second(s)."
}

function Stop-ManagedLocalServer {
    if ($null -ne $script:ManagedServerProcess) {
        try {
            if (-not $script:ManagedServerProcess.HasExited) {
                $taskkill = Get-Command taskkill.exe -ErrorAction SilentlyContinue
                if ($taskkill) {
                    & $taskkill.Source /PID $script:ManagedServerProcess.Id /T /F 2>$null | Out-Null
                    Start-Sleep -Milliseconds 300
                }
                if (-not $script:ManagedServerProcess.HasExited) {
                    Stop-Process -Id $script:ManagedServerProcess.Id -Force -ErrorAction SilentlyContinue
                }
            }
        }
        finally {
            Write-Host "Local Hy-MT2 server stopped." -ForegroundColor Green
            $script:ManagedServerProcess = $null
        }
    }

    foreach ($path in @($script:ManagedServerStdout, $script:ManagedServerStderr)) {
        if ($path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

function Strip-CodeFence([string]$Text) {
    $value = $Text.Trim()
    if ($value -match '^```[^\r\n]*\s*([\s\S]*?)\s*```$') {
        return $matches[1].Trim()
    }
    return $value
}

function Clean-TranslationText([string]$Text, [string]$SourceText) {
    $value = (Strip-CodeFence ([string]$Text)).Trim()
    $value = [regex]::Replace($value, '^[\uFEFF\u200B]+', '')
    $value = [regex]::Replace($value, '[\uFEFF\u200B]+$', '')
    $value = $value.Trim()

    $quotePairs = @(
        [pscustomobject]@{ Open = '"'; Close = '"' },
        [pscustomobject]@{ Open = "'"; Close = "'" },
        [pscustomobject]@{ Open = [string][char]0x201C; Close = [string][char]0x201D },
        [pscustomobject]@{ Open = [string][char]0x2018; Close = [string][char]0x2019 },
        [pscustomobject]@{ Open = [string][char]0x300C; Close = [string][char]0x300D },
        [pscustomobject]@{ Open = [string][char]0x300E; Close = [string][char]0x300F }
    )

    $source = ([string]$SourceText).Trim()
    $sourceWrapped = $false
    foreach ($pair in $quotePairs) {
        if ($source.Length -ge 2 -and $source.StartsWith($pair.Open) -and $source.EndsWith($pair.Close)) {
            $sourceWrapped = $true
            break
        }
    }

    if (-not $sourceWrapped) {
        for ($pass = 0; $pass -lt 2; $pass++) {
            $removed = $false
            foreach ($pair in $quotePairs) {
                if ($value.Length -ge 2 -and $value.StartsWith($pair.Open) -and $value.EndsWith($pair.Close)) {
                    $value = $value.Substring($pair.Open.Length, $value.Length - $pair.Open.Length - $pair.Close.Length).Trim()
                    $removed = $true
                    break
                }
            }
            if (-not $removed) { break }
        }
    }

    return $value
}

function Get-VisibleSourceLength([string]$Text) {
    return ([regex]::Replace(([string]$Text), '\s+', '')).Length
}

function Test-ShouldTranslateSingle([object]$Target) {
    if ($ShortSegmentChars -le 0) { return $false }
    return (Get-VisibleSourceLength ([string]$Target.ja)) -le $ShortSegmentChars
}

function Invoke-HyMt2Api([string]$Prompt, [string]$Endpoint) {
    $messages = @()
    if ($script:SystemRole -and $script:SystemRole.Trim()) {
        $messages += [ordered]@{role = "system"; content = $script:SystemRole.Trim()}
    }
    $messages += [ordered]@{role = "user"; content = $Prompt}

    $requestBody = [ordered]@{
        model = $script:Model
        temperature = 0.1
        max_tokens = 2048
        messages = $messages
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

function Invoke-DelimiterBatch([object[]]$Targets, [string]$Endpoint) {
    if ($Targets.Count -lt 2) { throw "Delimiter batch requires at least two targets." }

    $sourceText = (($Targets | ForEach-Object {[string]$_.ja}) -join ("`n" + $script:Delimiter + "`n"))
    $guidance = Get-PromptGuidance

    $prompt = @"
Please accurately translate the following Japanese subtitle segments into Simplified Chinese.
You must retain the exact same number of delimiters in the translation. Strictly do not omit, escape, translate, alter, or move $($script:Delimiter).

$guidance

Strict requirements:
1. Terminology and source fidelity have higher priority than style or polishing instructions.
2. Each source segment must correspond to exactly one translated segment in the same order. Do not merge or split segments.
3. Translate each segment from its own Japanese text first. Do not import nouns, actions, topics, or meanings from neighboring segments unless they are explicitly supported by that segment.
4. Preserve intentional repetition, short replies, names, and explicit, sexual, vulgar, or colloquial wording. Do not sanitize, soften, or euphemize it.
5. If Japanese ASR text is garbled or uncertain, translate conservatively. Do not invent, repair, or add unsupported meaning.
6. Output only the translated segments and delimiters. Do not output explanations, labels, markdown, JSON, timestamps, or subtitle indices.

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
        $result[[int]$Targets[$i].id] = Clean-TranslationText ([string]$parts[$i]) ([string]$Targets[$i].ja)
    }
    return $result
}

function Invoke-SingleTarget([object]$Target, [string]$Endpoint) {
    $guidance = Get-PromptGuidance
    $prompt = @"
Translate the following Japanese subtitle into Simplified Chinese. Note that you should only output the translated result without any additional explanation.

$guidance

Strict requirements:
1. Terminology and source fidelity have higher priority than style or polishing instructions.
2. Translate only what is supported by this subtitle text. Do not infer nouns, actions, topics, or meanings from unrelated context.
3. Preserve intentional repetition, short replies, names, and explicit, sexual, vulgar, or colloquial wording. Do not sanitize, soften, or euphemize it.
4. If the Japanese ASR text is garbled or uncertain, translate conservatively. Do not invent, repair, or add unsupported meaning.
5. Do not output labels, markdown, JSON, timestamps, or subtitle indices.

$([string]$Target.ja)
"@

    $content = Invoke-HyMt2Api $prompt $Endpoint
    return Clean-TranslationText ([string]$content) ([string]$Target.ja)
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

    $testZh = ([string][char]0x6D4B) + ([string][char]0x8BD5)
    $testJa = ([string][char]0x30C6) + ([string][char]0x30B9) + ([string][char]0x30C8)
    $asciiQuote = [string][char]0x22
    $cleaned = Clean-TranslationText ($asciiQuote + $testZh + $asciiQuote) $testJa
    if ($cleaned -ne $testZh) { throw "Self-test quote cleanup failed." }

    $quotedTranslation = ([string][char]0x201C) + $testZh + ([string][char]0x201D)
    $quotedSource = ([string][char]0x300C) + $testJa + ([string][char]0x300D)
    $preserved = Clean-TranslationText $quotedTranslation $quotedSource
    if ($preserved -ne $quotedTranslation) {
        throw "Self-test source quote preservation failed."
    }

    if ($script:TerminologyLine -ne ($script:TermJaSeishi + " translates to " + $script:TermZhSperm)) {
        throw "Self-test terminology construction failed."
    }

    $originalStyle = $script:StylePrompt
    $script:Model = "self-test-model"
    $fingerprintA = Get-TranslationFingerprint $sample
    $script:StylePrompt = $originalStyle + " Different style."
    $fingerprintB = Get-TranslationFingerprint $sample
    $script:StylePrompt = $originalStyle
    if ($fingerprintA.Length -ne 64 -or $fingerprintA -eq $fingerprintB) {
        throw "Self-test translation fingerprint failed."
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
if ($ShortSegmentChars -lt 0 -or $ShortSegmentChars -gt 50) {
    throw "ShortSegmentChars must be between 0 and 50."
}
if ($ServerStartupTimeoutSec -lt 10 -or $ServerStartupTimeoutSec -gt 600) {
    throw "ServerStartupTimeoutSec must be between 10 and 600."
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
Load-PromptConfig $PromptConfigPath
$script:TranslationFingerprint = Get-TranslationFingerprint $sourceText
$endpoint = Normalize-Endpoint $BaseUrl
$script:ProgressPath = Get-ProgressPath $OutputPath $script:TranslationFingerprint
$script:Translations = Load-Progress $script:ProgressPath $script:TranslationFingerprint

foreach ($key in @($script:Translations.Keys)) {
    $id = [int]$key
    if ($id -lt 1 -or $id -gt $script:Entries.Count) {
        $script:Translations.Remove($key)
    }
    else {
        $script:Translations[$id] = Clean-TranslationText ([string]$script:Translations[$id]) ([string]$script:Entries[$id - 1].ja)
    }
}

Write-Host "Source: $InputPath"
Write-Host "Output: $OutputPath"
Write-Host "Model: $Model"
Write-Host "Entries: $($script:Entries.Count)"
Write-Host "Mode: Hy-MT2 delimiter-preserving translation with configurable role/style/terminology and automatic split fallback"
Write-Host ("Translation fingerprint: " + $script:TranslationFingerprint.Substring(0, 12))
if ($PromptConfigPath) { Write-Host "Prompt config: $PromptConfigPath" }
if ($ShortSegmentChars -gt 0) {
    Write-Host "Short subtitles: <= $ShortSegmentChars non-whitespace character(s) translated independently."
}
if ($script:Translations.Count -gt 0) {
    Write-Host "Resuming from checkpoint: $($script:Translations.Count) translated entry/entries."
}

try {
    if (Test-IsLoopbackUrl $BaseUrl) {
        if ($UseExistingServer) {
            if (-not (Test-HyMt2ServerReady $BaseUrl)) {
                throw "-UseExistingServer was specified, but no ready llama-server was found at $BaseUrl."
            }
            Write-Host "Using existing local llama-server; this script will not stop that external process."
        }
        else {
            Start-ManagedLocalServer $BaseUrl
        }
    }

    for ($start = 0; $start -lt $script:Entries.Count; $start += $BatchSize) {
        $end = [Math]::Min($script:Entries.Count - 1, $start + $BatchSize - 1)
        $pending = @($script:Entries[$start..$end] | Where-Object {-not $script:Translations.ContainsKey([int]$_.id)})
        if ($pending.Count -eq 0) { continue }

        $batchTargets = @($pending | Where-Object {-not (Test-ShouldTranslateSingle $_)})
        if ($batchTargets.Count -gt 0) {
            Invoke-ResilientGroup $batchTargets $endpoint
        }

        $singleTargets = @($pending | Where-Object {Test-ShouldTranslateSingle $_})
        foreach ($target in $singleTargets) {
            Invoke-ResilientGroup @($target) $endpoint
        }
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
}
finally {
    if (-not $UseExistingServer) {
        Stop-ManagedLocalServer
    }
}
