# Faster-Whisper-TransWithAI-ChickenRice Fork 维护边界

## 项目身份

- 当前仓库：`Marcus515J/Faster-Whisper-TransWithAI-ChickenRice`
- 上游来源：`TransWithAI/Faster-Whisper-TransWithAI-ChickenRice`
- 本仓库是维护者独立维护的 Fork，当前与 `Marcus515J/SubtitleSyncTool` 完全分开开发、测试和发布。

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

## 未来与 SubtitleSyncTool 的关系

维护者长期希望把电影字幕相关功能尽量集中在一个软件中，但**现在不进行整合**。

只有当 `SubtitleSyncTool` 当前功能全部完成并稳定调试后，且维护者明确宣布进入新的“海南鸡整合阶段”，才允许重新审计两个仓库当时的稳定基线、许可、接口和迁移范围。

在那之前：

- 本仓库继续独立可运行、独立测试、独立发布；
- 不为了未来整合而提前重构本仓库；
- 不新增指向 SubtitleSyncTool 的运行时依赖；
- 不把 SubtitleSyncTool 的项目规则复制进本仓库；
- 不把本仓库的实现自动写入 SubtitleSyncTool。

未来整合必须由新的明确 Integration 任务启动，不能从历史对话或技术相似性推断已经授权。
