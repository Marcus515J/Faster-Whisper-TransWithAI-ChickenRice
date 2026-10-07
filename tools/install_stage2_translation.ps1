param(
    [string]$InstallRoot = "",
    [string]$RepoRef = "main"
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $InstallRoot) {
    $candidate = Split-Path $PSScriptRoot -Parent
    if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate "infer.exe"))) {
        $InstallRoot = $candidate
    }
    elseif (Test-Path -LiteralPath (Join-Path $PSScriptRoot "infer.exe")) {
        $InstallRoot = $PSScriptRoot
    }
    else {
        throw "InstallRoot was not supplied and no ChickenRice install was detected beside this script. Pass -InstallRoot explicitly."
    }
}

$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
    throw "ChickenRice install directory was not found: $InstallRoot"
}

$RepoRaw = "https://raw.githubusercontent.com/Marcus515J/Faster-Whisper-TransWithAI-ChickenRice/$RepoRef/tools"
$TempDir = Join-Path $env:TEMP ("chickenrice-stage2-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

$items = @(
    @{
        Name = "translate_srt_api.ps1"
        Url = "$RepoRaw/translate_srt_api.ps1"
        Destination = Join-Path $InstallRoot "translate_srt_api.ps1"
    },
    @{
        Name = "translate_srt_to_chinese.bat"
        Url = "$RepoRaw/translate_srt_to_chinese.bat"
        Destination = Join-Path $InstallRoot "translate_srt_to_chinese.bat"
    },
    @{
        Name = "translation_api_config.example.json"
        Url = "$RepoRaw/translation_api_config.example.json"
        Destination = Join-Path $InstallRoot "translation_api_config.example.json"
    },
    @{
        Name = "translate_srt_hymt2.ps1"
        Url = "$RepoRaw/translate_srt_hymt2.ps1"
        Destination = Join-Path $InstallRoot "translate_srt_hymt2.ps1"
    },
    @{
        Name = "run_japanese_to_chinese_pipeline.ps1"
        Url = "$RepoRaw/run_japanese_to_chinese_pipeline.ps1"
        Destination = Join-Path $InstallRoot "run_japanese_to_chinese_pipeline.ps1"
    },
    @{
        Name = "hymt2_prompt_config.example.json"
        Url = "$RepoRaw/hymt2_prompt_config.example.json"
        Destination = Join-Path $InstallRoot "hymt2_prompt_config.example.json"
    },
    @{
        Name = "pipeline_job.example.json"
        Url = "$RepoRaw/pipeline_job.example.json"
        Destination = Join-Path $InstallRoot "pipeline_job.example.json"
    },
    @{
        Name = "run_full_pipeline_local.ps1"
        Url = "$RepoRaw/run_full_pipeline_local.ps1"
        Destination = Join-Path $InstallRoot "run_full_pipeline_local.ps1"
    },
    @{
        Name = "setup_stage2_runtime.ps1"
        Url = "$RepoRaw/setup_stage2_runtime.ps1"
        Destination = Join-Path $InstallRoot "setup_stage2_runtime.ps1"
    },
    @{
        Name = "stage2_runtime_manifest.json"
        Url = "$RepoRaw/stage2_runtime_manifest.json"
        Destination = Join-Path $InstallRoot "stage2_runtime_manifest.json"
    }
)

try {
    foreach ($item in $items) {
        $temp = Join-Path $TempDir $item.Name
        Invoke-WebRequest -Uri $item.Url -OutFile $temp -UseBasicParsing
        if (-not (Test-Path $temp) -or (Get-Item $temp).Length -lt 10) {
            throw "Downloaded file is invalid: $($item.Name)"
        }
        Copy-Item $temp $item.Destination -Force
    }

    $activeConfig = Join-Path $InstallRoot "translation_api_config.json"
    if (-not (Test-Path $activeConfig)) {
        Copy-Item (Join-Path $TempDir "translation_api_config.example.json") $activeConfig
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot "translate_srt_api.ps1") -SelfTest
    if ($LASTEXITCODE -ne 0) {
        throw "Generic Stage 2 self-test failed."
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot "translate_srt_hymt2.ps1") -SelfTest
    if ($LASTEXITCODE -ne 0) {
        throw "Hy-MT2 Stage 2 self-test failed."
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot "run_japanese_to_chinese_pipeline.ps1") -SelfTest
    if ($LASTEXITCODE -ne 0) {
        throw "Pipeline bridge self-test failed."
    }

    Write-Host ""
    Write-Host "Stage 2 and pipeline bridge tools installed." -ForegroundColor Green
    Write-Host "Generic launcher: $(Join-Path $InstallRoot 'translate_srt_to_chinese.bat')"
    Write-Host "Hy-MT2 script:    $(Join-Path $InstallRoot 'translate_srt_hymt2.ps1')"
    Write-Host "Pipeline bridge:  $(Join-Path $InstallRoot 'run_japanese_to_chinese_pipeline.ps1')"
    Write-Host "Local launcher:   $(Join-Path $InstallRoot 'run_full_pipeline_local.ps1')"
    Write-Host "Runtime setup:    $(Join-Path $InstallRoot 'setup_stage2_runtime.ps1')"
    Write-Host "Config:           $activeConfig"
}
finally {
    Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
