[CmdletBinding()]
param(
    [string]$InstallRoot = "H:\0H\翻译\transwithai\1.10.1-transcribe",
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

    $launcherPath = Join-Path $Root "运行(日文转录SRT)(GPU).bat"
    $launcher = @'
@echo off
chcp 65001 >nul
set "cpath=%~dp0"

if "%~1"=="" goto prompt_input
"%cpath%infer.exe" --audio_suffixes="mp3,wav,flac,m4a,aac,ogg,wma,mp4,mkv,avi,mov,webm,flv,wmv" --sub_formats="srt" --device="cuda" --task="transcribe" %*
goto end

:prompt_input
echo 请将音视频文件拖到此窗口，然后按回车:
set "input_files="
set /p "input_files="
if defined input_files goto run_input
goto no_input

:run_input
"%cpath%infer.exe" --audio_suffixes="mp3,wav,flac,m4a,aac,ogg,wma,mp4,mkv,avi,mov,webm,flv,wmv" --sub_formats="srt" --device="cuda" --task="transcribe" %input_files%
goto end

:no_input
echo 未提供输入文件。

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

    $mainWeights = Get-ChildItem -LiteralPath $models -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.(bin|safetensors)$' }
    return ($null -ne $mainWeights -and $mainWeights.Count -gt 0)
}

function Resolve-CudaVariant {
    if ($Variant -ne "auto") { return $Variant }

    $nvidiaSmi = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    }
    if (-not $nvidiaSmi) {
        throw "未找到 nvidia-smi。请安装 NVIDIA 驱动，或用 -Variant cu118/cu122/cu128 手动指定版本。"
    }

    $smiText = (& $nvidiaSmi.Source 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $smiText -notmatch 'CUDA Version:\s*(\d+)\.(\d+)') {
        throw "无法从 nvidia-smi 判断 CUDA 版本。可用 -Variant cu118/cu122/cu128 手动指定。"
    }

    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    $cuda = [version]::new($major, $minor)

    if ($cuda -ge [version]"12.8") { return "cu128" }
    if ($cuda -ge [version]"12.2") { return "cu122" }
    return "cu118"
}

if (Test-InstalledPackage -Root $InstallRoot) {
    Install-SrtLauncher -Root $InstallRoot
    Write-Host "✅ 日文转录版已经安装：$InstallRoot"
    Write-Host "✅ 已确认启动器只输出 SRT：运行(日文转录SRT)(GPU).bat"
    exit 0
}

if (Test-Path -LiteralPath $InstallRoot) {
    $existing = Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue
    if ($existing) {
        throw "目标目录已有内容但不是完整的日文转录版：$InstallRoot`n请先移走该目录后再运行，脚本不会自动覆盖。"
    }
}

$selectedVariant = Resolve-CudaVariant
$archiveName = "faster_whisper_transwithai_windows_$selectedVariant-transcribe.zip"
$expectedHash = $ExpectedSha256[$selectedVariant]
$url = "$WorkerBase/$archiveName"

$parent = Split-Path -Parent $InstallRoot
if (-not $parent) { throw "无法确定安装目录的父路径：$InstallRoot" }
New-Item -ItemType Directory -Path $parent -Force | Out-Null

$downloadDir = Join-Path $parent "_downloads"
New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
$archivePath = Join-Path $downloadDir $archiveName
$extractPath = "$InstallRoot.extracting"

Write-Host "检测到版本：$selectedVariant"
Write-Host "安装目录：$InstallRoot"

$needDownload = $true
if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
    Write-Host "发现已有下载文件，正在校验..."
    $existingHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($existingHash -eq $expectedHash) {
        Write-Host "✅ 已有下载文件校验通过，直接使用。"
        $needDownload = $false
    } else {
        Write-Host "已有下载文件校验失败，重新下载。"
        Remove-Item -LiteralPath $archivePath -Force
    }
}

if ($needDownload) {
    Write-Host "正在下载官方 v1.10.1 日文转录完整包..."
    $bits = Get-Command "Start-BitsTransfer" -ErrorAction SilentlyContinue
    if ($bits) {
        Start-BitsTransfer -Source $url -Destination $archivePath -DisplayName "ChickenRice Japanese Transcribe"
    } else {
        Invoke-WebRequest -Uri $url -OutFile $archivePath -UseBasicParsing
    }
}

Write-Host "正在校验 SHA-256..."
$actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    throw "下载文件 SHA-256 校验失败。文件已删除，请重新运行。"
}
Write-Host "✅ SHA-256 校验通过。"

try {
    if (Test-Path -LiteralPath $extractPath) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

    Write-Host "正在解压..."
    $tar = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if (-not $tar) { $tar = Get-Command "tar" -ErrorAction SilentlyContinue }
    if ($tar) {
        & $tar.Source -xf $archivePath -C $extractPath
        if ($LASTEXITCODE -ne 0) { throw "tar 解压失败，退出代码：$LASTEXITCODE" }
    } else {
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
    }

    if (-not (Test-InstalledPackage -Root $extractPath)) {
        throw "解压后的程序结构不完整：未找到 infer.exe 或主日文模型权重。"
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
    Write-Host "✅ 日文转录版安装完成：$InstallRoot"
    Write-Host "✅ 使用专用日文模型：TransWithAI/whisper-ja-1.5B-ct2"
    Write-Host "✅ 只输出 SRT，不生成 VTT/LRC"
    Write-Host "✅ 启动文件：运行(日文转录SRT)(GPU).bat"
} catch {
    if (Test-Path -LiteralPath $extractPath) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
}
