param(
    [string]$JobConfigPath = "",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Read-Utf8Text([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Resolve-PathValue([string]$Value, [string]$BasePath) {
    if (-not $Value) { return "" }
    if ([System.IO.Path]::IsPathRooted($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Value))
}

function Ensure-Directory([string]$Path) {
    if (-not $Path) { throw "Directory path is empty." }
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path
        if (-not $item.PSIsContainer) {
            throw "Expected a directory but found a file: $Path"
        }
        return
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Emit-Event([string]$State, [hashtable]$Fields) {
    $payload = [ordered]@{
        stage = "asr_audio_review"
        state = $State
    }
    if ($null -ne $Fields) {
        foreach ($key in $Fields.Keys) {
            $payload[[string]$key] = $Fields[$key]
        }
    }
    Write-Output ("@@CR_EVENT@@" + ($payload | ConvertTo-Json -Compress -Depth 8))
}

function Convert-SrtTimeToMs([string]$Text) {
    $match = [regex]::Match(
        $Text.Trim(),
        '^(\d{2}):(\d{2}):(\d{2}),(\d{3})$'
    )
    if (-not $match.Success) {
        throw "Invalid SRT timestamp: $Text"
    }
    $hours = [int]$match.Groups[1].Value
    $minutes = [int]$match.Groups[2].Value
    $seconds = [int]$match.Groups[3].Value
    $milliseconds = [int]$match.Groups[4].Value
    return (($hours * 3600 + $minutes * 60 + $seconds) * 1000 + $milliseconds)
}

function Parse-Srt([string]$Path) {
    $text = Read-Utf8Text $Path
    $blocks = [regex]::Split($text.Trim(), '(?:\r?\n){2,}')
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($block in $blocks) {
        $lines = $block -split '\r?\n'
        if ($lines.Count -lt 3) { continue }

        $timestampLine = $lines[1].Trim()
        $parts = $timestampLine -split '\s+-->\s+'
        if ($parts.Count -ne 2) { continue }

        try {
            $startMs = Convert-SrtTimeToMs $parts[0]
            $endMs = Convert-SrtTimeToMs $parts[1]
        }
        catch {
            continue
        }

        $body = (($lines[2..($lines.Count - 1)]) -join " ").Trim()
        if (-not $body) { continue }

        $entries.Add([pscustomobject]@{
            start_ms = $startMs
            end_ms = $endMs
            text = $body
        }) | Out-Null
    }
    # Windows PowerShell 5.1 can throw "Argument types do not match"
    # when array-subexpressing a Generic.List[object]. Convert explicitly.
    return $entries.ToArray()
}

function Select-TargetTranscript(
    [object[]]$Entries,
    [int64]$TargetStartMs,
    [int64]$TargetEndMs
) {
    if (@($Entries).Count -eq 0) { return "" }

    $margin = 900
    $selected = @(
        $Entries | Where-Object {
            ([int64]$_.end_ms -ge ($TargetStartMs - $margin)) -and
            ([int64]$_.start_ms -le ($TargetEndMs + $margin))
        }
    )

    if ($selected.Count -eq 0) {
        $targetMid = ($TargetStartMs + $TargetEndMs) / 2.0
        $nearest = $Entries |
            Sort-Object {
                $entryMid = ([int64]$_.start_ms + [int64]$_.end_ms) / 2.0
                [Math]::Abs($entryMid - $targetMid)
            } |
            Select-Object -First 1
        if ($null -ne $nearest) {
            $selected = @($nearest)
        }
    }

    return ((@($selected) | ForEach-Object { [string]$_.text }) -join " ").Trim()
}

function Find-Ffmpeg([string]$Requested, [string]$RuntimeRoot) {
    if ($Requested) {
        $resolved = Resolve-PathValue $Requested $RuntimeRoot
        if (Test-Path -LiteralPath $resolved) { return $resolved }
        throw "ffmpeg executable was not found: $resolved"
    }

    $runtimeCandidate = Join-Path $RuntimeRoot "ffmpeg.exe"
    if (Test-Path -LiteralPath $runtimeCandidate) {
        return $runtimeCandidate
    }

    $command = Get-Command "ffmpeg.exe" -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return [string]$command.Source
    }

    $command = Get-Command "ffmpeg" -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return [string]$command.Source
    }

    throw "ffmpeg was not found. Install FFmpeg or provide ffmpeg_executable in the job config."
}

function Format-Seconds([int64]$Milliseconds) {
    $seconds = [double]$Milliseconds / 1000.0
    return $seconds.ToString("0.000", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-SelfTest {
    if ((Convert-SrtTimeToMs "00:01:02,345") -ne 62345) {
        throw "Timestamp conversion self-test failed."
    }

    $temp = Join-Path $env:TEMP (
        "asr-segment-review-selftest-" +
        [Guid]::NewGuid().ToString("N") +
        ".srt"
    )
    try {
        [System.IO.File]::WriteAllText(
            $temp,
            "1" + [Environment]::NewLine +
            "00:00:01,000 --> 00:00:02,000" + [Environment]::NewLine +
            "A" + [Environment]::NewLine + [Environment]::NewLine +
            "2" + [Environment]::NewLine +
            "00:00:02,500 --> 00:00:03,500" + [Environment]::NewLine +
            "B" + [Environment]::NewLine,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $sample = @(Parse-Srt $temp)
        if ($sample.Count -ne 2) {
            throw "SRT parser self-test failed."
        }
        $picked = Select-TargetTranscript $sample 2400 2700
        if ($picked -notmatch "B") {
            throw "Target transcript selection self-test failed."
        }
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }

    Write-Host "ASR segment review bridge self-test passed." -ForegroundColor Green
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

if (-not $JobConfigPath) {
    throw "JobConfigPath is required."
}
$JobConfigPath = (Resolve-Path -LiteralPath $JobConfigPath).Path

try {
    $job = (Read-Utf8Text $JobConfigPath) | ConvertFrom-Json
}
catch {
    throw "ASR segment review job config is invalid JSON: $JobConfigPath"
}

if (-not [string]$job.input_video) { throw "input_video is required." }
if (-not [string]$job.runtime_root) { throw "runtime_root is required." }

$inputVideo = (Resolve-Path -LiteralPath ([string]$job.input_video)).Path
$runtimeRoot = (Resolve-Path -LiteralPath ([string]$job.runtime_root)).Path
$workRoot = Join-Path $runtimeRoot "pipeline-cache"
if ([string]$job.work_root) {
    $workRoot = [System.IO.Path]::GetFullPath([string]$job.work_root)
}
Ensure-Directory $workRoot

$candidates = @($job.candidates)
if ($candidates.Count -eq 0) {
    Emit-Event "done" @{total = 0}
    exit 0
}

$paddingBeforeMs = 3500
$paddingAfterMs = 3500
if ($null -ne $job.padding_before_ms) {
    $paddingBeforeMs = [Math]::Max(0, [int]$job.padding_before_ms)
}
if ($null -ne $job.padding_after_ms) {
    $paddingAfterMs = [Math]::Max(0, [int]$job.padding_after_ms)
}

$keepWorkFiles = $false
if ($null -ne $job.keep_work_files) {
    $keepWorkFiles = [bool]$job.keep_work_files
}

$inferName = "infer.exe"
$modelValue = "models"
$generationValue = "generation_config.json5"
$device = "cuda"
$computeType = "auto"
if ($null -ne $job.stage1) {
    if ([string]$job.stage1.infer_executable) { $inferName = [string]$job.stage1.infer_executable }
    if ([string]$job.stage1.model_path) { $modelValue = [string]$job.stage1.model_path }
    if ([string]$job.stage1.generation_config) { $generationValue = [string]$job.stage1.generation_config }
    if ([string]$job.stage1.device) { $device = [string]$job.stage1.device }
    if ([string]$job.stage1.compute_type) { $computeType = [string]$job.stage1.compute_type }
}

$inferExe = Resolve-PathValue $inferName $runtimeRoot
$modelPath = Resolve-PathValue $modelValue $runtimeRoot
$generationConfig = Resolve-PathValue $generationValue $runtimeRoot
if (-not (Test-Path -LiteralPath $inferExe)) { throw "infer executable was not found: $inferExe" }
if (-not (Test-Path -LiteralPath $modelPath)) { throw "Stage 1 model was not found: $modelPath" }
if (-not (Test-Path -LiteralPath $generationConfig)) { throw "generation_config was not found: $generationConfig" }

$ffmpegRequested = ""
if ([string]$job.ffmpeg_executable) {
    $ffmpegRequested = [string]$job.ffmpeg_executable
}
$ffmpegExe = Find-Ffmpeg $ffmpegRequested $runtimeRoot

$jobToken = [Guid]::NewGuid().ToString("N")
$jobDir = Join-Path $workRoot (".subtitlesynctool-asr-audio-review\" + $jobToken)
Ensure-Directory $jobDir

$clipRecords = New-Object System.Collections.Generic.List[object]
$success = $false

try {
    Emit-Event "start" @{
        total = $candidates.Count
        padding_before_ms = $paddingBeforeMs
        padding_after_ms = $paddingAfterMs
    }

    $position = 0
    foreach ($candidate in $candidates) {
        $position++
        $id = [int]$candidate.id
        $startMs = [int64]$candidate.start_ms
        $endMs = [int64]$candidate.end_ms
        if ($endMs -le $startMs) {
            throw "Candidate #$id has invalid time range."
        }

        $clipStartMs = [Math]::Max([int64]0, $startMs - $paddingBeforeMs)
        $clipEndMs = $endMs + $paddingAfterMs
        $clipDurationMs = $clipEndMs - $clipStartMs
        $clipName = ("candidate-{0:D6}.wav" -f $id)
        $clipPath = Join-Path $jobDir $clipName

        $ffmpegArgs = @(
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-ss", (Format-Seconds $clipStartMs),
            "-t", (Format-Seconds $clipDurationMs),
            "-i", $inputVideo,
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            $clipPath
        )

        & $ffmpegExe @ffmpegArgs
        $ffmpegExit = $LASTEXITCODE
        if ($ffmpegExit -ne 0 -or -not (Test-Path -LiteralPath $clipPath)) {
            throw "ffmpeg failed while extracting candidate #$id (exit $ffmpegExit)."
        }

        $clipRecords.Add([pscustomobject]@{
            id = $id
            original = [string]$candidate.original
            clip_path = $clipPath
            clip_start_ms = $clipStartMs
            target_start_ms = ($startMs - $clipStartMs)
            target_end_ms = ($endMs - $clipStartMs)
        }) | Out-Null

        Emit-Event "extract_progress" @{
            completed = $position
            total = $candidates.Count
            id = $id
        }
    }

    $clipPaths = @($clipRecords | ForEach-Object { [string]$_.clip_path })
    $inferArgs = @(
        "--model_name_or_path=$modelPath",
        "--device=$device",
        "--compute_type=$computeType",
        "--sub_formats=srt",
        "--output_dir=$jobDir",
        "--task=transcribe",
        "--audio_suffixes=wav",
        "--generation_config=$generationConfig"
    ) + $clipPaths

    Emit-Event "transcribe_start" @{total = $clipRecords.Count}
    Push-Location $runtimeRoot
    try {
        & $inferExe @inferArgs
        $inferExit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($inferExit -ne 0) {
        throw "Segment re-transcription failed with exit code $inferExit."
    }

    $completed = 0
    foreach ($record in $clipRecords) {
        $completed++
        $srtPath = [System.IO.Path]::ChangeExtension([string]$record.clip_path, ".srt")
        if (-not (Test-Path -LiteralPath $srtPath)) {
            Emit-Event "result" @{
                id = [int]$record.id
                original = [string]$record.original
                reanalyzed = ""
                error = "No SRT was produced for the extracted clip."
            }
            continue
        }

        $entries = Parse-Srt $srtPath
        $reanalyzed = Select-TargetTranscript $entries ([int64]$record.target_start_ms) ([int64]$record.target_end_ms)

        Emit-Event "result" @{
            id = [int]$record.id
            original = [string]$record.original
            reanalyzed = $reanalyzed
            completed = $completed
            total = $clipRecords.Count
        }
    }

    Emit-Event "done" @{total = $clipRecords.Count}
    $success = $true
}
catch {
    Emit-Event "failed" @{
        message = $_.Exception.Message
        work_dir = $jobDir
    }
    throw
}
finally {
    if ($success -and -not $keepWorkFiles) {
        Remove-Item -LiteralPath $jobDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
