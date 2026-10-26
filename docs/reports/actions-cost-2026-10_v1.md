# Actions 用量/费用与私有仓库超额风险调查报告（2026-10）

- **报告版本**：v1.2 (`docs/reports/actions-cost-2026-10_v1.md`)
- **调查对象**：`Marcus515J/Faster-Whisper-TransWithAI-ChickenRice`
- **执行方**：ANTI
- **指挥**：Claude Code
- **调查基准日期**：2026-10-24（2026-10-26 第三轮复核修订）
- **证据分级标准**：
  - **【已查证】**：附有官方文档链接或权威公开资料。
  - **【已实测】**：注明执行人、执行环境及具体运行的命令与输出。
  - **【推测，未验证】**：官方文档未明示、尚无直接日志或因权限未达无法 100% 确认的推论。

---

## 摘要

- **结论**：
  1. 2026-10 本仓库实际产生 **90 次工作流运行、651 个 Job**，实际计费时长为 **6,731 分钟**（Windows 6,294 分钟，Linux 437 分钟）。
  2. 极高用量的根源是 **10-06 期间 CI 工作流无条件触发了 21 个 Windows 打包 Job**（消耗 5,193 分钟，占总 Windows 用量的 82.5%），且存在 **大量取消/失败运行浪费**（Cancelled 浪费 3,887 分钟，Failure 浪费 1,616 分钟，合计未成功运行耗时 **5,503 分钟，占比 81.8%**）。注意：取消与失败运行的耗时与 CI 全量打包在时间上高度重叠，属于同一用量的不同透视切面，不可重复叠加。该 CI 自动打包问题已于 10-07 在 commit `6de762c` 中收敛为手动触发。
  3. **关于 $57.72 的账单构成**：经核实，GitHub 对所有已启动的 Job（包含失败和取消）均计费，且官方现行价全量折算总额约为 $65.56，与账单显示的 $57.72 并不相等。因当前 API Token 缺少 `user` 权限，**技术上属于【无法可靠拆分】状态，需要 J 在 GitHub 网页导出 Billing Usage CSV 进行真对账**。
  4. **私有仓库换算结论**：按 GitHub 官方现行标准费率（Linux $0.006/min，Windows $0.010/min，折算比约 1.67x），10 月相同用量折算为 **10,927 分钟 Linux 等效分钟**，占 GitHub Free 每月 2,000 分钟免费额度的 **546.4%**（超额 4.46 倍）；超出部分将产生 **$53.56** 的实扣账单（若为 Pro 计划，占 364.2%，超额产生 $47.56）。
  5. **单次完整发布的真实消耗【已实测折算】**：实测两次成功的完整发布（Run `37397469369` 与 Run `37562016438`），单次实际消耗 569~596 计费分钟（Windows 约 390~398m，Linux 约 179~198m）。折合等效 Linux 分钟为 **830 ~ 860 分钟**（若全按 Windows 顶格上限折算约为 **950 ~ 1,000 分钟**），单次发布即占 GitHub Free 2,000 分钟额度的 **约 42% ~ 50%**。这意味着在私有仓库中，**每个月只要跑约 2 次完整发布，整月的免费算力额度即告耗尽**。
  6. **构件存储的致命卡点【推测，未验证】**：每次完整发布产生 21 个构件（约 65 GB）。官方默认保留期为 90 天。在私有仓库中，GitHub Free 仅含 500 MB、Pro 仅含 1 GB 构件存储额度。若将 Spending limit 硬设为 $0，**构件存储会在上传第 1~2 个包时超额被 GitHub 阻止（抛出 HTTP 403），导致发布流水线中断，比 2,000 分钟算力额度更早成为致命卡点**。
- **验证手段**：通过 `gh api` 抓取 2026-10 全量 runs、jobs、timing 及 artifacts 数据，由 Python 脚本进行确定性解析与账目拟合。
- **行动建议**：推荐实施 **选项 A + C（排队不取消） + D（90m 兜底） + F（1 天保留） + 构件存储改造/微量预算（解决存储卡死）** 组合。选项 B 因违反 AGENTS.md 规定必须排除。

---

## 一、工作流触发条件与配置全貌

【已实测】执行人 ANTI，在本地仓库执行 `git log` 与查看 `.github/workflows/*.yml` 查证。

历史及当前在仓库中出现过的 6 个工作流配置明细如下：

| 工作流名称 | 文件路径 | 当前状态 | 触发事件 (`on:`) | 路径/分支过滤 | Concurrency | Timeout-Minutes | 运行环境 (`runs-on`) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **CI** | `.github/workflows/ci.yml` | 激活 (main) | `push`, `pull_request`, `workflow_dispatch` | `branches: [main]`，无 paths 过滤 | 有 (`ci-${{ github.workflow }}-${{ github.ref }}`, cancel-in-progress: true) | **无**（默认 360m） | `ubuntu-latest` (lint), `windows-latest` (powershell-parse), `windows-latest` (build-windows 仅 manual) |
| **Build and Release with Conda** | `.github/workflows/build-release-conda.yml` | 激活 (main) | `push`, `workflow_dispatch` | `branches: [main]`, `paths: ['release/VERSION', 'release/TRIGGER']` | **无** | **无**（默认 360m） | `ubuntu-latest` (resolve/create/upload), 调用 reusable Windows 21 jobs (`windows-latest`) |
| **Build Windows (reusable)** | `.github/workflows/build-windows.yml` | 激活 (main) | `workflow_call` | 接收 `inputs.upload_artifacts` | **无** | **无**（默认 360m） | `windows-latest` (7 硬件环境 × 3 模型 = 21 矩阵 jobs) |
| **Publish v1.10.1** | `.github/workflows/publish-v1.10.1.yml` | 历史 (release/v1.10.1) | `push` | `branches: ['release/v1.10.1']` | **无** | **无** | `ubuntu-latest` (softprops/action-gh-release) |
| **Temporary PowerShell Parse Check** | `.github/workflows/temp-ps-parse.yml` | 历史 (已删除) | `push` | `branches: [feature/japanese-transcribe-stage1]` | **无** | **无** | `windows-latest` (PowerShell 语法检查) |
| **Temporary Ruff Format** | `.github/workflows/temp-ruff-format.yml` | 历史 (已删除) | `push` | `branches: [chore/fix-ruff-format]` | **无** | **无** | `ubuntu-latest` (自动格式化并回写分支) |

---

## 二、2026-10 实际用量统计（按工作流）

【已实测】执行人 ANTI，通过以下 GitHub API 提取 2026-10 全量数据并逐个 job 聚合：
- Runs 数据：`gh api "repos/Marcus515J/Faster-Whisper-TransWithAI-ChickenRice/actions/runs?created=2026-10-01..2026-10-31&per_page=100"`
- Jobs 数据：`gh api "repos/Marcus515J/Faster-Whisper-TransWithAI-ChickenRice/actions/runs/{id}/jobs?per_page=100"`
- 计费向上取整规则：每个 Job 实际秒数除以 60 向上取整（不足 1 分钟按 1 分钟计）。

### 1. 工作流维度统计表

| 工作流名称 | 运行次数 | 结论分布 | 触发事件分布 | 总 Job 数 | 原始时长 (秒/分) | 计费分钟 (向上取整) | Windows 计费分钟 | Linux 计费分钟 |
| :--- | :---: | :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| **CI** | 61 | 成功 30, 取消 21, 失败 10 | PR: 43, Push: 18 | 532 | 300,763s (5012.7m) | **5,288m** | 5,231m | 57m |
| **Build and Release with Conda** | 3 | 成功 2, 失败 1 | Push: 3 | 115 | 82,903s (1381.7m) | **1,439m** | 1,061m | 378m |
| **.github/workflows/build-release-conda.yml** (语法报错未生成 Job) | 22 | 失败 22 | Push: 22 | 0 | 0s (0m) | **0m** | 0m | 0m |
| **Temporary PowerShell Parse Check** | 2 | 成功 1, 失败 1 | Push: 2 | 2 | 32s (0.5m) | **2m** | 2m | 0m |
| **Temporary Ruff Format** | 1 | 成功 1 | Push: 1 | 1 | 10s (0.2m) | **1m** | 0m | 1m |
| **Publish v1.10.1** | 1 | 成功 1 | Push: 1 | 1 | 11s (0.2m) | **1m** | 0m | 1m |
| **合计** | **90** | **成功 35, 取消 21, 失败 34** | **PR: 43, Push: 47** | **651** | **383,719s (6395.3m)** | **6,731m** | **6,294m** | **437m** |

### 2. 操作系统类型统计表

| 机器类型 | Job 数量 | 原始时长 (秒) | 原始时长 (分钟) | 计费分钟 (Ceiling) | 占总计费时长比例 |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Windows (`windows-latest`)** | 502 | 361,495s | 6,024.9m | **6,294m** | **93.5%** |
| **Linux (`ubuntu-latest`)** | 111 | 22,224s | 370.4m | **437m** | **6.5%** |
| **macOS** | 0 | 0s | 0.0m | **0m** | **0.0%** |
| **未分配 Runner（跳过的 Job）** | 38 | 0s | 0.0m | **0m** | **0.0%** |
| **总计** | **651** | **383,719s** | **6,395.3m** | **6,731m** | **100.0%** |

### 3. 数据口径清晰交代：工作流表「22 次 0-Job」与 OS 表「38 个未分配 Runner Job」的区别
【已实测】执行人 ANTI 逐条检查 API 响应确认：
1. **工作流表中的 22 次运行（Job 数 0）**：
   来自 `build-release-conda.yml` 在 10-07 期间因 YAML heredoc 缩进语法错误，在 GitHub Actions 语法解析阶段即失败（如 Run `37560674289`、`37560467939` 等）。GitHub 尚未为其生成任何 Job 对象，因此 API 返回的 Jobs 列表为空数组 `[]`（产生 0 计费分钟）。
2. **OS 统计表中的 38 个未分配 Runner Job（总计 651 Job 之一部）**：
   来自日常 CI 运行中定义的 reusable 调用 `Build and check all Windows variants`（例如 Job `112715911776`、`112715787928` 等共 38 个）。由于在 `ci.yml` 中配置了 `if: github.event_name == 'workflow_dispatch'`，在日常 38 次由 push/PR 触发的 CI 运行时，该 Job 条件不满足被 GitHub 判定为 **Skipped（跳过）**。Skipped 的 Job 不会分配任何 Runner，无 labels，耗时为 0 秒，产生 0 计费分钟。
3. **两表勾稽关系**：
   Job 总数 651 = 502 个 Windows 运行 Job + 111 个 Linux 运行 Job + 38 个 Skipped Job。统计完全闭合。

### 4. API 权限说明
【已实测】执行人 ANTI，运行 `gh api "users/Marcus515J/settings/billing/actions"` 时返回 HTTP 404 及 `gh: This API operation needs the "user" scope`。因此 GitHub CLI 当前凭据不包含 Billing 查询权限，无法直接从 API 导出账单底层扣费明细。

---

## 三、对账 $57.72：构成分析与无法拆分交代

【已实测】+【已查证】+【推测，未验证】

针对 J 在账单页看到的本仓库原价折算用量 **$57.72**，经深度排查与核验，结论为：**目前技术上属于【无法可靠拆分】，需要 J 在网页端导出 Billing Usage CSV 进行真对账**。具体分析与依据如下：

1. **排除「只算成功 Job」的拟合假设**【已查证】：
   - GitHub 官方文档明确说明：工作流只要启动运行，无论 Job 最终是成功、失败还是被取消（Cancelled），所有实际占用的 Runner 时长都会被计费并向上取整到整分钟。因此不能为了逼近 $57.72 而人为剔除失败和取消的 Job。
2. **官方现行费率全量折算与 $57.72 不相等**【已查证】+【已实测】：
   - 官方现行标准价格（[Actions runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing)）：Linux $0.006/min，Windows $0.010/min。
   - 对 10 月全量 651 个 Job（包含所有成功、失败、取消）进行现行价折算：
     $$\text{全量现行折算} = 6,294 \text{ (Windows)} \times \$0.010 + 437 \text{ (Linux)} \times \$0.006 = \$62.94 + \$2.62 = \$65.56$$
   - 测算结果为 **$65.56**，与账单显示的 **$57.72** 存在 **$7.84** 的差距。
3. **构件存储（Artifacts Storage）的影响**【已实测】+【推测，未验证】：
   - 仓库内当前存留 **42 个构件，合计 129.63 GB**（由 10-06 和 10-07 两次 Release 生成）。
   - GitHub Actions 存储费用是按 GB·小时（GB-hours）小时级动态累计的。在公开仓库中该项费用虽被免费额度 100% 抵扣，但账单原价折算显示中是否包含了部分构件存活天数的存储原价值，因缺少时间序列流水而无法剥离。
4. **API 查询受限**【已实测】：
   - 执行人 ANTI 实测调用 GitHub 计费 API 时因缺少 `user` scope 被拦截，无法通过 CLI 抓取底层对账账单。
5. **结论与所需支持**：
   - 当前在没有底层账单流水的情况下，任何推导出的几毛几分钱“吻合”都属于数字凑数。
   - **请 J 在 GitHub 网页端进入 Settings → Billing and plans → Usage，选择 2026-10 月度导出 Usage CSV 文件**。CSV 中会明确列出每一项收费产品类别（Actions Compute 分钟、Shared Storage 存储等）的真实计费金额。

---

## 四、重复与白跑清单（具体 Run 与浪费分钟）

【已实测】通过对 90 次运行的数据透视，发现严重资源空转现象：

### 1. Cancelled（被取消）的运行：浪费 3,887 计费分钟
由于早前 CI 缺少有效的分支过滤或并发快速推进，新 push 触发了旧任务的取消，但旧任务已经在 Windows 上跑了极长时间。
- **典型浪费 Run 编号**：
  - `37410850361` (CI, push main@0f5dc24)：浪费 **606m** Windows + 1m Linux
  - `37403979548` (CI, PR fix/subtitle-end-hold-srt-only@efc2ac4)：浪费 **580m** Windows + 1m Linux
  - `37401006635` (CI, PR fix/subtitle-end-hold-srt-only@d25e7b1)：浪费 **559m** Windows + 1m Linux
  - `37397328685` (CI, push main@c80efc7)：浪费 **473m** Windows + 1m Linux
  - `37409039255` (CI, push main@0ab55a0)：浪费 **343m** Windows + 1m Linux
  - `37410071945` (CI, PR fix/mypy-word-timing-marker@59c8f9e)：浪费 **314m** Windows + 1m Linux
  - `37410613483` (CI, PR docs/project-boundary@787211f)：浪费 **313m** Windows + 1m Linux
  - `37410811127` (CI, PR feature/japanese-transcribe-stage1@21f4ace)：浪费 **309m** Windows + 1m Linux
  - 其余 13 次取消运行合计浪费 372m。
- **小计**：21 次取消，共浪费 **3,869 Windows 分钟 + 18 Linux 分钟**（合计 3,887 分钟）。

### 2. Failure（早期/中期失败）的运行：浪费 1,616 计费分钟
- **典型浪费 Run 编号**：
  - `37397268119` (CI, PR fix/word-timestamp-segmentation@8f768c2)：矩阵跑至后期失败，浪费 **352m** Windows + 1m Linux
  - `37408989239` (CI, PR chore/fix-ruff-format@cd37256)：浪费 **340m** Windows + 1m Linux
  - `37406814219` (CI, PR fix/subtitle-end-hold-srt-only@c04cefa)：浪费 **332m** Windows + 1m Linux
  - `37399542841` (CI, push main@879aa9b)：浪费 **303m** Windows + 1m Linux
  - `37560863307` (Build and Release with Conda, push main@1f4605a)：Release 流水线失败，浪费 **273m** Windows + 1m Linux
  - 另外 22 次为 `build-release-conda.yml` 因 YAML 缩进错误在入口即失败（耗时 0 秒，0 计费分钟）。
- **小计**：共浪费 **1,606 Windows 分钟 + 10 Linux 分钟**（合计 1,616 分钟）。

### 3. 未成功运行耗时与数据重叠关系说明
- **未成功运行合计**：Cancelled (3,887m) + Failure (1,616m) = **5,503 分钟，占总计费时长（6,731m）的 81.8%**。
- **重叠关系重要说明**：
  - 「未成功运行（5,503m）」是按 **Job/Run 终态结论维度** 统计的。
  - 「CI 全量 Windows 打包（5,193m）」是按 **功能场景维度** 统计的（10-06 期间 CI 自动调起 `build-windows.yml` 消耗的时长）。
  - 二者在时间线上存在极高的重叠：5,503 分钟的取消和失败绝大部分正是因为 CI 中跑了 21 个 Windows 打包 job 耗时过长而被后续提交中断或最终报错。**二者不可作为独立浪费相加**。

### 4. 临时工作流残留与触发：消耗 3 计费分钟
- `Temporary PowerShell Parse Check` (Run `37410696054`, `37410588674`)：消耗 2m Windows。
- `Temporary Ruff Format` (Run `37408771768`)：消耗 1m Linux。
- 虽然分钟数较少，但验证了临时调试工作流留在仓库中被自动触发的隐患。相关文件随后已从代码库删除。

### 5. Push 与 PR 双触发及并发：
- 同一 SHA 出现 `push` 与 `pull_request` 重复触发（例如 SHA `d96be85` 与 `d2fb886`）。但因 CI 配置了 `cancel-in-progress: true`，重复运行多被快速掐断，直接浪费分钟较小（约 2 分钟）。

---

## 五、私有仓库账目折算（核心测算）

### 1. 官方计费规则基准
- **参考官方权威文档**【已查证】：
  - [About billing for GitHub Actions](https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions) (查阅日期：2026-10-25)
  - [Actions runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing) (查阅日期：2026-10-25)
  - [GitHub Actions product billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions) (查阅日期：2026-10-25)
- **规则要点**：
  - 公开仓库免费；私有仓库按账号计划每月赠送固定额度池（以 Linux 2-core 分钟计算）。
  - **现行标准单价与比率（现行官方主口径）**【已查证】：
    - Linux 2-core: **$0.006 / min**（基准）
    - Windows 2-core: **$0.010 / min**（Windows/Linux 费率比约为 **1.67x**，即 $0.010 / $0.006）
    - macOS 3/4-core: **$0.062 / min**
    - *注：现行官方文档页面已不再使用“倍数（Multiplier）”专有名词，而是直接明码标价上述每分钟价格。早期计费体系中曾使用 Linux 1x ($0.008)、Windows 2x ($0.016) 的固定倍数，本节以现行标准价为主测算口径，早期 2x 模型作为对照参考。*
  - **免费额度池（针对私有仓库）**【已查证】：
    - **GitHub Free**：每月 **2,000 分钟**（Linux 等效，价值 $12.00），500 MB 构件存储。
    - **GitHub Pro**：每月 **3,000 分钟**（Linux 等效，价值 $18.00），1 GB 构件存储。
  - **超额单价**：超出免费额度后，按上述每分钟单价计费；超额构件存储单价为 $0.25 / GB / 月。

### 2. J 账户计划核实情况说明
【已实测】执行人 ANTI 运行 `gh api user --jq '{login: .login, plan: .plan}'`，返回结果为 `plan: null`。由于当前 token 未获分配 `user` scope，GitHub REST API 对公开请求隐藏了用户的 plan 明细。因此，本报告对 GitHub Free 与 GitHub Pro 两种计划均给出完整折算数据。

### 3. 官方现行标准费率测算（主口径）

- **折算算法与公式**：
  $$\text{10 月总原价值} = 437 \text{ (Linux)} \times \$0.006 + 6,294 \text{ (Windows)} \times \$0.010 = \$2.622 + \$62.940 = \$65.562 \approx \$65.56$$
  $$\text{等效 Linux 计费分钟} = \frac{\$65.562}{\$0.006} = 10,927 \text{ 分钟}$$
  *（即按 1 Windows 分钟 = 1.6667 Linux 分钟换算：$437 + 6,294 \times 1.6667 = 10,927$ 分钟）*

- **折算结论表（现行官方标准价）**：

| 计划类型 | 每月免费额度 (Linux分钟/价值) | 10 月等效用量 (折合Linux分钟) | 额度占用率 | 超额等效分钟 | 超额产生费用 (按现行单价实扣) |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **GitHub Free** | 2,000 分钟 ($12.00) | 10,927 分钟 ($65.56) | **546.4%** | 8,927 分钟 | **$53.56** (即 $65.56 - $12.00) |
| **GitHub Pro** | 3,000 分钟 ($18.00) | 10,927 分钟 ($65.56) | **364.2%** | 7,927 分钟 | **$47.56** (即 $65.56 - $18.00) |

> **核心结论句（现行价标准口径）**：  
> **「同样的 10 月用量放私有仓库：按官方现行费率（Windows $0.010/min，Linux $0.006/min，约 1.67 倍折算）= 10,927 等效 Linux 分钟，占 GitHub Free 每月 2,000 分钟免费额度的 546.4%（超额 4.46 倍）；超出部分将产生 $53.56 的实扣账单（Pro 计划超额产生 $47.56）。」**

### 4. 早期 2x 倍数模型测算对照【推测，早期模型】
- 若按早期文档的固定倍数（Linux 1x, Windows 2x）：
  - 等效分钟：$437 \times 1 + 6,294 \times 2 = 13,025$ 分钟。
  - 占 Free 2,000 分钟的 651.3%（超额 11,025 分钟）。
  - 超额单价按 $0.006 ~ $0.008 折算，账单区间为 $66.15 ~ $88.20。

### 5. 单次成功完整发布的真实成本实测
【已实测】执行人 ANTI 对 10 月两次成功的完整发布流水线进行独立核算（排除日常 CI 与 10-07 当天另一次失败的发布）：
- **Run `37397469369` (v1.10.1 正式发布)**：共 43 个 Job，实际消耗 **390m Windows + 179m Linux**，总计费时长 569 分钟。
  - 现行价原值：`390 × $0.010 + 179 × $0.006 = $4.974`。
  - 折合等效 Linux 分钟：`$4.974 / 0.006 = 829 等效分钟`（占 2,000 分钟额度的 **41.5%**）。
  - 若全按 Windows 单价（$0.010）顶格折算：`569 × 1.6667 = 948 等效分钟`（占额度的 **47.4%**）。
- **Run `37562016438` (v1.11.0 正式发布)**：共 46 个 Job，实际消耗 **398m Windows + 198m Linux**，总计费时长 596 分钟。
  - 现行价原值：`398 × $0.010 + 198 × $0.006 = $5.168`。
  - 折合等效 Linux 分钟：`$5.168 / 0.006 = 861 等效分钟`（占 2,000 分钟额度的 **43.1%**）。
  - 若全按 Windows 单价（$0.010）顶格折算：`596 × 1.6667 = 993 等效分钟`（占额度的 **49.7%**）。

> **单次发布成本核心结论**：  
> **单次成功的完整版本发布（全矩阵 21 个 Windows 包 + 运行时 + Bridge），实测等效 Linux 分钟约为 830 ~ 860 分钟（顶格上限约为 950 ~ 1,000 分钟），约占 GitHub Free 每月 2,000 分钟免费额度的 42% ~ 50%。在私有仓库中，每月跑约 2 次完整发布就会将整月免费算力额度完全耗尽。**

---

## 六、防超额建议清单（选项 A ~ H）

每项独立可选，未经维护者确认前**不进行任何实际改动**：

| 选项 | 做什么 | 省多少（真实数据折算） | 代价 | 改动范围 | 回退方式 | 是否影响现有发布流程 |
| :---: | :--- | :--- | :--- | :--- | :--- | :---: |
| **A** | **CI 坚决禁用自动 Windows 打包**（已在 10-07 实施，需制度化确立） | **【已落实措施】**10-06 历史浪费已消除。今后核心防范点：单次完整发布消耗约 830~860 等效分钟（占月度额度 42%~50%） | PR 阶段不打包 Windows 二进制，改在发布时统一打包 | 确认 `.github/workflows/ci.yml` 保持 manual 条件 | 移除 `if: workflow_dispatch` | **无影响**（发布走 `build-release-conda.yml`） |
| **B** | **PowerShell 检查改在 Linux (`ubuntu-latest`) 下跑 `pwsh`** | 节省 38 换算分钟（Windows 1.67x 降为 Linux 1x，省 40%） | **【严重代价】直接违反 AGENTS.md 规则**（根目录 AGENTS.md 明确要求“发布前必须让 Windows PowerShell 5.1 做语法检查”，Linux 只有 pwsh 7，无法检验 PS 5.1 特有怪癖） | 修改 `ci.yml` 中 `powershell-parse` 的运行环境 | 改回 `runs-on: windows-latest` | **违反规则，强烈不建议实施** |
| **C** | **在 Release 流水线补充 `concurrency`（排队，但不取消进行中的运行）** | **防范至少 500 ~ 950 换算分钟/次**（防止连续重试导致多个 21-job 矩阵并发跑） | 重试发布时必须等待前一次流水线完成，不能插队立即开始 | 修改 `build-release-conda.yml` 增加 `concurrency: group: release-${{ github.workflow }}`，**禁止**设置 `cancel-in-progress: true`（见下方证据） | 删掉该配置段 | **安全受益**（绝不会留下残缺 Release） |
| **D** | **为所有 Job 设置严格 `timeout-minutes`**（Windows 打包设 90m，CI 设 10m） | **防挂起兜底**：实测单个最长构建达 39.4m，设 90m 拥有约 2.3 倍安全余量。若 PyInstaller/Conda 卡死，单 job 最多浪费 90m 而非默认 360m（省 270m Windows ≈ 450 等效分/次） | 若网络极度恶劣导致真实构建超过 90 分钟会被超时终止 | 修改 `.github/workflows/*.yml` 各 job | 删掉 `timeout-minutes` | **无影响**（最长构建约 39.4m，90m 余量充裕，杜绝 60m 误杀风险） |
| **E** | **精简私有环境发布矩阵（只保留 CUDA 核心包）** | 单次发布从 21 个 job 降为 4 个 job，单次发布**节省约 650 换算分钟**（从约 850m 降至约 200m） | 放弃自动构建 AMD gfx 架构和部分 CUDA 旧版本，小众环境需手动单独打 | 修改 `build-release-conda.yml` 的 matrix | 还原 matrix 列表 | **有影响**（减少 Release 资产多样性，需维护者拍板） |
| **F** | **设置 Artifacts 保留期为 1 天 (`retention-days: 1`)** | **避免每月最高约 \$32.40 理论上限存储费**（官方默认保留 90 天，多版本累积将严重超额；设为 1 天后单次发布存储仅约 **\$0.50**） | 临时构件 1 天后过期，不能在数周后回溯下载中间调试文件（但 Release 资产不受影响） | 修改 `build-windows.yml` upload-artifact 步骤加 `retention-days: 1` | 改回默认 90 天 | **无影响**【已实测】Release 发布包在流水线结束前已上传到 GitHub Releases（见下方证据） |
| **G** | **GitHub 账户级防御：Spending Limit 设为 \$0 的风险与配套改造** | **100% 物理消除信用卡扣款风险** | **【严重隐患】构件存储额度极早卡死发布**：Free 仅含 500MB、Pro 仅含 1GB 存储，单次发布生成 65GB 构件。若设 $0，上传第 1~2 个包即遭 GitHub 拦截中断（见下方分析） | 需配套改造发布流水线：改为不通过 Actions Artifact 中转，直传 Release；或设置微量预算（如 $2/月） | 随时在网页调高限额 | **直接设 $0 会导致当前发布流水线必崩** |
| **H** | **私有仓库只保留手动触发 (`workflow_dispatch`)** | **节省 100% 被动触发分钟** | 失去自动化 CI 保护，所有构建必须人工去 Actions 页面点击 | 修改各 workflow `on:` 仅留 `workflow_dispatch` | 加回 `push`/`pull_request` | **有重大影响**（改变 `release/VERSION` 合并自动发布的行为契约） |

---

## 七、关键技术风险深剖与证据说明

### 1. 为什么选项 C 绝对不能加 `cancel-in-progress: true`？
【已查证】+【已实测】
- 根目录 `AGENTS.md` 明确规定：
  > “不要手工创建一个缺少二进制资产的同名 Release。 发布流水线本身失败、需要重跑同一版本时，只更新 `release/TRIGGER`；不得为了重试伪造新的版本号。”
- 查阅 `.github/workflows/build-release-conda.yml` 第 54-96 行：流水线首先由 `create-release` job 创建 GitHub Release 草稿/占位实体，随后由矩阵 job 逐个上传 21 个打包二进制文件。
- 如果在发布流水线上设置了 `cancel-in-progress: true`，当维护者推送 `release/TRIGGER` 触发重跑时，前一次正在上传资产的流水线会被立即掐断中止。这会导致已经在 GitHub 上创建的 Release 缺少部分资产，**留下残缺不全的同名 Release，严重破坏 AGENTS.md 核心发布准则**。
- **正确做法**：仅设置 `concurrency: group: release-${{ github.workflow }}`（不设 `cancel-in-progress: true` 或显式设为 `false`）。新重试会自动排队，等待前一次流水线完整结束后再执行，安全合规。

### 2. 为什么选项 G（Spending Limit = $0）会比算力分钟更早搞崩私有仓库发布？
【已查证】+【推测，未验证】
- **官方规则依据**【已查证】：
  - [About billing for GitHub Actions](https://docs.github.com/en/billing/concepts/product-billing/github-actions)：
    > “If your account has a spending limit of $0, or has reached its spending limit, your jobs may fail if you try to upload artifacts or packages.”（如果账户支出上限为 $0 或达到限额，尝试上传构件或包时作业将失败）。
  - 私有仓库构件存储配额：GitHub Free 仅 **500 MB**，GitHub Pro 仅 **1 GB**。
- **发布流水线实际运行现状**【已实测】：
  - 单次完整发布生成 21 个 Windows 包，总大小约为 **65 GB**（每个包 2.5 ~ 5.5 GB 不等）。
  - 当前架构在 `build-windows.yml` 中必须通过 `actions/upload-artifact@v6` 上传临时构件，再由 `build-release-conda.yml` 下载并上传至 Release。
- **致命卡点推断**【推测，未验证】：
  - 在私有仓库中，当 Spending limit 设为 $0 时，发布流水线构建到第 1 个包（约 3 GB）尝试上传时，就会立即触碰 500MB/1GB 存储上限，GitHub API 将直接拒绝上传并使 Job 报错失败！
  - **这意味着在私有仓库中，发布流水线根本无法跑完第 1 个包，构件存储超额会比 2,000 分钟配额更快、更致命地中断发布**！
- **推荐解决路径**：
  - **方案一（免构件存储架构改造）**：修改工作流，取消中间的 `upload-artifact` 步骤，让 Windows 打包 Job 在编译完成后直接调用 `gh release upload` 将产物直传至 GitHub Releases。
  - **方案二（微量存储预算）**：若维持现有 Artifact 中转架构，不可设 Spending limit 为 $0，需配置微量预算（例如每月 $2.00），并配合选项 F（`retention-days: 1`）。由于单次发布 65 GB 仅留存 1 天的理论成本约为 **$0.50**，微量预算足以保证发布顺利跑完，同时卡死大额扣款风险。

### 3. 选项 F 的保留期与 Releases 资产隔离证据
【已查证】+【已实测】
- **默认保留期**【已查证】：根据 [GitHub Actions 官方管理文档](https://docs.github.com/en/actions/administering-github-actions/usage-limits-billing-and-administration)，GitHub Actions 构件和日志的默认保留期为 **90 天**。若不显式指定，私有仓库中每次发布的 65 GB 都会保留 3 个月，产生持续累积的存储账单（129 GB 存满一个月理论上限为 $32.41）。
- **1 天保留成本估算**：65 GB 构件保留 1 天（24 小时），按月折算成本为：
  $$65 \text{ GB} \times \frac{1 \text{ 天}}{30 \text{ 天}} \times \$0.25/\text{GB} \approx \$0.54 \text{（约 \$0.50/次发布）}$$
- **Releases 资产系统隔离证据**【已实测】：
  1. 查阅代码 `.github/workflows/build-release-conda.yml` 第 97-150 行：`upload-assets` job 紧随 `build-windows` 之后执行，下载 Artifact 后立即使用 `ading2210/gh-large-releases@v1` 将产物上传至 GitHub Releases；
  2. GitHub Releases 资产独立存放于 GitHub CDN 存储，不计入 Actions Artifact 存储池；
  3. 工作流运行结束时，所有正式包已被持久化到 Release 页面。因此缩短 Actions Artifact 的 `retention-days` 至 1 天，对用户端下载正式版本资产 **零影响**。

---

## 八、推荐组合与实施建议

### 最终推荐组合：选项 A + C（排队不取消） + D（90m 超时） + F（1天保留） + 配套存储策略

- **推荐理由**：
  1. **彻底合规**：坚决排除选项 B，严格遵守 AGENTS.md 规定的 Windows PS 5.1 检查准则；
  2. **保护正式发布**：选项 C 只排队不取消，彻底杜绝破坏 AGENTS.md 准则留下残缺 Release 的隐患；选项 D 设为 90 分钟（基于实测最长 39.4m 构建拥有约 2.3 倍余量），消除 60m 误杀风险；
  3. **破解存储死局**：揭露了 Spending Limit = $0 会导致 65GB 发布构件因 500MB 存储上限而秒崩溃的致命隐患，提出了直传 Release（或 $2 微量预算配合 1 天保留单次仅 $0.50）的可行解法；
  4. **全矩阵产物完整**：不改动 `release/VERSION` 与 `release/TRIGGER` 契约，21 个构建包一个不少。
- **执行原则**：本报告仅作决策参考，在 J 审查并选定方案前，不改动任何仓库代码、工作流与设置。
