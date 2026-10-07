# Japanese video -> Simplified Chinese pipeline bridge

This bridge is the stable shallow integration boundary for SubtitleSyncTool.

## Entry point

`tools/run_japanese_to_chinese_pipeline.ps1 -JobConfigPath <job.json>`

The bridge keeps ChickenRice independently runnable. SubtitleSyncTool must not import ChickenRice ASR/CUDA/Hy-MT2 internals.

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

The default terminology still contains the verified correction `せーし -> 精子`.

## Progress protocol

The bridge writes normal human logs plus machine-readable lines prefixed with:

`@@CR_EVENT@@`

Consumers should parse only prefixed lines as JSON. Current events cover ASR start/reuse/done/failure, translation start/progress/done/failure, QC start/done/failure and final pipeline completion.

Stage 2 progress events include `completed`, `total` and `percent`. A resumed checkpoint also emits `resumed: true`, allowing the UI to restore progress immediately without parsing human log text.

Final QC runs before the Chinese SRT replaces the destination file. Hard failures include missing/empty translations, delimiter leakage, Markdown/code-fence leakage, obvious JSON payloads and model-explanation prefixes. Possible untranslated Japanese and extreme source/translation length ratios are warnings only, because legitimate names or unusual dialogue can otherwise create false positives. Timeline/index equality remains a hard invariant.

## Files

- `translate_srt_hymt2.ps1`: Stage 2 translator.
- `hymt2_prompt_config.example.json`: standalone Stage 2 prompt profile example.
- `run_japanese_to_chinese_pipeline.ps1`: one-job pipeline bridge.
- `pipeline_job.example.json`: bridge job example.

The bridge work directory is retained intentionally so a later style change can reuse Stage 1 output.
