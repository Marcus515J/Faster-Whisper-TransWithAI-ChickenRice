param(
    [string]$InstallRoot = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $InstallRoot) {
    $translatedFolder = ([char]0x7FFB).ToString() + ([char]0x8BD1).ToString()
    $InstallRoot = Join-Path (Join-Path (Join-Path "H:\0H" $translatedFolder) "transwithai") "1.10"
}

$RepoRaw = "https://raw.githubusercontent.com/Marcus515J/Faster-Whisper-TransWithAI-ChickenRice/main"
$PackageDir = Join-Path $InstallRoot "_internal\faster_whisper_transwithai_chickenrice"
$InferPath = Join-Path $PackageDir "infer.py"
$ConfigPath = Join-Path $InstallRoot "generation_config.json5"
$WordSplitPath = Join-Path $PackageDir "word_timing_split.py"
$RefinePatchPath = Join-Path $PackageDir "subtitle_refine_patch.py"

if (!(Test-Path $InstallRoot)) {
    throw "ChickenRice install directory was not found: $InstallRoot"
}
if (!(Test-Path $PackageDir)) {
    throw "Internal package directory was not found: $PackageDir"
}
if (!(Test-Path $InferPath)) {
    throw "infer.py was not found: $InferPath"
}

$TempDir = Join-Path $env:TEMP ("chickenrice-update-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

$Downloads = @(
    @{
        Name = "generation_config.json5"
        Url = "$RepoRaw/generation_config.json5"
        Temp = Join-Path $TempDir "generation_config.json5"
        Destination = $ConfigPath
    },
    @{
        Name = "word_timing_split.py"
        Url = "$RepoRaw/src/faster_whisper_transwithai_chickenrice/word_timing_split.py"
        Temp = Join-Path $TempDir "word_timing_split.py"
        Destination = $WordSplitPath
    },
    @{
        Name = "subtitle_refine_patch.py"
        Url = "$RepoRaw/src/faster_whisper_transwithai_chickenrice/subtitle_refine_patch.py"
        Temp = Join-Path $TempDir "subtitle_refine_patch.py"
        Destination = $RefinePatchPath
    }
)

$BackupDir = $null
$Changed = New-Object System.Collections.Generic.List[string]
$BackedUp = New-Object System.Collections.Generic.List[object]

function Get-HashOrNull([string]$Path) {
    if (!(Test-Path $Path)) { return $null }
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash
}

function Ensure-BackupDir {
    if ($null -eq $script:BackupDir) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $script:BackupDir = Join-Path $InstallRoot ("_update_backup\" + $stamp)
        New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    }
}

function Backup-File([string]$Path, [string]$RelativeName) {
    if (!(Test-Path $Path)) { return }
    Ensure-BackupDir
    $backupPath = Join-Path $script:BackupDir $RelativeName
    $backupParent = Split-Path $backupPath -Parent
    New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
    Copy-Item $Path $backupPath -Force
    $script:BackedUp.Add([pscustomobject]@{ Original = $Path; Backup = $backupPath }) | Out-Null
}

try {
    Write-Host "Checking GitHub main for the latest validated files..." -ForegroundColor Cyan

    foreach ($item in $Downloads) {
        Invoke-WebRequest -Uri $item.Url -OutFile $item.Temp -UseBasicParsing
        if (!(Test-Path $item.Temp) -or (Get-Item $item.Temp).Length -lt 20) {
            throw "Downloaded file is invalid: $($item.Name)"
        }
    }

    $configText = Get-Content $Downloads[0].Temp -Raw -Encoding UTF8
    if ($configText -notmatch '"word_timing_split"' -or
        $configText -notmatch '"subtitle_refine"' -or
        $configText -notmatch '"min_display_duration_s"\s*:\s*0\.6' -or
        $configText -notmatch '"smart_split_with_vad"\s*:\s*false' -or
        $configText -notmatch '"max_duration_ms"\s*:\s*0') {
        throw "generation_config.json5 from GitHub failed validation. Update stopped."
    }

    $wordText = Get-Content $Downloads[1].Temp -Raw -Encoding UTF8
    if ($wordText -notmatch 'class WordTimingSplitOptions' -or
        $wordText -notmatch 'install_word_timing_split_patch' -or
        $wordText -notmatch 'min_display_duration_s') {
        throw "word_timing_split.py from GitHub failed validation. Update stopped."
    }

    $refineText = Get-Content $Downloads[2].Temp -Raw -Encoding UTF8
    if ($refineText -notmatch 'install_subtitle_refine_patch' -or
        $refineText -notmatch 'Subtitle refine: candidates' -or
        $refineText -notmatch 'align_segment_ends_to_vad') {
        throw "subtitle_refine_patch.py from GitHub failed validation. Update stopped."
    }

    foreach ($item in $Downloads) {
        $oldHash = Get-HashOrNull $item.Destination
        $newHash = Get-HashOrNull $item.Temp
        if ($oldHash -ne $newHash) {
            Backup-File $item.Destination $item.Name
            Copy-Item $item.Temp $item.Destination -Force
            $Changed.Add($item.Name) | Out-Null
        }
    }

    $inferText = Get-Content $InferPath -Raw -Encoding UTF8
    $inferChanged = $false

    if ($inferText -notmatch 'install_word_timing_split_patch') {
        $target = 'from .vad_manager import VadConfig, VadModelManager'
        if ($inferText -notmatch [regex]::Escape($target)) {
            throw "infer.py does not match the expected structure; refusing to patch it."
        }

        Backup-File $InferPath "infer.py"
        $replacement = @"
from .vad_manager import VadConfig, VadModelManager
from .word_timing_split import install_word_timing_split_patch

install_word_timing_split_patch()
"@
        $inferText = $inferText.Replace($target, $replacement.TrimEnd())
        $inferChanged = $true
    }

    if ($inferText -notmatch 'install_subtitle_refine_patch') {
        if (-not $inferChanged) {
            Backup-File $InferPath "infer.py"
        }

        $importTarget = 'from .word_timing_split import install_word_timing_split_patch'
        $callTarget = 'install_word_timing_split_patch()'
        if ($inferText -notmatch [regex]::Escape($importTarget) -or
            $inferText -notmatch [regex]::Escape($callTarget)) {
            throw "infer.py word timing hook is missing; refusing to add refinement hook."
        }

        $inferText = $inferText.Replace(
            $importTarget,
            $importTarget + "`r`nfrom .subtitle_refine_patch import install_subtitle_refine_patch"
        )
        $inferText = $inferText.Replace(
            $callTarget,
            $callTarget + "`r`ninstall_subtitle_refine_patch()"
        )
        $inferChanged = $true
    }

    if ($inferChanged) {
        [System.IO.File]::WriteAllText(
            $InferPath,
            $inferText,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $Changed.Add("infer.py hook") | Out-Null
    }

    $finalConfig = Get-Content $ConfigPath -Raw -Encoding UTF8
    $finalWord = Get-Content $WordSplitPath -Raw -Encoding UTF8
    $finalRefine = Get-Content $RefinePatchPath -Raw -Encoding UTF8
    $finalInfer = Get-Content $InferPath -Raw -Encoding UTF8

    $ok =
        ($finalConfig -match '"word_timing_split"') -and
        ($finalConfig -match '"subtitle_refine"') -and
        ($finalConfig -match '"min_display_duration_s"\s*:\s*0\.6') -and
        ($finalConfig -match '"smart_split_with_vad"\s*:\s*false') -and
        ($finalConfig -match '"segment_merge"\s*:\s*\{[\s\S]*?"enabled"\s*:\s*false') -and
        ($finalConfig -match '"max_duration_ms"\s*:\s*0') -and
        ($finalWord -match 'install_word_timing_split_patch') -and
        ($finalRefine -match 'install_subtitle_refine_patch') -and
        ($finalInfer -match 'install_word_timing_split_patch') -and
        ($finalInfer -match 'install_subtitle_refine_patch')

    if (!$ok) {
        throw "Updated local files failed final validation."
    }

    Write-Host ""
    if ($Changed.Count -eq 0) {
        Write-Host "Already up to date." -ForegroundColor Green
    } else {
        Write-Host "Update completed:" -ForegroundColor Green
        foreach ($name in $Changed) {
            Write-Host "   - $name"
        }
        if ($null -ne $BackupDir) {
            Write-Host "Backup: $BackupDir"
        }
    }
    Write-Host "Local subtitle files now match repository main." -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red

    if ($BackedUp.Count -gt 0) {
        Write-Host "Restoring files from before this update..." -ForegroundColor Yellow
        foreach ($entry in $BackedUp) {
            if (Test-Path $entry.Backup) {
                Copy-Item $entry.Backup $entry.Original -Force
            }
        }
        Write-Host "Restore completed." -ForegroundColor Yellow
    }
    exit 1
}
finally {
    Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
