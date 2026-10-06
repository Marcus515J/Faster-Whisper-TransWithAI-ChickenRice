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
$ReleaseBase = "https://github.com/$Repo/releases/download/$Version"

$ExpectedSha256 = @{
    cu118 = "612f3eb04dbad3a6c891eeb5198b66a6af0953934794e50d9a2367d19bfdbc88"
    cu122 = "5552d4b731c60e5aa60267182bdb9ffce02db7debe290e445b048aa1ec4c8f5b"
    cu128 = "4b19595f7363730085aacbfe563f3467313e0c95fe83abe66eff9c6d1e1c9ee9"
}

$PartCount = @{
    cu118 = 3
    cu122 = 3
    cu128 = 3
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
    if ($LASTEXITCODE -eq 0 -and $smiText -match 'CUDA\s+Version\s*:\s*(\d+)\.(\d+)') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        $cuda = [version]("{0}.{1}" -f $major, $minor)

        if ($cuda -ge [version]"12.8") { return "cu128" }
        if ($cuda -ge [version]"12.2") { return "cu122" }
        return "cu118"
    }

    $driverText = (& $nvidiaSmi.Source --query-gpu=driver_version --format=csv,noheader 2>$null |
        Select-Object -First 1 | Out-String).Trim()

    if ($driverText -match '^(\d+)\.(\d+)') {
        $driverMajor = [int]$Matches[1]
        $driverMinor = [int]$Matches[2]
        $driver = [version]("{0}.{1}" -f $driverMajor, $driverMinor)

        if ($driver -ge [version]"570.65") { return "cu128" }
        if ($driver -ge [version]"536.25") { return "cu122" }
        if ($driver -ge [version]"522.06") { return "cu118" }

        throw "NVIDIA driver $driverText is too old for the packaged CUDA 11.8 build. Update the driver first."
    }

    throw "Could not determine CUDA compatibility from nvidia-smi. Pass -Variant cu118/cu122/cu128."
}

function Invoke-DotNetDownload {
    param(
        [Parameter(Mandatory = $true)][string]$SourceUrl,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromHours(6)
    $response = $null
    $inputStream = $null
    $outputStream = $null

    try {
        $response = $client.GetAsync(
            $SourceUrl,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        $null = $response.EnsureSuccessStatusCode()

        $total = $response.Content.Headers.ContentLength
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        $buffer = New-Object byte[] (4 * 1024 * 1024)
        [long]$downloaded = 0
        [int]$lastPercent = -1
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $downloaded += $read
            if ($total -and $total -gt 0) {
                $percent = [int](($downloaded * 100) / $total)
                if ($percent -ge ($lastPercent + 5)) {
                    Write-Host ("  {0}% ({1:N1} / {2:N1} MiB)" -f $percent, ($downloaded / 1MB), ($total / 1MB))
                    $lastPercent = $percent
                }
            }
        }
    } catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }
}

function Invoke-DirectDownload {
    param(
        [Parameter(Mandatory = $true)][string]$SourceUrl,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
    if ($curl) {
        $resume = (Test-Path -LiteralPath $Destination -PathType Leaf) -and ((Get-Item -LiteralPath $Destination).Length -gt 0)
        $args = @(
            "-L",
            "--fail",
            "--retry", "5",
            "--retry-all-errors",
            "--retry-delay", "2",
            "--connect-timeout", "30",
            "--progress-bar"
        )
        if ($resume) {
            Write-Host "Resuming existing partial file..."
            $args += @("-C", "-")
        }
        $args += @("-o", $Destination, $SourceUrl)

        & $curl.Source @args
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Destination -PathType Leaf)) {
            return
        }

        if ($resume) {
            Write-Host "Resume failed; retrying this part from the beginning."
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            $args = @(
                "-L",
                "--fail",
                "--retry", "5",
                "--retry-all-errors",
                "--retry-delay", "2",
                "--connect-timeout", "30",
                "--progress-bar",
                "-o", $Destination,
                $SourceUrl
            )
            & $curl.Source @args
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Destination -PathType Leaf)) {
                return
            }
        }

        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        Write-Host "curl.exe failed; falling back to .NET streaming HTTP for this part."
    }

    Invoke-DotNetDownload -SourceUrl $SourceUrl -Destination $Destination
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw "Download completed without creating the expected file: $Destination"
    }
}

function Join-SplitFiles {
    param(
        [Parameter(Mandatory = $true)][string[]]$Parts,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $output = $null
    try {
        $output = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $buffer = New-Object byte[] (8 * 1024 * 1024)
        foreach ($part in $Parts) {
            Write-Host "Merging $(Split-Path -Leaf $part)..."
            $input = $null
            try {
                $input = [System.IO.File]::OpenRead($part)
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $output.Write($buffer, 0, $read)
                }
            } finally {
                if ($input) { $input.Dispose() }
            }
        }
    } finally {
        if ($output) { $output.Dispose() }
    }
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
        Write-Host "Existing archive failed verification; rebuilding from GitHub split files."
        Remove-Item -LiteralPath $archivePath -Force
    }
}

$partPaths = @()
if ($needDownload) {
    Write-Host "Downloading the v1.10.1 Japanese transcribe package directly from GitHub split assets..."
    for ($i = 0; $i -lt $PartCount[$selectedVariant]; $i++) {
        $suffix = $i.ToString("0000")
        $partName = "$archiveName.$suffix"
        $partPath = Join-Path $downloadDir $partName
        $partUrl = "$ReleaseBase/$partName"
        $partPaths += $partPath

        Write-Host ""
        Write-Host "Part $($i + 1)/$($PartCount[$selectedVariant]): $partName"
        Invoke-DirectDownload -SourceUrl $partUrl -Destination $partPath
    }

    Write-Host ""
    Write-Host "Combining split files..."
    Join-SplitFiles -Parts $partPaths -Destination $archivePath
}

Write-Host "Verifying SHA-256..."
$actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) {
    Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
    foreach ($partPath in $partPaths) {
        Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
    }
    throw "SHA-256 verification failed. The combined archive and split files were deleted; run the installer again."
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
        foreach ($partPath in $partPaths) {
            Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        }
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
