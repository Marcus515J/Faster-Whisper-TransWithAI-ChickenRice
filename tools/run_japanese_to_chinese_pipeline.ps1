param(
    [string]$JobConfigPath = "",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Read-Utf8Text([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
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

function Test-HasProperty([object]$Object, [string]$Name) {
    return ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name)
}

function Resolve-PathValue([string]$Value, [string]$BasePath) {
    if (-not $Value) { return "" }
    if ([System.IO.Path]::IsPathRooted($Value)) {
        return [System.IO.Path]::GetFullPath($Value)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Value))
}

function Ensure-Directory([string]$Path) {
    if (-not $Path) {
        throw "Directory path is empty."
    }

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path
        if (-not $item.PSIsContainer) {
            throw "Expected a directory but found a file: $Path"
        }
        return
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Emit-BridgeEvent(
    [string]$Stage,
    [string]$State,
    [string]$Message = "",
    [string]$Path = ""
) {
    $payload = [ordered]@{
        stage = $Stage
        state = $State
    }
    if ($Message) { $payload.message = $Message }
    if ($Path) { $payload.path = $Path }
    Write-Output ("@@CR_EVENT@@" + ($payload | ConvertTo-Json -Compress))
}

function Get-Stage1Fingerprint(
    [System.IO.FileInfo]$InputInfo,
    [string]$ModelPath,
    [string]$GenerationConfigPath,
    [string]$Device,
    [string]$ComputeType
) {
    $modelStamp = ""
    if (Test-Path -LiteralPath $ModelPath) {
        $modelItem = Get-Item -LiteralPath $ModelPath
        $modelStamp = "$($modelItem.FullName)|$($modelItem.LastWriteTimeUtc.Ticks)"
    }

    $configHash = ""
    if (Test-Path -LiteralPath $GenerationConfigPath) {
        $configHash = Get-Sha256Hex (Read-Utf8Text $GenerationConfigPath)
    }

    $payload = [ordered]@{
        input_path = $InputInfo.FullName
        input_length = $InputInfo.Length
        input_mtime_utc = $InputInfo.LastWriteTimeUtc.Ticks
        model = $modelStamp
        generation_config_sha256 = $configHash
        device = $Device
        compute_type = $ComputeType
    }
    return Get-Sha256Hex ($payload | ConvertTo-Json -Compress)
}

function Invoke-SelfTest {
    $a = Get-Sha256Hex "alpha"
    $b = Get-Sha256Hex "beta"
    if ($a.Length -ne 64 -or $a -eq $b) {
        throw "Bridge self-test hash check failed."
    }

    $relative = Resolve-PathValue "child.txt" "C:\bridge-test"
    if (-not $relative.ToLowerInvariant().EndsWith("\bridge-test\child.txt")) {
        throw "Bridge self-test path resolution failed."
    }

    Ensure-Directory $env:TEMP

    $selfJob = [pscustomobject]@{stop_after_stage1 = $true}
    if (-not [bool]$selfJob.stop_after_stage1) {
        throw "Bridge self-test stop_after_stage1 check failed."
    }

    Write-Host "ChickenRice pipeline bridge self-test passed." -ForegroundColor Green
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
    throw "Pipeline job config is invalid JSON: $JobConfigPath"
}

if (-not (Test-HasProperty $job "input_video") -or -not [string]$job.input_video) {
    throw "Job config must contain input_video."
}
if (-not (Test-HasProperty $job "runtime_root") -or -not [string]$job.runtime_root) {
    throw "Job config must contain runtime_root."
}

$inputVideo = (Resolve-Path -LiteralPath ([string]$job.input_video)).Path
$inputInfo = Get-Item -LiteralPath $inputVideo
if ($inputInfo.PSIsContainer) {
    throw "input_video must be a file."
}

$runtimeRoot = (Resolve-Path -LiteralPath ([string]$job.runtime_root)).Path
$outputDir = Split-Path $inputVideo -Parent
if ((Test-HasProperty $job "output_path") -and [string]$job.output_path) {
    $finalOutput = [System.IO.Path]::GetFullPath([string]$job.output_path)
    $outputDir = Split-Path $finalOutput -Parent
}
else {
    $finalOutput = Join-Path $outputDir ([System.IO.Path]::GetFileNameWithoutExtension($inputVideo) + ".zh.srt")
}
Ensure-Directory $outputDir

$overwriteFinal = $false
if (Test-HasProperty $job "overwrite_final") {
    $overwriteFinal = [bool]$job.overwrite_final
}
if ((Test-Path -LiteralPath $finalOutput) -and -not $overwriteFinal) {
    throw "Final output already exists. Set overwrite_final=true or choose another output_path: $finalOutput"
}

$workRoot = Join-Path $outputDir ".chickenrice-work"
if ((Test-HasProperty $job "work_root") -and [string]$job.work_root) {
    $workRoot = [System.IO.Path]::GetFullPath([string]$job.work_root)
}
Ensure-Directory $workRoot

$stage1 = $job.stage1
$inferName = "infer.exe"
$modelValue = "models"
$generationValue = "generation_config.json5"
$device = "cuda"
$computeType = "auto"
if ($null -ne $stage1) {
    if ((Test-HasProperty $stage1 "infer_executable") -and [string]$stage1.infer_executable) { $inferName = [string]$stage1.infer_executable }
    if ((Test-HasProperty $stage1 "model_path") -and [string]$stage1.model_path) { $modelValue = [string]$stage1.model_path }
    if ((Test-HasProperty $stage1 "generation_config") -and [string]$stage1.generation_config) { $generationValue = [string]$stage1.generation_config }
    if ((Test-HasProperty $stage1 "device") -and [string]$stage1.device) { $device = [string]$stage1.device }
    if ((Test-HasProperty $stage1 "compute_type") -and [string]$stage1.compute_type) { $computeType = [string]$stage1.compute_type }
}

$inferExe = Resolve-PathValue $inferName $runtimeRoot
$modelPath = Resolve-PathValue $modelValue $runtimeRoot
$generationConfig = Resolve-PathValue $generationValue $runtimeRoot
if (-not (Test-Path -LiteralPath $inferExe)) { throw "Stage 1 infer executable was not found: $inferExe" }
if (-not (Test-Path -LiteralPath $modelPath)) { throw "Stage 1 model path was not found: $modelPath" }
if (-not (Test-Path -LiteralPath $generationConfig)) { throw "Stage 1 generation config was not found: $generationConfig" }

$stage1Fingerprint = Get-Stage1Fingerprint $inputInfo $modelPath $generationConfig $device $computeType
$stem = [System.IO.Path]::GetFileNameWithoutExtension($inputVideo)
$workDir = Join-Path $workRoot ($stem + "-" + $stage1Fingerprint.Substring(0, 12))
Ensure-Directory $workDir
$japaneseSrt = Join-Path $workDir ($stem + ".srt")

if (Test-Path -LiteralPath $japaneseSrt) {
    Emit-BridgeEvent "asr" "reused" "Reusing cached Japanese SRT." $japaneseSrt
}
else {
    Emit-BridgeEvent "asr" "start" "Starting Japanese transcription." ""
    $inputSuffix = [System.IO.Path]::GetExtension($inputVideo).TrimStart(".").ToLowerInvariant()
    $inferArgs = @(
        "--model_name_or_path=$modelPath",
        "--device=$device",
        "--compute_type=$computeType",
        "--sub_formats=srt",
        "--output_dir=$workDir",
        "--task=transcribe",
        "--audio_suffixes=$inputSuffix",
        "--generation_config=$generationConfig",
        $inputVideo
    )

    Push-Location $runtimeRoot
    try {
        & $inferExe @inferArgs
        $stage1Exit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($stage1Exit -ne 0) {
        Emit-BridgeEvent "asr" "failed" "Stage 1 exited with code $stage1Exit." ""
        throw "Stage 1 transcription failed with exit code $stage1Exit."
    }
    if (-not (Test-Path -LiteralPath $japaneseSrt)) {
        throw "Stage 1 completed but Japanese SRT was not created: $japaneseSrt"
    }
    Emit-BridgeEvent "asr" "done" "Japanese SRT created." $japaneseSrt
}

$stopAfterStage1 = $false
if (Test-HasProperty $job "stop_after_stage1") {
    $stopAfterStage1 = [bool]$job.stop_after_stage1
}
if ($stopAfterStage1) {
    Emit-BridgeEvent "pipeline" "stage1_ready" "Stage 1 Japanese SRT is ready." $japaneseSrt
    Write-Host "Stage 1 ready: $japaneseSrt" -ForegroundColor Green
    exit 0
}

$stage2 = $job.stage2
$translatorScript = Join-Path $PSScriptRoot "translate_srt_hymt2.ps1"
$baseUrl = "http://127.0.0.1:8080/v1"
$modelName = "HY-MT2-7B-Q8_0"
$llamaServerPath = ""
$localModelPath = ""
$batchSize = 20

if ($null -ne $stage2) {
    if ((Test-HasProperty $stage2 "translator_script") -and [string]$stage2.translator_script) {
        $translatorScript = Resolve-PathValue ([string]$stage2.translator_script) $PSScriptRoot
    }
    if ((Test-HasProperty $stage2 "base_url") -and [string]$stage2.base_url) { $baseUrl = [string]$stage2.base_url }
    if ((Test-HasProperty $stage2 "model_name") -and [string]$stage2.model_name) { $modelName = [string]$stage2.model_name }
    if ((Test-HasProperty $stage2 "llama_server_path") -and [string]$stage2.llama_server_path) { $llamaServerPath = [string]$stage2.llama_server_path }
    if ((Test-HasProperty $stage2 "model_path") -and [string]$stage2.model_path) { $localModelPath = [string]$stage2.model_path }
    if (Test-HasProperty $stage2 "batch_size") { $batchSize = [int]$stage2.batch_size }
}
if (-not (Test-Path -LiteralPath $translatorScript)) { throw "Stage 2 translator script was not found: $translatorScript" }
if (-not $llamaServerPath) { throw "stage2.llama_server_path is required." }
if (-not $localModelPath) { throw "stage2.model_path is required." }

$promptConfigPath = ""
if ((Test-HasProperty $job "translation_profile") -and $null -ne $job.translation_profile) {
    $profileJson = $job.translation_profile | ConvertTo-Json -Depth 10
    $profileHash = Get-Sha256Hex $profileJson
    $promptConfigPath = Join-Path $workDir ("prompt-" + $profileHash.Substring(0, 12) + ".json")
    if (-not (Test-Path -LiteralPath $promptConfigPath)) {
        Write-Utf8NoBom $promptConfigPath $profileJson
    }
}

Emit-BridgeEvent "translation" "start" "Starting Hy-MT2 translation." ""
$stage2Args = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $translatorScript,
    "-InputPath", $japaneseSrt,
    "-OutputPath", $finalOutput,
    "-BaseUrl", $baseUrl,
    "-Model", $modelName,
    "-BatchSize", [string]$batchSize,
    "-LlamaServerPath", $llamaServerPath,
    "-LocalModelPath", $localModelPath
)
if ($promptConfigPath) {
    $stage2Args += @("-PromptConfigPath", $promptConfigPath)
}

& powershell.exe @stage2Args
$stage2Exit = $LASTEXITCODE
if ($stage2Exit -ne 0) {
    Emit-BridgeEvent "translation" "failed" "Stage 2 exited with code $stage2Exit." ""
    throw "Stage 2 translation failed with exit code $stage2Exit."
}
if (-not (Test-Path -LiteralPath $finalOutput)) {
    throw "Stage 2 completed but final Chinese SRT was not created: $finalOutput"
}
Emit-BridgeEvent "translation" "done" "Chinese SRT created." $finalOutput

$keepJapanese = $false
if (Test-HasProperty $job "keep_japanese_srt") {
    $keepJapanese = [bool]$job.keep_japanese_srt
}
if ($keepJapanese) {
    $visibleJa = Join-Path $outputDir ($stem + ".ja.srt")
    Copy-Item -LiteralPath $japaneseSrt -Destination $visibleJa -Force
    Emit-BridgeEvent "output" "japanese_saved" "Japanese SRT copied to output directory." $visibleJa
}

Emit-BridgeEvent "pipeline" "done" "Pipeline completed." $finalOutput
Write-Host "Pipeline completed: $finalOutput" -ForegroundColor Green
