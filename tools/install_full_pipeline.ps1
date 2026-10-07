[CmdletBinding()]
param(
    [string]$InstallRoot = "",
    [ValidateSet("auto", "cu118", "cu122", "cu128")]
    [string]$Variant = "auto",
    [string]$ReleaseTag = "latest",
    [switch]$SkipStage2Model,
    [switch]$KeepDownloads,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = "Marcus515J/Faster-Whisper-TransWithAI-ChickenRice"

function Resolve-CudaVariant {
    if ($Variant -ne "auto") {
        return $Variant
    }

    $nvidiaSmi = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        $nvidiaSmi = Get-Command "nvidia-smi" -ErrorAction SilentlyContinue
    }
    if (-not $nvidiaSmi) {
        throw "nvidia-smi was not found. Pass -Variant cu118/cu122/cu128 explicitly."
    }

    $text = (& $nvidiaSmi.Source 2>&1 | Out-String)
    if ($text -match 'CUDA\s+Version\s*:\s*(\d+)\.(\d+)') {
        $cuda = [version]("{0}.{1}" -f $Matches[1], $Matches[2])
        if ($cuda -ge [version]"12.8") {
            return "cu128"
        }
        if ($cuda -ge [version]"12.2") {
            return "cu122"
        }
        return "cu118"
    }

    throw "Could not determine CUDA compatibility from nvidia-smi. Pass -Variant explicitly."
}

function Invoke-StreamingDownload {
    param(
        [Parameter(Mandatory = $true)][string]$SourceUrl,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
    if ($curl) {
        $args = @(
            "-L",
            "--fail",
            "--retry", "5",
            "--retry-all-errors",
            "--retry-delay", "2",
            "--connect-timeout", "30",
            "--progress-bar"
        )
        if (
            (Test-Path -LiteralPath $Destination -PathType Leaf) -and
            ((Get-Item -LiteralPath $Destination).Length -gt 0)
        ) {
            $args += @("-C", "-")
        }
        $args += @("-o", $Destination, $SourceUrl)

        & $curl.Source @args
        if (
            $LASTEXITCODE -eq 0 -and
            (Test-Path -LiteralPath $Destination -PathType Leaf)
        ) {
            return
        }

        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromHours(12)
    $response = $null
    $inputStream = $null
    $outputStream = $null

    try {
        $response = $client.GetAsync(
            $SourceUrl,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        $null = $response.EnsureSuccessStatusCode()
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )

        $buffer = New-Object byte[] (8 * 1024 * 1024)
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
        }
    }
    catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        if ($outputStream) {
            $outputStream.Dispose()
        }
        if ($inputStream) {
            $inputStream.Dispose()
        }
        if ($response) {
            $response.Dispose()
        }
        if ($client) {
            $client.Dispose()
        }
        if ($handler) {
            $handler.Dispose()
        }
    }
}

function Assert-AssetDigest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Asset
    )

    if (-not ($Asset.PSObject.Properties.Name -contains "digest")) {
        return
    }

    $expected = [string]$Asset.digest
    if (-not $expected) {
        return
    }

    $expected = $expected.ToLowerInvariant().Replace("sha256:", "")
    if ($expected -notmatch '^[0-9a-f]{64}$') {
        throw "Release asset has an invalid SHA-256 digest: $($Asset.name)"
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Release asset SHA-256 mismatch: $($Asset.name)"
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
            $input = $null
            try {
                $input = [System.IO.File]::OpenRead($part)
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $output.Write($buffer, 0, $read)
                }
            }
            finally {
                if ($input) {
                    $input.Dispose()
                }
            }
        }
    }
    finally {
        if ($output) {
            $output.Dispose()
        }
    }
}

function Expand-LargeZip {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $tar = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if (-not $tar) {
        $tar = Get-Command "tar" -ErrorAction SilentlyContinue
    }

    if ($tar) {
        & $tar.Source -xf $Archive -C $Destination
        if ($LASTEXITCODE -ne 0) {
            throw "Archive extraction failed with exit code $LASTEXITCODE."
        }
        return
    }

    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
}

function Get-ReleaseAndAssets {
    param(
        [Parameter(Mandatory = $true)][string]$Tag
    )

    $releaseApi = if ($Tag -eq "latest") {
        "https://api.github.com/repos/$Repo/releases/latest"
    }
    else {
        "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    }

    $headers = @{"User-Agent" = "ChickenRice-Full-Installer"}
    $release = Invoke-RestMethod -Uri $releaseApi -Headers $headers
    if (-not $release.assets_url) {
        throw "GitHub release response did not contain assets_url."
    }

    $assets = @(
        Invoke-RestMethod -Uri ($release.assets_url + "?per_page=100") -Headers $headers
    )

    return [pscustomobject]@{
        release = $release
        assets = $assets
    }
}

function Invoke-SelfTest {
    $temp = Join-Path $env:TEMP (
        "chickenrice-installer-selftest-" +
        [guid]::NewGuid().ToString("N")
    )
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    try {
        $partA = Join-Path $temp "a.part"
        $partB = Join-Path $temp "b.part"
        $joined = Join-Path $temp "joined.bin"

        [System.IO.File]::WriteAllBytes($partA, [byte[]](1, 2, 3))
        [System.IO.File]::WriteAllBytes($partB, [byte[]](4, 5))
        Join-SplitFiles -Parts @($partA, $partB) -Destination $joined

        $bytes = [System.IO.File]::ReadAllBytes($joined)
        if (
            $bytes.Length -ne 5 -or
            $bytes[0] -ne 1 -or
            $bytes[4] -ne 5
        ) {
            throw "Split-file join self-test failed."
        }

        $digest = "sha256:" + (("0" * 64) -join "")
        if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
            throw "Release digest format self-test failed."
        }

        $sampleName = "faster_whisper_transwithai_windows_cu128-transcribe.zip.0002"
        $archiveBase = "faster_whisper_transwithai_windows_cu128-transcribe.zip"
        if (
            $sampleName -notmatch (
                [regex]::Escape($archiveBase) + '\.\d{4}$'
            )
        ) {
            throw "Release split-asset matching self-test failed."
        }

        Write-Host "Full pipeline installer self-test passed." -ForegroundColor Green
    }
    finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

if (-not $InstallRoot) {
    $InstallRoot = Join-Path (Get-Location).Path "ChickenRice-HyMT2"
}
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)

$selectedVariant = Resolve-CudaVariant
$resolved = Get-ReleaseAndAssets -Tag $ReleaseTag
$release = $resolved.release
$assets = @($resolved.assets)
$resolvedTag = [string]$release.tag_name
$archiveBase = "faster_whisper_transwithai_windows_$selectedVariant-transcribe.zip"

$directAsset = @(
    $assets |
        Where-Object { $_.name -eq $archiveBase } |
        Select-Object -First 1
)
$partAssets = @(
    $assets |
        Where-Object {
            $_.name -match (
                [regex]::Escape($archiveBase) + '\.\d{4}$'
            )
        } |
        Sort-Object name
)

if ($directAsset.Count -eq 0 -and $partAssets.Count -eq 0) {
    throw (
        "Transcribe package was not found in release " +
        "$resolvedTag for variant $selectedVariant."
    )
}

if (Test-Path -LiteralPath $InstallRoot) {
    $existing = @(
        Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue
    )
    if ($existing.Count -gt 0) {
        throw "InstallRoot is not empty: $InstallRoot"
    }
    Remove-Item -LiteralPath $InstallRoot -Force
}

$installParent = Split-Path $InstallRoot -Parent
if (-not $installParent) {
    throw "Could not resolve InstallRoot parent: $InstallRoot"
}
New-Item -ItemType Directory -Path $installParent -Force | Out-Null

$downloadRoot = Join-Path $installParent "_chickenrice-downloads"
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null

$archivePath = Join-Path $downloadRoot $archiveBase
$partPaths = @()
$extractPath = "$InstallRoot.extracting"

try {
    if ($directAsset.Count -gt 0) {
        Write-Host "Downloading $archiveBase from $resolvedTag..."
        Invoke-StreamingDownload -SourceUrl ([string]$directAsset[0].browser_download_url) -Destination $archivePath
        Assert-AssetDigest -Path $archivePath -Asset $directAsset[0]
    }
    else {
        $index = 0
        foreach ($asset in $partAssets) {
            $index++
            $partPath = Join-Path $downloadRoot ([string]$asset.name)
            $partPaths += $partPath

            Write-Host (
                "Downloading part {0}/{1}: {2}" -f
                $index,
                $partAssets.Count,
                $asset.name
            )
            Invoke-StreamingDownload -SourceUrl ([string]$asset.browser_download_url) -Destination $partPath
            Assert-AssetDigest -Path $partPath -Asset $asset
        }

        Write-Host "Combining release parts..."
        Join-SplitFiles -Parts $partPaths -Destination $archivePath
    }

    if (Test-Path -LiteralPath $extractPath) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

    Write-Host "Extracting Stage 1 package..."
    Expand-LargeZip -Archive $archivePath -Destination $extractPath

    if (-not (Test-Path -LiteralPath (Join-Path $extractPath "infer.exe"))) {
        throw "Extracted transcribe package is missing infer.exe."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $extractPath "models"))) {
        throw "Extracted transcribe package is missing models."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $extractPath "setup_stage2_runtime.ps1"))) {
        throw "Extracted transcribe package is missing setup_stage2_runtime.ps1."
    }

    Move-Item -LiteralPath $extractPath -Destination $InstallRoot

    $setup = Join-Path $InstallRoot "setup_stage2_runtime.ps1"
    Write-Host ""
    Write-Host "Installing Stage 2 runtime..."

    $setupArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $setup,
        "-Stage2Root", (Join-Path $InstallRoot "stage2-runtime"),
        "-ReleaseTag", $resolvedTag
    )
    if ($SkipStage2Model) {
        $setupArgs += "-SkipModel"
    }

    & powershell.exe @setupArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Stage 2 setup failed with exit code $LASTEXITCODE."
    }

    Write-Host ""
    Write-Host "Full ChickenRice + Hy-MT2 pipeline is ready." -ForegroundColor Green
    Write-Host "Release:     $resolvedTag"
    Write-Host "InstallRoot: $InstallRoot"
    Write-Host "Launcher:    $(Join-Path $InstallRoot 'run_full_pipeline_local.ps1')"
    Write-Host "Double-click: $(Join-Path $InstallRoot '运行(日文转录+HyMT2中文字幕).bat')"
}
finally {
    if (Test-Path -LiteralPath $extractPath) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not $KeepDownloads) {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        foreach ($partPath in $partPaths) {
            Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        }

        try {
            if (
                (Test-Path -LiteralPath $downloadRoot) -and
                -not (Get-ChildItem -LiteralPath $downloadRoot -Force)
            ) {
                Remove-Item -LiteralPath $downloadRoot -Force
            }
        }
        catch {
        }
    }
}
