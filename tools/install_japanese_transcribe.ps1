[CmdletBinding()]
param(
    [string]$InstallRoot = "",
    [ValidateSet("auto", "cu118", "cu122", "cu128")]
    [string]$Variant = "auto",
    [switch]$KeepArchive
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Repo = "Marcus515J/Faster-Whisper-TransWithAI-ChickenRice"
$Version = "v1.10.1"
$WorkerBase = "https://gh-releases.ading2210.workers.dev/$Repo/releases/download/$Version"

$ExpectedSha256 = @{
    cu118 = "612f3eb04dbad3a6c891eeb5198b66a6af0953934794e50d9a2367d19bfdbc88"
    cu122 = "5552d4b731c60e5aa60267182bdb9ffce02db7debe290e445b048aa1ec4c8f5b"
    cu128 = "4b19595f7363730085aacbfe563f3467313e0c95fe83abe66eff9c6d1e1c9ee9"
}

if (-not $InstallRoot) {
    $translatedFolder = ([char]0x7FFB).ToString() + ([char]0x8BD1).ToString()
    $InstallRoot = Join-Path (Join-Path (Join-Path "H:\0H" $translatedFolder) "transwithai") "1.10.1-transcribe"
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Install-SrtLauncher {
    param([Parameter(Mandatory = $true)][string]$Root)

    $configPath = Join-Path $Root "generation_config.json5"
    if (Test-Path -LiteralPath $configPath) {
        $configText = [System.IO.File]::ReadAllText($configPath)
        $taskRegex = New-Object System.Text.RegularExpressions.Regex('"task"\s*:\s*"(?:translate|transcribe)"')
        $configText = $taskRegex.Replace($configText, '"task": "transcribe"', 1)
        Write-Utf8NoBom -Path $configPath -Text $configText
    }

    $launcherPath = Join-Path $Root "run_japanese_srt_gpu.bat"
    $launcher = @'
@echo off
chcp 65001 >nul
set "cpath=%~dp0"

if "%~1"=="" goto prompt_input
"%cpath%infer.exe" --audio_suffixes="mp3,wav,flac,m4a,aac,ogg,wma,mp4,mkv,avi,mov,webm,flv,wmv" --sub_formats="srt" --device="cuda" --task="transcribe" %*
goto end

:prompt_input
echo Drag audio/video files into this window, then press Enter:
set "input_files="
set /p "input_files="
if defined input_files goto run_input
goto no_input

:run_input
"%cpath%infer.exe" --audio_suffixes="mp3,wav,flac,m4a,aac,ogg,wma,mp4,mkv,avi,mov,webm,flv,wmv" --sub_formats="srt" --device="cuda" --task="transcribe" %input_files%
goto end

:no_input
echo No input file was provided.

:end
pause
'@
    Write-Utf8NoBom -Path $launcherPath -Text $launcher
}

function Test-InstalledPackage {
    param([Parameter(Mandatory = $true)][string]$Root)

    $infer = Join-Path $Root "infer.exe"
    $models = Join-Path $Root "models"
    if (-not (Test-Path -LiteralPath $infer -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $models -PathType Container)) { return $false }

    $mainWeights = @(
        Get-ChildItem -LiteralPath $models -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.(bin|safetensors)$' }
    )
    return ($mainWeights.Count -gt 0)
}

function Resolve-CudaVariant {
    if ($Variant -ne "auto") { return $Variant }

    $nvidiaSmi = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    }
    if (-not $nvidiaSmi) {
        throw "nvidia-smi was not found. Install/update the NVIDIA driver or pass -Variant cu118/cu122/cu128."
    }

    $smiText = (& $nvidiaSmi.Source 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $smiText -notmatch 'CUDA Version:\s*(\d+)\.(\d+)') {
        throw "Could not determine the CUDA version from nvidia-smi. Pass -Variant cu118/cu122/cu128."
    }

    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    $cuda = [version]("{0}.{1}" -f $major, $minor)

    if ($cuda -ge [version]"12.8") { return "cu128" }
    if ($cuda -ge [version]"12.2") { return "cu122" }
    return "cu118"
}

if (Test-InstalledPackage -Root $InstallRoot) {
    Install-SrtLauncher -Root $InstallRoot
    Write-Host "Japanese transcribe package is already installed: $InstallRoot"
    Write-Host "SRT-only launcher is ready: run_japanese_srt_gpu.bat"
    exit 0
}

if (Test-Path -LiteralPath $InstallRoot) {
    $existing = Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue
    if ($existing) {
        throw "Target directory is not empty and is not a complete transcribe install: $InstallRoot. Move/remove it before retrying."
    }
}

$selectedVariant = Resolve-CudaVariant
$archiveName = "faster_whisper_transwithai_windows_$selectedVariant-transcribe.zip"
$expectedHash = $ExpectedSha256[$selectedVariant]
$url = "$WorkerBase/$archiveName"

$parent = Split-Path -Parent $InstallRoot
if (-not $parent) { throw "Could not resolve the parent directory for: $InstallRoot" }
New-Item -ItemType Directory -Path $parent -Force | Out-Null

$downloadDir = Join-Path $parent "_downloads"
New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
$archivePath = Join-Path $downloadDir $archiveName
$extractPath = "$InstallRoot.extracting"

Write-Host "Selected package: $selectedVariant"
Write-Host "Install directory: $InstallRoot"

$needDownload = $true
if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
    Write-Host "Existing archive found; checking SHA-256..."
    $existingHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($existingHash -eq $expectedHash) {
        Write-Host "Existing archive passed SHA-256 verification."
        $needDownload = $false
    } else {
        Write-Host "Existing archive failed verification; downloading again."
        Remove-Item -LiteralPath $archivePath -Force
    }
}

if ($needDownload) {
    Write-Host "Downloading the v1.10.1 Japanese transcribe package..."
    $bits = Get-Command "Start-BitsTransfer" -ErrorAction SilentlyContinue
    if ($bits) {
        Start-BitsTransfer -Source $url -Destination $archivePath -DisplayName "ChickenRice Japanese Transcribe"
    } else {
        Invoke-WebRequest -Uri $url -OutFile $archivePath -UseBasicParsing
    }
}

Write-Host "Verifying SHA-256..."
$actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    throw "SHA-256 verification failed. The downloaded archive was deleted; run the installer again."
}
Write-Host "SHA-256 verification passed."

try {
    if (Test-Path -LiteralPath $extractPath) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

    Write-Host "Extracting..."
    $tar = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if (-not $tar) { $tar = Get-Command "tar" -ErrorAction SilentlyContinue }
    if ($tar) {
        & $tar.Source -xf $archivePath -C $extractPath
        if ($LASTEXITCODE -ne 0) { throw "tar extraction failed with exit code $LASTEXITCODE" }
    } else {
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
    }

    if (-not (Test-InstalledPackage -Root $extractPath)) {
        throw "Extracted package is incomplete: infer.exe or the main Japanese model weights are missing."
    }

    Install-SrtLauncher -Root $extractPath

    if (Test-Path -LiteralPath $InstallRoot) {
        Remove-Item -LiteralPath $InstallRoot -Recurse -Force
    }
    Move-Item -LiteralPath $extractPath -Destination $InstallRoot

    if (-not $KeepArchive) {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "Japanese transcribe package installed: $InstallRoot"
    Write-Host "Model: TransWithAI/whisper-ja-1.5B-ct2"
    Write-Host "Output format: SRT only"
    Write-Host "Launcher: run_japanese_srt_gpu.bat"
} catch {
    if (Test-Path -LiteralPath $extractPath) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
}
