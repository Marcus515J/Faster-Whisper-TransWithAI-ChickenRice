[CmdletBinding()]
param(
    [string]$Stage2Root = "",
    [string]$ReleaseTag = "latest",
    [switch]$SkipModel,
    [switch]$ForceRuntime,
    [string]$ModelUrl = "",
    [string]$ModelFile = "",
    [string]$ModelSha256 = "",
    [string]$ModelName = "",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = "Marcus515J/Faster-Whisper-TransWithAI-ChickenRice"
$RuntimeAssetName = "chickenrice_stage2_runtime_win_cuda12.zip"

function Resolve-BaseRoot {
    if (Test-Path -LiteralPath (Join-Path $PSScriptRoot "infer.exe")) {
        return $PSScriptRoot
    }

    $parent = Split-Path $PSScriptRoot -Parent
    if (
        $parent -and
        (Test-Path -LiteralPath (Join-Path $parent "infer.exe"))
    ) {
        return $parent
    }

    return $PSScriptRoot
}

function Get-ManifestPath {
    param(
        [Parameter(Mandatory = $true)][string]$BaseRoot
    )

    foreach ($candidate in @(
        (Join-Path $BaseRoot "stage2_runtime_manifest.json"),
        (Join-Path $PSScriptRoot "stage2_runtime_manifest.json")
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw "stage2_runtime_manifest.json was not found."
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

function Assert-Sha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Expected
    )

    if (-not $Expected) {
        return
    }

    $normalized = $Expected.ToLowerInvariant().Replace("sha256:", "")
    if ($normalized -notmatch '^[0-9a-f]{64}$') {
        throw "Expected SHA-256 is invalid for $Path."
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $normalized) {
        throw (
            "SHA-256 mismatch for $Path. " +
            "Expected $normalized, got $actual."
        )
    }
}

function Expand-ZipClean {
    param(
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
}

function Get-ReleaseAsset {
    param(
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$AssetName
    )

    $releaseApi = if ($Tag -eq "latest") {
        "https://api.github.com/repos/$Repo/releases/latest"
    }
    else {
        "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    }

    $headers = @{"User-Agent" = "ChickenRice-Stage2-Setup"}
    $release = Invoke-RestMethod -Uri $releaseApi -Headers $headers
    if (-not $release.assets_url) {
        throw "GitHub release response did not contain assets_url."
    }

    $assets = @(
        Invoke-RestMethod -Uri ($release.assets_url + "?per_page=100") -Headers $headers
    )
    $asset = @(
        $assets |
            Where-Object { $_.name -eq $AssetName } |
            Select-Object -First 1
    )

    return [pscustomobject]@{
        release = $release
        asset = $asset
    }
}

function Install-RuntimePayload {
    param(
        [Parameter(Mandatory = $true)][string]$ExtractRoot,
        [Parameter(Mandatory = $true)][string]$TargetRoot
    )

    $sourceLlama = Join-Path $ExtractRoot "llama.cpp"
    $sourceServer = Join-Path $sourceLlama "llama-server.exe"
    if (-not (Test-Path -LiteralPath $sourceServer -PathType Leaf)) {
        throw "Runtime payload is missing llama.cpp\llama-server.exe."
    }

    New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
    $targetLlama = Join-Path $TargetRoot "llama.cpp"

    if (Test-Path -LiteralPath $targetLlama) {
        Remove-Item -LiteralPath $targetLlama -Recurse -Force
    }
    Move-Item -LiteralPath $sourceLlama -Destination $targetLlama

    foreach ($extra in @(
        "stage2_runtime_manifest.json",
        "README_pipeline_bridge.md",
        "RUNTIME_INFO.txt"
    )) {
        $source = Join-Path $ExtractRoot $extra
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $TargetRoot $extra) -Force
        }
    }
}

function Invoke-SelfTest {
    $baseRoot = Resolve-BaseRoot
    $manifestPath = Get-ManifestPath -BaseRoot $baseRoot
    $testManifest = (
        Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
    )

    foreach ($item in @(
        $testManifest.llama_cpp.windows_cuda12.binaries,
        $testManifest.llama_cpp.windows_cuda12.cuda_runtime,
        $testManifest.translation_model
    )) {
        $sha = [string]$item.sha256
        if ($sha -notmatch '^[0-9a-fA-F]{64}$') {
            throw "Manifest SHA-256 is invalid."
        }

        $url = [string]$item.url
        if ($url -notmatch '^https://') {
            throw "Manifest URL must use HTTPS."
        }
    }

    if ([int64]$testManifest.translation_model.size_bytes -lt 1000000000) {
        throw "Translation model size metadata is invalid."
    }
    if (-not [string]$testManifest.translation_model.model_name) {
        throw "Translation model name is missing."
    }

    $temp = Join-Path $env:TEMP (
        "chickenrice-stage2-selftest-" +
        [guid]::NewGuid().ToString("N")
    )
    $target = Join-Path $temp "target"
    $extract = Join-Path $temp "extract"
    $modelDir = Join-Path $target "models"

    try {
        New-Item -ItemType Directory -Path $modelDir -Force | Out-Null
        $keepFile = Join-Path $modelDir "keep-model.gguf"
        [System.IO.File]::WriteAllText($keepFile, "keep")

        $sourceLlama = Join-Path $extract "llama.cpp"
        New-Item -ItemType Directory -Path $sourceLlama -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $sourceLlama "llama-server.exe"),
            "test"
        )

        Install-RuntimePayload -ExtractRoot $extract -TargetRoot $target

        if (-not (Test-Path -LiteralPath $keepFile -PathType Leaf)) {
            throw "Runtime refresh self-test deleted the model directory."
        }
        if (
            -not (
                Test-Path -LiteralPath (
                    Join-Path $target "llama.cpp\llama-server.exe"
                ) -PathType Leaf
            )
        ) {
            throw "Runtime payload install self-test failed."
        }
    }
    finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Stage 2 runtime setup self-test passed." -ForegroundColor Green
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

$baseRoot = Resolve-BaseRoot
$manifestPath = Get-ManifestPath -BaseRoot $baseRoot
$manifest = (
    Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
)

if (-not $Stage2Root) {
    $Stage2Root = Join-Path $baseRoot "stage2-runtime"
}
$Stage2Root = [System.IO.Path]::GetFullPath($Stage2Root)
$llamaRoot = Join-Path $Stage2Root "llama.cpp"
$llamaServer = Join-Path $llamaRoot "llama-server.exe"

$temp = Join-Path $env:TEMP (
    "chickenrice-stage2-setup-" +
    [guid]::NewGuid().ToString("N")
)
New-Item -ItemType Directory -Path $temp -Force | Out-Null

try {
    if ($ForceRuntime -or -not (Test-Path -LiteralPath $llamaServer -PathType Leaf)) {
        Write-Host "Resolving Stage 2 runtime release..."
        $resolved = Get-ReleaseAsset -Tag $ReleaseTag -AssetName $RuntimeAssetName

        if ($resolved.asset.Count -gt 0) {
            $runtimeZip = Join-Path $temp $RuntimeAssetName
            Write-Host (
                "Downloading packaged Stage 2 runtime from release " +
                "$($resolved.release.tag_name)..."
            )
            Invoke-StreamingDownload -SourceUrl ([string]$resolved.asset[0].browser_download_url) -Destination $runtimeZip

            if ($resolved.asset[0].PSObject.Properties.Name -contains "digest") {
                Assert-Sha256 -Path $runtimeZip -Expected ([string]$resolved.asset[0].digest)
            }

            $extract = Join-Path $temp "runtime"
            Expand-ZipClean -Archive $runtimeZip -Destination $extract
            Install-RuntimePayload -ExtractRoot $extract -TargetRoot $Stage2Root
        }
        else {
            Write-Host (
                "Release runtime asset not found; " +
                "falling back to pinned upstream llama.cpp files."
            )

            New-Item -ItemType Directory -Path $Stage2Root -Force | Out-Null
            if (Test-Path -LiteralPath $llamaRoot) {
                Remove-Item -LiteralPath $llamaRoot -Recurse -Force
            }
            New-Item -ItemType Directory -Path $llamaRoot -Force | Out-Null

            foreach ($item in @(
                $manifest.llama_cpp.windows_cuda12.binaries,
                $manifest.llama_cpp.windows_cuda12.cuda_runtime
            )) {
                $archive = Join-Path $temp ([string]$item.name)
                Write-Host "Downloading $($item.name)..."
                Invoke-StreamingDownload -SourceUrl ([string]$item.url) -Destination $archive
                Assert-Sha256 -Path $archive -Expected ([string]$item.sha256)
                Expand-Archive -LiteralPath $archive -DestinationPath $llamaRoot -Force
            }
        }
    }
    else {
        Write-Host "Existing llama.cpp runtime found: $llamaServer"
    }

    if (-not (Test-Path -LiteralPath $llamaServer -PathType Leaf)) {
        throw "llama-server.exe was not found after runtime setup: $llamaServer"
    }

    $defaultModel = $manifest.translation_model
    if (-not $ModelUrl) {
        $ModelUrl = [string]$defaultModel.url
    }
    if (-not $ModelFile) {
        $ModelFile = [string]$defaultModel.file
    }
    if (-not $ModelSha256) {
        $ModelSha256 = [string]$defaultModel.sha256
    }
    if (-not $ModelName) {
        $ModelName = [string]$defaultModel.model_name
    }

    $modelRoot = Join-Path $Stage2Root "models"
    New-Item -ItemType Directory -Path $modelRoot -Force | Out-Null
    $modelPath = Join-Path $modelRoot $ModelFile

    if (-not $SkipModel) {
        if (Test-Path -LiteralPath $modelPath -PathType Leaf) {
            try {
                Assert-Sha256 -Path $modelPath -Expected $ModelSha256
                Write-Host "Existing translation model passed SHA-256 verification."
            }
            catch {
                throw (
                    "Existing model failed verification. " +
                    "Move or remove it before retrying: $modelPath"
                )
            }
        }
        else {
            Write-Host "Downloading translation model: $ModelFile"
            Write-Host (
                "This is a large file and supports resume " +
                "when curl.exe is available."
            )
            Invoke-StreamingDownload -SourceUrl $ModelUrl -Destination $modelPath
            Assert-Sha256 -Path $modelPath -Expected $ModelSha256
        }
    }

    $config = [ordered]@{
        schema_version = 1
        llama_server_path = $llamaServer
        model_path = $modelPath
        model_name = $ModelName
        model_sha256 = $ModelSha256
        runtime_manifest = $manifestPath
    }

    $configPath = Join-Path $baseRoot "stage2_runtime.json"
    [System.IO.File]::WriteAllText(
        $configPath,
        ($config | ConvertTo-Json -Depth 6),
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-Host ""
    Write-Host "Stage 2 runtime is ready." -ForegroundColor Green
    Write-Host "llama-server: $llamaServer"
    if ($SkipModel) {
        Write-Host "Model download skipped. Expected model path: $modelPath"
    }
    else {
        Write-Host "Model:        $modelPath"
    }
    Write-Host "Config:       $configPath"
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
