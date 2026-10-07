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
    if ($Variant -ne "auto") { return $Variant }

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
        if ($cuda -ge [version]"12.8") { return "cu128" }
        if ($cuda -ge [version]"12.2") { return "cu122" }
        return "cu118"
    }

    throw "Could not determine CUDA compatibility from nvidia-smi. Pass -Variant explicitly."
}

function Invoke-StreamingDownload(
    [string]$SourceUrl,
    [string]$Destination
) {
    $curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
    if ($curl) {
        $args = @(
            "-L", "--fail",
            "--retry", "5",
            "--retry-all-errors",
            "--retry-delay", "2",
            "--connect-timeout", "30",
            "--progress-bar"
        )
        if ((Test-Path -LiteralPath $Destination) -and ((Get-Item -LiteralPath $Destination).Length -gt 0)) {
            $args += @("-C", "-")
        }
        $args += @("-o", $Destination, $SourceUrl)
        & $curl.Source @args
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Destination)) {
            return
        }
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromHours(12)
    $response = $null
    $input = $null
    $output = $null
    try {
        $response = $client.GetAsync(
            $SourceUrl,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        $null = $response.EnsureSuccessStatusCode()
        $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $output = [System.IO.File]::Open(
            $Destination,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $buffer = New-Object byte[] (8 * 1024 * 1024)
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $output.Write($buffer, 0, $read)
        }
    }
    finally {
        if ($output) { $output.Dispose() }
        if ($input) { $input.Dispose() }
        if ($response) { $response.Dispose() }
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }
}

function Assert-AssetDigest(
    [string]$Path,
    [object]$Asset
) {
    if (-not ($Asset.PSObject.Properties.Name -contains "digest")) { return }
    $expected = [string]$Asset.digest
    if (-not $expected) { return }
    $expected = $expected.ToLowerInvariant().Replace("sha256:", "")
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Release asset SHA-256 mismatch: $($Asset.name)"
    }
}

function Expand-LargeZip(
    [string]$Archive,
    [string]$Destination
) {
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

function Join-Parts(
    [string[]]$Parts,
    [string]$Destination
) {
    $output = [System.IO.File]::Open(
        $Destination,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $buffer = New-Object byte[] (8 * 1024 * 1024)
        foreach ($part in $Parts) {
            $input = [System.IO.File]::OpenRead($part)
            try {
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $output.Write($buffer, 0, $read)
                }
            }
            finally {
                $input.Dispose()
            }
        }
    }
    finally {
        $output.Dispose()
    }
}

function Invoke-SelfTest {
    $temp = Join-Path $env:TEMP ("chickenrice-installer-selftest-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    try {
        $a = Join-Path $temp "a.part"
        $b = Join-Path $temp "b.part"
        $out = Join-Path $temp "joined.bin"
        [System.IO.File]::WriteAllBytes($a, [byte[]](1,2,3))
        [System.IO.File]::WriteAllBytes($b, [byte[]](4,5))
        Join-Parts @($a, $b) $out
        $bytes = [System.IO.File]::ReadAllBytes($out)
        if ($bytes.Length -ne 5 -or $bytes[0] -ne 1 -or $bytes[4] -ne 5) {
            throw "Split-file join self-test failed."
        }

        $mock = [pscustomobject]@{
            name = "test.bin"
            digest = "sha256:" + (("0" * 64) -join "")
        }
        if ([string]$mock.digest -notmatch '^sha256:[0-9a-f]{64}
    $InstallRoot = Join-Path (Get-Location).Path "ChickenRice-HyMT2"
}
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
$selectedVariant = Resolve-CudaVariant

$releaseApi = if ($ReleaseTag -eq "latest") {
    "https://api.github.com/repos/$Repo/releases/latest"
}
else {
    "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag"
}

Write-Host "Resolving release..."
$release = Invoke-RestMethod -Uri $releaseApi -Headers @{"User-Agent"="ChickenRice-Full-Installer"}
$resolvedTag = [string]$release.tag_name
$archiveBase = "faster_whisper_transwithai_windows_$selectedVariant-transcribe.zip"

$directAsset = @($release.assets | Where-Object { $_.name -eq $archiveBase } | Select-Object -First 1)
$partAssets = @(
    $release.assets |
        Where-Object { $_.name -match ([regex]::Escape($archiveBase) + '\.\d{4}$') } |
        Sort-Object name
)

if ($directAsset.Count -eq 0 -and $partAssets.Count -eq 0) {
    throw "Transcribe package was not found in release $resolvedTag for variant $selectedVariant."
}

if (Test-Path -LiteralPath $InstallRoot) {
    $existing = Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue
    if ($existing) {
        throw "InstallRoot is not empty: $InstallRoot"
    }
}

$installParent = Split-Path $InstallRoot -Parent
if (-not $installParent) {
    throw "Could not resolve InstallRoot parent: $InstallRoot"
}
New-Item -ItemType Directory -Path $installParent -Force | Out-Null
$downloadRoot = Join-Path $installParent "_chickenrice-downloads"
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
$archivePath = Join-Path $downloadRoot $archiveBase

try {
    if ($directAsset.Count -gt 0) {
        Write-Host "Downloading $archiveBase from $resolvedTag..."
        Invoke-StreamingDownload $directAsset[0].browser_download_url $archivePath
        Assert-AssetDigest $archivePath $directAsset[0]
    }
    else {
        $partPaths = @()
        $index = 0
        foreach ($asset in $partAssets) {
            $index++
            $partPath = Join-Path $downloadRoot ([string]$asset.name)
            Write-Host "Downloading part $index/$($partAssets.Count): $($asset.name)"
            Invoke-StreamingDownload ([string]$asset.browser_download_url) $partPath
            Assert-AssetDigest $partPath $asset
            $partPaths += $partPath
        }

        Write-Host "Combining release parts..."
        Join-Parts $partPaths $archivePath
    }

    $extract = "$InstallRoot.extracting"
    if (Test-Path -LiteralPath $extract) {
        Remove-Item -LiteralPath $extract -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extract -Force | Out-Null

    Write-Host "Extracting Stage 1 package..."
    Expand-LargeZip $archivePath $extract
    if (-not (Test-Path -LiteralPath (Join-Path $extract "infer.exe"))) {
        throw "Extracted transcribe package is missing infer.exe."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $extract "models"))) {
        throw "Extracted transcribe package is missing models."
    }

    Move-Item -LiteralPath $extract -Destination $InstallRoot

    $setup = Join-Path $InstallRoot "setup_stage2_runtime.ps1"
    if (-not (Test-Path -LiteralPath $setup)) {
        throw "Release package is missing setup_stage2_runtime.ps1."
    }

    Write-Host ""
    Write-Host "Installing Stage 2 runtime..."
    $args = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $setup,
        "-Stage2Root", (Join-Path $InstallRoot "stage2-runtime"),
        "-ReleaseTag", $resolvedTag
    )
    if ($SkipStage2Model) {
        $args += "-SkipModel"
    }

    & powershell.exe @args
    if ($LASTEXITCODE -ne 0) {
        throw "Stage 2 setup failed with exit code $LASTEXITCODE."
    }

    Write-Host ""
    Write-Host "Full ChickenRice + Hy-MT2 pipeline is ready." -ForegroundColor Green
    Write-Host "InstallRoot: $InstallRoot"
    Write-Host "Launcher:    $(Join-Path $InstallRoot 'run_full_pipeline_local.ps1')"
    Write-Host "Double-click the bundled full-pipeline BAT in InstallRoot."
}
finally {
    if (-not $KeepDownloads) {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        foreach ($asset in $partAssets) {
            Remove-Item -LiteralPath (Join-Path $downloadRoot ([string]$asset.name)) -Force -ErrorAction SilentlyContinue
        }
        try {
            if ((Test-Path -LiteralPath $downloadRoot) -and -not (Get-ChildItem -LiteralPath $downloadRoot -Force)) {
                Remove-Item -LiteralPath $downloadRoot -Force
            }
        } catch {}
    }
}
) {
            throw "Release digest format self-test failed."
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

$releaseApi = if ($ReleaseTag -eq "latest") {
    "https://api.github.com/repos/$Repo/releases/latest"
}
else {
    "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag"
}

Write-Host "Resolving release..."
$release = Invoke-RestMethod -Uri $releaseApi -Headers @{"User-Agent"="ChickenRice-Full-Installer"}
$resolvedTag = [string]$release.tag_name
$archiveBase = "faster_whisper_transwithai_windows_$selectedVariant-transcribe.zip"

$directAsset = @($release.assets | Where-Object { $_.name -eq $archiveBase } | Select-Object -First 1)
$partAssets = @(
    $release.assets |
        Where-Object { $_.name -match ([regex]::Escape($archiveBase) + '\.\d{4}$') } |
        Sort-Object name
)

if ($directAsset.Count -eq 0 -and $partAssets.Count -eq 0) {
    throw "Transcribe package was not found in release $resolvedTag for variant $selectedVariant."
}

if (Test-Path -LiteralPath $InstallRoot) {
    $existing = Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue
    if ($existing) {
        throw "InstallRoot is not empty: $InstallRoot"
    }
}

$installParent = Split-Path $InstallRoot -Parent
if (-not $installParent) {
    throw "Could not resolve InstallRoot parent: $InstallRoot"
}
New-Item -ItemType Directory -Path $installParent -Force | Out-Null
$downloadRoot = Join-Path $installParent "_chickenrice-downloads"
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
$archivePath = Join-Path $downloadRoot $archiveBase

try {
    if ($directAsset.Count -gt 0) {
        Write-Host "Downloading $archiveBase from $resolvedTag..."
        Invoke-StreamingDownload $directAsset[0].browser_download_url $archivePath
        Assert-AssetDigest $archivePath $directAsset[0]
    }
    else {
        $partPaths = @()
        $index = 0
        foreach ($asset in $partAssets) {
            $index++
            $partPath = Join-Path $downloadRoot ([string]$asset.name)
            Write-Host "Downloading part $index/$($partAssets.Count): $($asset.name)"
            Invoke-StreamingDownload ([string]$asset.browser_download_url) $partPath
            Assert-AssetDigest $partPath $asset
            $partPaths += $partPath
        }

        Write-Host "Combining release parts..."
        Join-Parts $partPaths $archivePath
    }

    $extract = "$InstallRoot.extracting"
    if (Test-Path -LiteralPath $extract) {
        Remove-Item -LiteralPath $extract -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extract -Force | Out-Null

    Write-Host "Extracting Stage 1 package..."
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extract -Force
    if (-not (Test-Path -LiteralPath (Join-Path $extract "infer.exe"))) {
        throw "Extracted transcribe package is missing infer.exe."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $extract "models"))) {
        throw "Extracted transcribe package is missing models."
    }

    Move-Item -LiteralPath $extract -Destination $InstallRoot

    $setup = Join-Path $InstallRoot "setup_stage2_runtime.ps1"
    if (-not (Test-Path -LiteralPath $setup)) {
        throw "Release package is missing setup_stage2_runtime.ps1."
    }

    Write-Host ""
    Write-Host "Installing Stage 2 runtime..."
    $args = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $setup,
        "-Stage2Root", (Join-Path $InstallRoot "stage2-runtime"),
        "-ReleaseTag", $resolvedTag
    )
    if ($SkipStage2Model) {
        $args += "-SkipModel"
    }

    & powershell.exe @args
    if ($LASTEXITCODE -ne 0) {
        throw "Stage 2 setup failed with exit code $LASTEXITCODE."
    }

    Write-Host ""
    Write-Host "Full ChickenRice + Hy-MT2 pipeline is ready." -ForegroundColor Green
    Write-Host "InstallRoot: $InstallRoot"
    Write-Host "Launcher:    $(Join-Path $InstallRoot 'run_full_pipeline_local.ps1')"
    Write-Host "Double-click the bundled full-pipeline BAT in InstallRoot."
}
finally {
    if (-not $KeepDownloads) {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        foreach ($asset in $partAssets) {
            Remove-Item -LiteralPath (Join-Path $downloadRoot ([string]$asset.name)) -Force -ErrorAction SilentlyContinue
        }
        try {
            if ((Test-Path -LiteralPath $downloadRoot) -and -not (Get-ChildItem -LiteralPath $downloadRoot -Force)) {
                Remove-Item -LiteralPath $downloadRoot -Force
            }
        } catch {}
    }
}
