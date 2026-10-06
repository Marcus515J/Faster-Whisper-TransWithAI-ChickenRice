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
