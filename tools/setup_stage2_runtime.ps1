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
    if ($parent -and (Test-Path -LiteralPath (Join-Path $parent "infer.exe"))) {
        return $parent
    }
    return $PSScriptRoot
}

function Get-ManifestPath([string]$BaseRoot) {
    foreach ($candidate in @(
        (Join-Path $BaseRoot "stage2_runtime_manifest.json"),
        (Join-Path $PSScriptRoot "stage2_runtime_manifest.json")
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    throw "stage2_runtime_manifest.json was not found."
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

function Assert-Sha256(
    [string]$Path,
    [string]$Expected
) {
    if (-not $Expected) { return }
    $normalized = $Expected.ToLowerInvariant().Replace("sha256:", "")
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $normalized) {
        throw "SHA-256 mismatch for $Path. Expected $normalized, got $actual."
    }
}

function Expand-ZipClean(
    [string]$Archive,
    [string]$Destination
) {
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force
}

function Invoke-SelfTest {
    $root = Resolve-BaseRoot
    $path = Get-ManifestPath $root
    $testManifest = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json

    foreach ($item in @(
        $testManifest.llama_cpp.windows_cuda12.binaries,
        $testManifest.llama_cpp.windows_cuda12.cuda_runtime,
        $testManifest.translation_model
    )) {
        $sha = [string]$item.sha256
        if ($sha -notmatch '^[0-9a-fA-F]{64}
$manifestPath = Get-ManifestPath $baseRoot
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $Stage2Root) {
    $Stage2Root = Join-Path $baseRoot "stage2-runtime"
}
$Stage2Root = [System.IO.Path]::GetFullPath($Stage2Root)
$llamaRoot = Join-Path $Stage2Root "llama.cpp"
$llamaServer = Join-Path $llamaRoot "llama-server.exe"

$temp = Join-Path $env:TEMP ("chickenrice-stage2-setup-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

try {
    if ($ForceRuntime -or -not (Test-Path -LiteralPath $llamaServer)) {
        $releaseApi = if ($ReleaseTag -eq "latest") {
            "https://api.github.com/repos/$Repo/releases/latest"
        }
        else {
            "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag"
        }

        Write-Host "Resolving Stage 2 runtime release..."
        $release = Invoke-RestMethod -Uri $releaseApi -Headers @{"User-Agent"="ChickenRice-Stage2-Setup"}
        $runtimeAsset = @($release.assets | Where-Object { $_.name -eq $RuntimeAssetName } | Select-Object -First 1)

        if ($runtimeAsset.Count -gt 0) {
            $runtimeZip = Join-Path $temp $RuntimeAssetName
            Write-Host "Downloading packaged Stage 2 runtime from release $($release.tag_name)..."
            Invoke-StreamingDownload $runtimeAsset[0].browser_download_url $runtimeZip
            if ($runtimeAsset[0].PSObject.Properties.Name -contains "digest") {
                Assert-Sha256 $runtimeZip ([string]$runtimeAsset[0].digest)
            }

            $extract = Join-Path $temp "runtime"
            Expand-ZipClean $runtimeZip $extract
            if (-not (Test-Path -LiteralPath (Join-Path $extract "llama.cpp\llama-server.exe"))) {
                throw "Stage 2 runtime asset is missing llama.cpp\llama-server.exe."
            }

            New-Item -ItemType Directory -Path $Stage2Root -Force | Out-Null

            # Runtime refresh must never delete an already downloaded model.
            # Replace only stage2-runtime\llama.cpp and keep stage2-runtime\models.
            if (Test-Path -LiteralPath $llamaRoot) {
                Remove-Item -LiteralPath $llamaRoot -Recurse -Force
            }
            Move-Item -LiteralPath (Join-Path $extract "llama.cpp") -Destination $llamaRoot

            foreach ($extra in @(
                "stage2_runtime_manifest.json",
                "README_pipeline_bridge.md",
                "RUNTIME_INFO.txt"
            )) {
                $source = Join-Path $extract $extra
                if (Test-Path -LiteralPath $source) {
                    Copy-Item -LiteralPath $source -Destination (Join-Path $Stage2Root $extra) -Force
                }
            }
        }
        else {
            Write-Host "Release runtime asset not found; falling back to pinned upstream llama.cpp files."
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
                Invoke-StreamingDownload ([string]$item.url) $archive
                Assert-Sha256 $archive ([string]$item.sha256)
                Expand-Archive -LiteralPath $archive -DestinationPath $llamaRoot -Force
            }
        }
    }
    else {
        Write-Host "Existing llama.cpp runtime found: $llamaServer"
    }

    if (-not (Test-Path -LiteralPath $llamaServer)) {
        throw "llama-server.exe was not found after runtime setup: $llamaServer"
    }

    $defaultModel = $manifest.translation_model
    if (-not $ModelUrl) { $ModelUrl = [string]$defaultModel.url }
    if (-not $ModelFile) { $ModelFile = [string]$defaultModel.file }
    if (-not $ModelSha256) { $ModelSha256 = [string]$defaultModel.sha256 }
    if (-not $ModelName) { $ModelName = [string]$defaultModel.model_name }

    $modelRoot = Join-Path $Stage2Root "models"
    New-Item -ItemType Directory -Path $modelRoot -Force | Out-Null
    $modelPath = Join-Path $modelRoot $ModelFile

    if (-not $SkipModel) {
        $modelOk = $false
        if (Test-Path -LiteralPath $modelPath) {
            try {
                Assert-Sha256 $modelPath $ModelSha256
                $modelOk = $true
                Write-Host "Existing translation model passed SHA-256 verification."
            }
            catch {
                throw "Existing model failed verification. Move or remove it before retrying: $modelPath"
            }
        }

        if (-not $modelOk) {
            Write-Host "Downloading translation model: $ModelFile"
            Write-Host "This is a large file and supports resume when curl.exe is available."
            Invoke-StreamingDownload $ModelUrl $modelPath
            Assert-Sha256 $modelPath $ModelSha256
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
) {
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

    Write-Host "Stage 2 runtime setup self-test passed." -ForegroundColor Green
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

$baseRoot = Resolve-BaseRoot
$manifestPath = Get-ManifestPath $baseRoot
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $Stage2Root) {
    $Stage2Root = Join-Path $baseRoot "stage2-runtime"
}
$Stage2Root = [System.IO.Path]::GetFullPath($Stage2Root)
$llamaRoot = Join-Path $Stage2Root "llama.cpp"
$llamaServer = Join-Path $llamaRoot "llama-server.exe"

$temp = Join-Path $env:TEMP ("chickenrice-stage2-setup-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

try {
    if ($ForceRuntime -or -not (Test-Path -LiteralPath $llamaServer)) {
        $releaseApi = if ($ReleaseTag -eq "latest") {
            "https://api.github.com/repos/$Repo/releases/latest"
        }
        else {
            "https://api.github.com/repos/$Repo/releases/tags/$ReleaseTag"
        }

        Write-Host "Resolving Stage 2 runtime release..."
        $release = Invoke-RestMethod -Uri $releaseApi -Headers @{"User-Agent"="ChickenRice-Stage2-Setup"}
        $runtimeAsset = @($release.assets | Where-Object { $_.name -eq $RuntimeAssetName } | Select-Object -First 1)

        if ($runtimeAsset.Count -gt 0) {
            $runtimeZip = Join-Path $temp $RuntimeAssetName
            Write-Host "Downloading packaged Stage 2 runtime from release $($release.tag_name)..."
            Invoke-StreamingDownload $runtimeAsset[0].browser_download_url $runtimeZip
            if ($runtimeAsset[0].PSObject.Properties.Name -contains "digest") {
                Assert-Sha256 $runtimeZip ([string]$runtimeAsset[0].digest)
            }

            $extract = Join-Path $temp "runtime"
            Expand-ZipClean $runtimeZip $extract
            if (-not (Test-Path -LiteralPath (Join-Path $extract "llama.cpp\llama-server.exe"))) {
                throw "Stage 2 runtime asset is missing llama.cpp\llama-server.exe."
            }

            New-Item -ItemType Directory -Path $Stage2Root -Force | Out-Null

            # Runtime refresh must never delete an already downloaded model.
            # Replace only stage2-runtime\llama.cpp and keep stage2-runtime\models.
            if (Test-Path -LiteralPath $llamaRoot) {
                Remove-Item -LiteralPath $llamaRoot -Recurse -Force
            }
            Move-Item -LiteralPath (Join-Path $extract "llama.cpp") -Destination $llamaRoot

            foreach ($extra in @(
                "stage2_runtime_manifest.json",
                "README_pipeline_bridge.md",
                "RUNTIME_INFO.txt"
            )) {
                $source = Join-Path $extract $extra
                if (Test-Path -LiteralPath $source) {
                    Copy-Item -LiteralPath $source -Destination (Join-Path $Stage2Root $extra) -Force
                }
            }
        }
        else {
            Write-Host "Release runtime asset not found; falling back to pinned upstream llama.cpp files."
            New-Item -ItemType Directory -Path $llamaRoot -Force | Out-Null

            foreach ($item in @(
                $manifest.llama_cpp.windows_cuda12.binaries,
                $manifest.llama_cpp.windows_cuda12.cuda_runtime
            )) {
                $archive = Join-Path $temp ([string]$item.name)
                Write-Host "Downloading $($item.name)..."
                Invoke-StreamingDownload ([string]$item.url) $archive
                Assert-Sha256 $archive ([string]$item.sha256)
                Expand-Archive -LiteralPath $archive -DestinationPath $llamaRoot -Force
            }
        }
    }
    else {
        Write-Host "Existing llama.cpp runtime found: $llamaServer"
    }

    if (-not (Test-Path -LiteralPath $llamaServer)) {
        throw "llama-server.exe was not found after runtime setup: $llamaServer"
    }

    $defaultModel = $manifest.translation_model
    if (-not $ModelUrl) { $ModelUrl = [string]$defaultModel.url }
    if (-not $ModelFile) { $ModelFile = [string]$defaultModel.file }
    if (-not $ModelSha256) { $ModelSha256 = [string]$defaultModel.sha256 }
    if (-not $ModelName) { $ModelName = [string]$defaultModel.model_name }

    $modelRoot = Join-Path $Stage2Root "models"
    New-Item -ItemType Directory -Path $modelRoot -Force | Out-Null
    $modelPath = Join-Path $modelRoot $ModelFile

    if (-not $SkipModel) {
        $modelOk = $false
        if (Test-Path -LiteralPath $modelPath) {
            try {
                Assert-Sha256 $modelPath $ModelSha256
                $modelOk = $true
                Write-Host "Existing translation model passed SHA-256 verification."
            }
            catch {
                throw "Existing model failed verification. Move or remove it before retrying: $modelPath"
            }
        }

        if (-not $modelOk) {
            Write-Host "Downloading translation model: $ModelFile"
            Write-Host "This is a large file and supports resume when curl.exe is available."
            Invoke-StreamingDownload $ModelUrl $modelPath
            Assert-Sha256 $modelPath $ModelSha256
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
