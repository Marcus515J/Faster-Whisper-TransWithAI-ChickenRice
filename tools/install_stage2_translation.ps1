param(
    [string]$InstallRoot = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $InstallRoot) {
    $translatedFolder = ([char]0x7FFB).ToString() + ([char]0x8BD1).ToString()
    $InstallRoot = Join-Path (Join-Path (Join-Path "H:\0H" $translatedFolder) "transwithai") "1.10.1-transcribe"
}

if (-not (Test-Path $InstallRoot)) {
    throw "ChickenRice install directory was not found: $InstallRoot"
}

$RepoRaw = "https://raw.githubusercontent.com/Marcus515J/Faster-Whisper-TransWithAI-ChickenRice/main/tools"
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
        throw "Stage 2 self-test failed."
    }

    Write-Host ""
    Write-Host "Stage 2 translation tools installed." -ForegroundColor Green
    Write-Host "Launcher: $(Join-Path $InstallRoot 'translate_srt_to_chinese.bat')"
    Write-Host "Config:   $activeConfig"
}
finally {
    Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
