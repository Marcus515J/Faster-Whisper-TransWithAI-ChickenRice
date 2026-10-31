# Faster-Whisper-TransWithAI-ChickenRice Fork 维护边界

## 执行者合同（无人值守派活，所有仓库通用）

> 本段在每个仓库的 AGENTS.md 里一字不差；要改，所有仓库一起改。与具体执行者无关，Codex、agy、DSH 或以后接入的执行者都照做。
> 优先级：用户当前明确指令 > 本 AGENTS.md（含本段）> git-workflow skill。本段只补「没人在场」时的做法，其余照 git-workflow。

指挥会在后台用命令行启动你，派活语只有一句：「读 GitHub Issue #N（仓库 owner/repo），按 Issue 正文完整执行」。这时**没有人能回答你的问题**。

1. **任务从哪来**：`gh issue view N --repo <owner/repo> --comments`。Issue 正文开头的「派活头」和后面的任务单是任务本身；评论里以「派活 第 X 次」开头的是指挥的后续指令，以最新一条为准，覆盖派活头里同名的字段。
2. **开工前先读**：git-workflow skill、本文件。
3. **要问的不等人**：git-workflow 里所有「停下问用户」的情况，不要停在等待输入的状态。把问题写清楚（看到了什么、为什么停、需要谁定什么）：已开 PR 的写进 PR 描述「5. 需要你做什么」，并在 PR 下发一条评论重复；还没开 PR 的写成 Issue 评论。写完就结束运行。
4. **D 级事项**：派活头或派活评论里「J 已拍板」写了原话的，按原话列的逐项做，不再停下问；原话以外的 D 级事项照第 3 条停下。
5. **合并**：只在最新派活评论写了「合并 PR #M」，且该 PR 最新一条指挥核对评论末行是「结论：通过，可合并」时合并。A 级照 git-workflow 自己合并。
6. **工作目录共用**：本地仓库只有一个工作目录，指挥和其他执行者都用它。不建 worktree（Issue 写了才建）。运行结束前切回开发主线、工作区干净（任务分支保留）。做不到就按第 3 条写明后结束。
7. **报错不绕**：额度用完、权限被拦、网络不通、找不到命令：不换办法、不改配置、不重试，把报错原文按第 3 条写下来后结束。
8. **汇报加一行**：PR 描述「3. 仓库状态」里加「执行者 / 模型 / 推理强度」：运行时能看到的照实抄；看不到的写「以派活参数为准，运行时无法确认」。
9. **最后一行输出**：PR 链接（没开 PR 就写 Issue 评论链接）加一句结论。指挥读你输出的末尾。

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
- 用源字幕、模型和 Prompt 指纹隔离 Stage 2 checkpoint。

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
