param(
    [string]$InstallRoot = "H:\0H\翻译\transwithai\1.10"
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoRaw = "https://raw.githubusercontent.com/Marcus515J/Faster-Whisper-TransWithAI-ChickenRice/main"
$PackageDir = Join-Path $InstallRoot "_internal\faster_whisper_transwithai_chickenrice"
$InferPath = Join-Path $PackageDir "infer.py"
$ConfigPath = Join-Path $InstallRoot "generation_config.json5"
$WordSplitPath = Join-Path $PackageDir "word_timing_split.py"

if (!(Test-Path $InstallRoot)) {
    throw "找不到海南鸡目录：$InstallRoot"
}
if (!(Test-Path $PackageDir)) {
    throw "找不到内部程序目录：$PackageDir"
}
if (!(Test-Path $InferPath)) {
    throw "找不到 infer.py：$InferPath"
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
        Name = "运行(翻译)(CPU).bat"
        Url = "$RepoRaw/运行(翻译)(CPU).bat"
        Temp = Join-Path $TempDir "运行(翻译)(CPU).bat"
        Destination = Join-Path $InstallRoot "运行(翻译)(CPU).bat"
    },
    @{
        Name = "运行(翻译)(GPU).bat"
        Url = "$RepoRaw/运行(翻译)(GPU).bat"
        Temp = Join-Path $TempDir "运行(翻译)(GPU).bat"
        Destination = Join-Path $InstallRoot "运行(翻译)(GPU).bat"
    },
    @{
        Name = "运行(翻译)(GPU)(输出到当前文件夹).bat"
        Url = "$RepoRaw/运行(翻译)(GPU)(输出到当前文件夹).bat"
        Temp = Join-Path $TempDir "运行(翻译)(GPU)(输出到当前文件夹).bat"
        Destination = Join-Path $InstallRoot "运行(翻译)(GPU)(输出到当前文件夹).bat"
    },
    @{
        Name = "运行(翻译)(GPU,低显存模式).bat"
        Url = "$RepoRaw/运行(翻译)(GPU,低显存模式).bat"
        Temp = Join-Path $TempDir "运行(翻译)(GPU,低显存模式).bat"
        Destination = Join-Path $InstallRoot "运行(翻译)(GPU,低显存模式).bat"
    },
    @{
        Name = "运行(翻译)(GPU,高显存加速模式).bat"
        Url = "$RepoRaw/运行(翻译)(GPU,高显存加速模式).bat"
        Temp = Join-Path $TempDir "运行(翻译)(GPU,高显存加速模式).bat"
        Destination = Join-Path $InstallRoot "运行(翻译)(GPU,高显存加速模式).bat"
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
    Write-Host "正在检查 GitHub main 最新配置..." -ForegroundColor Cyan

    foreach ($item in $Downloads) {
        Invoke-WebRequest -Uri $item.Url -OutFile $item.Temp -UseBasicParsing
        if (!(Test-Path $item.Temp) -or (Get-Item $item.Temp).Length -lt 20) {
            throw "下载文件异常：$($item.Name)"
        }
    }

    $configText = Get-Content $Downloads[0].Temp -Raw -Encoding UTF8
    if ($configText -notmatch '"word_timing_split"' -or
        $configText -notmatch '"min_display_duration_s"\s*:\s*0\.6' -or
        $configText -notmatch '"end_hold_s"\s*:\s*1\.0' -or
        $configText -notmatch '"beam_size"\s*:\s*5' -or
        $configText -notmatch '"no_repeat_ngram_size"\s*:\s*3' -or
        $configText -notmatch '"compression_ratio_threshold"\s*:\s*2\.0' -or
        $configText -notmatch '"smart_split_with_vad"\s*:\s*false' -or
        $configText -notmatch '"max_duration_ms"\s*:\s*0') {
        throw "仓库中的 generation_config.json5 未通过安全检查，已停止更新。"
    }

    $wordText = Get-Content $Downloads[1].Temp -Raw -Encoding UTF8
    if ($wordText -notmatch 'class WordTimingSplitOptions' -or
        $wordText -notmatch 'install_word_timing_split_patch' -or
        $wordText -notmatch 'min_display_duration_s' -or
        $wordText -notmatch '_parse_clip_timestamps' -or
        $wordText -notmatch '_matching_speech_span_end') {
        throw "仓库中的 word_timing_split.py 未通过安全检查，已停止更新。"
    }

    foreach ($item in $Downloads | Select-Object -Skip 2) {
        $batText = Get-Content $item.Temp -Raw -Encoding UTF8
        if ($batText -notmatch '--sub_formats="srt"' -or
            $batText -match '--sub_formats="[^"]*(vtt|lrc)') {
            throw "仓库中的 $($item.Name) 不是 SRT-only 配置，已停止更新。"
        }
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
    if ($inferText -notmatch 'install_word_timing_split_patch') {
        $target = 'from .vad_manager import VadConfig, VadModelManager'
        if ($inferText -notmatch [regex]::Escape($target)) {
            throw "infer.py 结构与预期不一致，无法安全安装词级切分挂钩。"
        }

        Backup-File $InferPath "infer.py"
        $replacement = @"
from .vad_manager import VadConfig, VadModelManager
from .word_timing_split import install_word_timing_split_patch

install_word_timing_split_patch()
"@
        $inferText = $inferText.Replace($target, $replacement.TrimEnd())
        [System.IO.File]::WriteAllText(
            $InferPath,
            $inferText,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $Changed.Add("infer.py 挂钩") | Out-Null
    }

    $finalConfig = Get-Content $ConfigPath -Raw -Encoding UTF8
    $finalWord = Get-Content $WordSplitPath -Raw -Encoding UTF8
    $finalInfer = Get-Content $InferPath -Raw -Encoding UTF8

    $ok =
        ($finalConfig -match '"word_timing_split"') -and
        ($finalConfig -match '"min_display_duration_s"\s*:\s*0\.6') -and
        ($finalConfig -match '"end_hold_s"\s*:\s*1\.0') -and
        ($finalConfig -match '"no_repeat_ngram_size"\s*:\s*3') -and
        ($finalConfig -match '"compression_ratio_threshold"\s*:\s*2\.0') -and
        ($finalConfig -match '"smart_split_with_vad"\s*:\s*false') -and
        ($finalConfig -match '"segment_merge"\s*:\s*\{[\s\S]*?"enabled"\s*:\s*false') -and
        ($finalConfig -match '"max_duration_ms"\s*:\s*0') -and
        ($finalWord -match 'install_word_timing_split_patch') -and
        ($finalWord -match '_matching_speech_span_end') -and
        ($finalInfer -match 'install_word_timing_split_patch')

    if (!$ok) {
        throw "更新后的本地文件未通过最终核对。"
    }

    foreach ($batName in @(
        "运行(翻译)(CPU).bat",
        "运行(翻译)(GPU).bat",
        "运行(翻译)(GPU)(输出到当前文件夹).bat",
        "运行(翻译)(GPU,低显存模式).bat",
        "运行(翻译)(GPU,高显存加速模式).bat"
    )) {
        $batPath = Join-Path $InstallRoot $batName
        $batText = Get-Content $batPath -Raw -Encoding UTF8
        if ($batText -notmatch '--sub_formats="srt"' -or $batText -match '--sub_formats="[^"]*(vtt|lrc)') {
            throw "$batName 未通过 SRT-only 最终核对。"
        }
    }

    Write-Host ""
    if ($Changed.Count -eq 0) {
        Write-Host "✅ 已经是最新方案，无需修改。" -ForegroundColor Green
    } else {
        Write-Host "✅ 更新完成：" -ForegroundColor Green
        foreach ($name in $Changed) {
            Write-Host "   - $name"
        }
        if ($null -ne $BackupDir) {
            Write-Host "备份位置：$BackupDir"
        }
    }
    Write-Host "✅ 当前本地配置与仓库 main 的字幕方案一致。" -ForegroundColor Green
    Write-Host "✅ 翻译模式只输出 SRT。" -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "❌ 更新失败：$($_.Exception.Message)" -ForegroundColor Red

    if ($BackedUp.Count -gt 0) {
        Write-Host "正在恢复本次更新前的文件..." -ForegroundColor Yellow
        foreach ($entry in $BackedUp) {
            if (Test-Path $entry.Backup) {
                Copy-Item $entry.Backup $entry.Original -Force
            }
        }
        Write-Host "✅ 已恢复。" -ForegroundColor Yellow
    }
    exit 1
}
finally {
    Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
