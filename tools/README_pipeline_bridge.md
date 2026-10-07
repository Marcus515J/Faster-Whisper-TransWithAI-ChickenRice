# Japanese video -> Simplified Chinese pipeline bridge

This bridge is the stable shallow integration boundary for SubtitleSyncTool.

## Entry point

`tools/run_japanese_to_chinese_pipeline.ps1 -JobConfigPath <job.json>`

The bridge keeps ChickenRice independently runnable. SubtitleSyncTool must not import ChickenRice ASR/CUDA/Hy-MT2 internals.

## Fastest standalone use

For a packaged `-transcribe` release:

1. Run `setup_stage2_runtime.ps1` once. It installs the tested portable llama.cpp runtime and downloads/verifies the external Hy-MT2 model.
2. Drag one video/audio file onto `运行(日文转录+HyMT2中文字幕).bat`.

For a completely empty machine, download the small `chickenrice_bridge_tools_<version>.zip` release asset and run:

`install_full_pipeline.ps1 -InstallRoot <target-directory>`

The zero-state installer resolves the current release, downloads the matching NVIDIA transcribe package, then sets up Stage 2.

Exact tested external dependencies and checksums are stored in `stage2_runtime_manifest.json`. The Chinese long-term recovery guide in the release root is `长期恢复指南_日文转中文字幕.md`.

## Pipeline

```text
video/audio
  -> ChickenRice Stage 1 transcribe
  -> cached Japanese SRT
  -> Stage 1 process exits and releases GPU
  -> Hy-MT2 Stage 2
  -> Chinese SRT
  -> llama-server exits
```

Stage 1 cache identity is based on the source file identity plus the Stage 1 model/config/runtime settings. Translation style is deliberately excluded, so changing translation instructions reuses the Japanese SRT.

Stage 2 checkpoint identity includes the Japanese source text, model, prompt revision, role, style, film notes, terminology, batch size and short-segment mode. The complete fingerprint is also stored inside the checkpoint before it can be resumed.

## Translation profile

The job can contain `translation_profile` with:

- `system_role`: translator role and non-negotiable behavior.
- `style_prompt`: naturalness, register, subtitle wording and polishing preferences.
- `film_notes`: optional global context; the prompt explicitly forbids inventing facts from it.
- `terminology`: source/target term pairs.

Priority is fixed as:

`source fidelity + terminology > subtitle structure > style/polishing`

## Replaceable model/runtime contract

The integration intentionally does not hard-code one future model.

- Stage 1 model: `stage1.model_path`.
- Stage 2 GGUF: `stage2.model_path` + `stage2.model_name`.
- llama.cpp executable: `stage2.llama_server_path`.
- Server protocol: OpenAI-compatible `/v1/chat/completions`.

Changing the Stage 1 model invalidates the Stage 1 cache identity. Changing the Stage 2 model or prompt creates a different Stage 2 fingerprint, while the already cached Japanese SRT remains reusable.

The default terminology still contains the verified correction `せーし -> 精子`.

## Stage 1 handoff for caller-side review

The main `run_japanese_to_chinese_pipeline.ps1` job accepts an optional
`stop_after_stage1=true` field. When enabled, the bridge performs or reuses Stage 1,
emits `pipeline/stage1_ready` with the cached Japanese SRT path, and exits successfully
without starting Hy-MT2. This is intended for callers that need to inspect or
non-destructively review the Japanese SRT before the single official Stage 2 run.

The cached Stage 1 SRT itself is never modified by this option.

## Optional short-audio ASR review bridge

For post-ASR quality review, the packaged runtime also exposes:

`review_asr_segments.ps1 -JobConfigPath <job.json>`

This helper is deliberately separate from the main Stage 1 -> Stage 2 pipeline. It accepts the original media plus a small list of suspicious subtitle time ranges, extracts only those short audio windows with FFmpeg, loads the existing Stage 1 Japanese ASR model once, re-transcribes all candidate clips in one run, and emits machine-readable `asr_audio_review/*` events.

The helper never edits the cached Japanese SRT or the final Chinese SRT. Its output is second-opinion evidence for a caller such as SubtitleSyncTool. Consumers may combine that evidence with surrounding subtitles and a later text review, but must not treat it as ground truth.

Each suspicious cue is now re-transcribed twice in the same Whisper load: a wider context window (default 3.5 seconds before/after) and a tight target window (default 0.8 seconds before/after). The bridge returns both texts separately so the caller can prefer the tight evidence while still using the context pass for disambiguation. Temporary WAV/SRT work files are removed after a successful run unless `keep_work_files=true`.

## Progress protocol

The bridge writes normal human logs plus machine-readable lines prefixed with:

`@@CR_EVENT@@`

Consumers should parse only prefixed lines as JSON. Current events cover ASR start/reuse/done/failure, translation start/progress/done/failure, QC start/done/failure and final pipeline completion.

Stage 2 progress events include `completed`, `total` and `percent`. A resumed checkpoint also emits `resumed: true`, allowing the UI to restore progress immediately without parsing human log text.

Final QC runs before the Chinese SRT replaces the destination file. Hard failures include missing/empty translations, delimiter leakage, Markdown/code-fence leakage, obvious JSON payloads and model-explanation prefixes. Possible untranslated Japanese and extreme source/translation length ratios are warnings only, because legitimate names or unusual dialogue can otherwise create false positives. Timeline/index equality remains a hard invariant.

Existing Japanese/Chinese SRT pairs can be checked without loading Hy-MT2 by running `translate_srt_hymt2.ps1 -InputPath <ja.srt> -OutputPath <zh.srt> -QcOnly`. This emits the same `qc/*` machine events and never starts `llama-server`.

## Files

- `translate_srt_hymt2.ps1`: Stage 2 translator.
- `hymt2_prompt_config.example.json`: standalone Stage 2 prompt profile example.
- `run_japanese_to_chinese_pipeline.ps1`: one-job pipeline bridge.
- `review_asr_segments.ps1`: short-audio Japanese ASR second-opinion bridge for suspicious cue ranges.
- `pipeline_job.example.json`: bridge job example.

The bridge work directory is retained intentionally so a later style change can reuse Stage 1 output.
