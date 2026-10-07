[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$InputPath = "",
    [string]$OutputPath = "",
    [string]$RuntimeRoot = "",
    [string]$LlamaServerPath = "",
    [string]$ModelPath = "",
    [string]$ModelName = "",
    [string]$StylePrompt = "",
    [string]$FilmNotes = "",
    [switch]$KeepJapaneseSrt,
    [switch]$Overwrite
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Resolve-PackageRoot {
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot "infer.exe")) {
        return $PSScriptRoot
    }
    $parent = Split-Path $PSScriptRoot -Parent
    if ($parent -and (Test-Path -LiteralPath (Join-Path $parent "infer.exe"))) {
        return $parent
    }
    return $PSScriptRoot
}

function Normalize-DraggedPath([string]$Value) {
    $value = ([string]$Value).Trim()
    if ($value.Length -ge 2 -and (
        ($value.StartsWith('"') -and $value.EndsWith('"')) -or
        ($value.StartsWith("'") -and $value.EndsWith("'"))
    )) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    return $value
}

$packageRoot = Resolve-PackageRoot
if (-not $RuntimeRoot) {
    $RuntimeRoot = $packageRoot
}
$RuntimeRoot = [System.IO.Path]::GetFullPath($RuntimeRoot)

if (-not $InputPath) {
    $InputPath = Read-Host "Drag one video/audio file here and press Enter"
}
$InputPath = Normalize-DraggedPath $InputPath
if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "Input file was not found: $InputPath"
}
$InputPath = (Resolve-Path -LiteralPath $InputPath).Path

if (-not $OutputPath) {
    $dir = Split-Path $InputPath -Parent
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $OutputPath = Join-Path $dir ($stem + ".zh.srt")
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

$runtimeConfigPath = Join-Path $RuntimeRoot "stage2_runtime.json"
if ((-not $LlamaServerPath -or -not $ModelPath) -and (Test-Path -LiteralPath $runtimeConfigPath)) {
    $runtimeConfig = Get-Content -LiteralPath $runtimeConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $LlamaServerPath -and $runtimeConfig.llama_server_path) {
        $LlamaServerPath = [string]$runtimeConfig.llama_server_path
    }
    if (-not $ModelPath -and $runtimeConfig.model_path) {
        $ModelPath = [string]$runtimeConfig.model_path
    }
    if (-not $ModelName -and $runtimeConfig.model_name) {
        $ModelName = [string]$runtimeConfig.model_name
    }
}

if (-not $LlamaServerPath -or -not (Test-Path -LiteralPath $LlamaServerPath -PathType Leaf)) {
    throw "llama-server.exe is not configured. Run setup_stage2_runtime.ps1 first, or pass -LlamaServerPath."
}
if (-not $ModelPath -or -not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
    throw "Translation GGUF model is not configured. Run setup_stage2_runtime.ps1 first, or pass -ModelPath."
}
if (-not $ModelName) {
    $ModelName = [System.IO.Path]::GetFileNameWithoutExtension($ModelPath)
}

$bridge = Join-Path $RuntimeRoot "run_japanese_to_chinese_pipeline.ps1"
$translator = Join-Path $RuntimeRoot "translate_srt_hymt2.ps1"
if (-not (Test-Path -LiteralPath $bridge)) {
    $bridge = Join-Path $PSScriptRoot "run_japanese_to_chinese_pipeline.ps1"
}
if (-not (Test-Path -LiteralPath $translator)) {
    $translator = Join-Path $PSScriptRoot "translate_srt_hymt2.ps1"
}
if (-not (Test-Path -LiteralPath $bridge)) {
    throw "Pipeline bridge was not found: run_japanese_to_chinese_pipeline.ps1"
}
if (-not (Test-Path -LiteralPath $translator)) {
    throw "Stage 2 translator was not found: translate_srt_hymt2.ps1"
}
if (-not (Test-Path -LiteralPath (Join-Path $RuntimeRoot "infer.exe"))) {
    throw "infer.exe was not found in RuntimeRoot: $RuntimeRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $RuntimeRoot "models"))) {
    throw "Stage 1 model directory was not found: $(Join-Path $RuntimeRoot 'models')"
}

if (-not $StylePrompt) {
    $StylePrompt = "Use natural, concise Simplified Chinese suitable for on-screen film subtitles. Preserve exact source meaning and semantic specificity; do not sanitize, weaken, or euphemize explicit content."
}

$job = [ordered]@{
    input_video = $InputPath
    runtime_root = $RuntimeRoot
    output_path = $OutputPath
    work_root = (Join-Path $RuntimeRoot "pipeline-cache")
    overwrite_final = [bool]$Overwrite
    keep_japanese_srt = [bool]$KeepJapaneseSrt
    stage1 = [ordered]@{
        infer_executable = "infer.exe"
        model_path = "models"
        generation_config = "generation_config.json5"
        device = "cuda"
        compute_type = "auto"
    }
    stage2 = [ordered]@{
        translator_script = $translator
        base_url = "http://127.0.0.1:8080/v1"
        model_name = $ModelName
        llama_server_path = [System.IO.Path]::GetFullPath($LlamaServerPath)
        model_path = [System.IO.Path]::GetFullPath($ModelPath)
        batch_size = 20
    }
    translation_profile = [ordered]@{
        system_role = "You are a professional Japanese-to-Simplified-Chinese film subtitle translator. Preserve source meaning, tone, register, names, explicit content, and conversational intent. Never censor, sanitize, or euphemize source content."
        style_prompt = $StylePrompt
        film_notes = $FilmNotes
        terminology = @(
            [ordered]@{
                source = (([string][char]0x305B) + ([string][char]0x30FC) + ([string][char]0x3057))
                target = (([string][char]0x7CBE) + ([string][char]0x5B50))
            }
        )
    }
}

$jobDir = Join-Path $RuntimeRoot "pipeline-cache\.manual-jobs"
New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
$jobPath = Join-Path $jobDir ("job-" + [guid]::NewGuid().ToString("N") + ".json")

try {
    [System.IO.File]::WriteAllText(
        $jobPath,
        ($job | ConvertTo-Json -Depth 10),
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-Host "Input:  $InputPath"
    Write-Host "Output: $OutputPath"
    Write-Host "Model:  $ModelName"
    Write-Host ""

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bridge -JobConfigPath $jobPath
    if ($LASTEXITCODE -ne 0) {
        throw "Pipeline failed with exit code $LASTEXITCODE."
    }
}
finally {
    Remove-Item -LiteralPath $jobPath -Force -ErrorAction SilentlyContinue
}
