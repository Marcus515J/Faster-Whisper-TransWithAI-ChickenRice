# Stage 2 SRT text translation

This optional Windows-side stage translates a Japanese SRT into Simplified Chinese while locking the subtitle structure.

- Source indices and timestamp lines are preserved.
- Translation runs in batches through an OpenAI-compatible chat-completions API.
- Every batch is validated for exact target IDs before it is accepted.
- Completed batches are checkpointed so an interrupted run can resume without paying for completed batches again.
- Clearly non-verbal / meaningless ASR noise may translate to an invisible zero-width subtitle payload so the entry and timeline remain intact.
- Output defaults to `<source>.zh.srt`; the Japanese source file is never overwritten.

Files installed by `install_stage2_translation.ps1`:

- `translate_srt_api.ps1`
- `translate_srt_to_chinese.bat`
- `translation_api_config.json`
- `translation_api_config.example.json`

The config uses three fields: `base_url`, `model`, and `api_key`. Environment variables or interactive prompts can be used instead.


## Local Hy-MT2 path (v1.11+)

The generic API translator remains available, but the tested local path is `translate_srt_hymt2.ps1` + llama.cpp.

For packaged releases:

1. Run `setup_stage2_runtime.ps1`.
2. Use `run_full_pipeline_local.ps1` or the bundled full-pipeline BAT.

The tested dependency baseline is recorded in `stage2_runtime_manifest.json`. The Hy-MT2 GGUF is external because of its size; the runtime setup downloads and verifies it. A future compatible GGUF can be selected with `stage2.model_path` and `stage2.model_name` without changing Stage 1.
