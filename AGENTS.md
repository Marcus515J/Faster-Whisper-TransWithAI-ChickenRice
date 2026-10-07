# Faster-Whisper-TransWithAI-ChickenRice Fork 维护边界

## 项目身份

- 当前仓库：`Marcus515J/Faster-Whisper-TransWithAI-ChickenRice`
- 上游来源：`TransWithAI/Faster-Whisper-TransWithAI-ChickenRice`
- 本仓库是维护者独立维护的 Fork，继续独立开发、测试和发布；维护者已于 2026-10-07 明确进入与 `Marcus515J/SubtitleSyncTool` 的“海南鸡整合阶段”，当前只允许通过稳定 Bridge / 子进程契约做浅层调用。

## 严格隔离规则

即使两个项目都处理电影字幕，也不得自动把 `SubtitleSyncTool` 的以下内容带入本仓库：

- 需求与 Roadmap；
- Issues / PR / 分支；
- 参数与配置；
- 测试样本与测试结论；
- ASS 模板、双语合并或 Anchor 时间轴校准逻辑；
- 发布状态；
- 项目规则和验收标准。

同样，本仓库的 faster-whisper、VAD、word timing、翻译模式、生成参数、模型、测试和 Release 也不能自动当成 `SubtitleSyncTool` 的当前需求、依赖或 Provider。

技术关键词相似（例如 faster-whisper、字幕、翻译、SRT、VAD、GPU）不足以证明两个项目可以共享上下文。

## 开工前检查

任何 AI / Agent 在本仓库执行代码或 GitHub 操作前，先确认：

1. 当前仓库完整名称确实是 `Marcus515J/Faster-Whisper-TransWithAI-ChickenRice`；
2. 当前会话明确在讨论海南鸡 Fork，而不是 SubtitleSyncTool；
3. 当前任务来自本仓库自己的代码、Issue、PR、README 或维护者本轮明确指令；
4. 引用的参数和测试结果来自本仓库，而不是另一个字幕项目。

无法同时确认时，不得凭相似主题自动补齐关系。

## 当前与 SubtitleSyncTool 的整合边界

维护者已明确启动整合。当前方向不是把两个仓库合并，而是由 ChickenRice 暴露稳定 Bridge：Stage 1 生成日文 SRT，释放 ASR/GPU 后由 Stage 2 Hy-MT2 生成中文字幕；SubtitleSyncTool 只做浅层 UI 调用。

当前允许：

- 提供稳定 CLI / job JSON 契约；
- 提供机器可读阶段进度；
- 接受翻译角色、风格、影片背景和术语表；
- 缓存并复用 Stage 1 日文 SRT；
- 用源字幕、模型和 Prompt 指纹隔离 Stage 2 checkpoint；
- 提供独立的“可疑时间段短音频重新 ASR”Bridge：只对调用方传入的少量时间段截取音频并复用现有 Stage 1 日文模型做二次识别，结果只作为复核证据，不得直接修改缓存日文 SRT 或最终中文字幕。

当前仍禁止：

- 让本仓库依赖 SubtitleSyncTool 才能独立运行；
- 复制 SubtitleSyncTool 的 UI、Anchor、ASS 模板或双语合并实现进本仓库；
- 把模型、CUDA 运行时或本机缓存提交到另一个仓库；
- 因整合而自动共享两个项目未明确授权的参数、测试结论、Issue 或发布状态。


## v1.11+ 发布与长期恢复规则

- 正式 Release 版本由 `release/VERSION` 控制；合并对该文件的版本更新后，`.github/workflows/build-release-conda.yml` 自动构建、实测并发布。不要手工创建一个缺少二进制资产的同名 Release。 发布流水线本身失败、需要重跑同一版本时，只更新 `release/TRIGGER`；不得为了重试伪造新的版本号。
- “日文影片 → Hy-MT2 中文字幕”的推荐基础包是 `-transcribe`。所有 Bridge / Stage 2 小型脚本、恢复文档、模型清单必须随 Windows Release 包一起复制，不能只留在源码 `tools/`。
- 额外发布 `chickenrice_bridge_tools_<version>.zip` 作为零状态恢复入口，和 `chickenrice_stage2_runtime_win_cuda12.zip` 作为已验证 llama.cpp 便携 Runtime。
- Hy-MT2 Q8 等超大翻译模型不重复打入各 GPU 发行包；固定来源、大小、SHA-256 和已验证 llama.cpp 基线写在 `tools/stage2_runtime_manifest.json`，恢复脚本负责下载与校验。
- Stage 1 模型通过 `stage1.model_path`，Stage 2 模型通过 `stage2.model_path/model_name`，llama.cpp 通过 `stage2.llama_server_path` 替换。不得为了某次本机环境把这些路径写死进 GUI 或 Bridge 契约。
- 发布前必须让 Windows PowerShell 5.1 对 Bridge / 安装脚本做语法检查，并运行 Stage 2 / Bridge SelfTest；正式大模型运行仍以维护者实机验收为准。
- 从完全空白电脑恢复的正本说明是根目录 `长期恢复指南_日文转中文字幕.md`。涉及依赖、模型或发布布局变化时必须同步更新该文件。
