# Actions 用量/费用与私有仓库超额风险调查报告（2026-10）

- **报告版本**：v1.0 (`docs/reports/actions-cost-2026-10_v1.md`)
- **调查对象**：`Marcus515J/Faster-Whisper-TransWithAI-ChickenRice`
- **执行方**：ANTI
- **指挥**：Claude Code
- **调查基准日期**：2026-10-24
- **证据分级标准**：
  - **【已查证】**：附有官方文档链接或权威公开资料。
  - **【已实测】**：注明执行人、执行环境及具体运行的命令与输出。
  - **【推测，未验证】**：尚无直接日志或因权限未达无法 100% 确认的推论。

---

## 摘要

- **结论**：
  1. 2026-10 本仓库实际产生 **90 次工作流运行、651 个 Job**，实际计费时长为 **6,731 分钟**（Windows 6,294 分钟，Linux 437 分钟）。
  2. 极高用量的根源是 **10-06 期间 CI 工作流无条件触发了 21 个 Windows 打包 Job**（消耗 5,193 分钟，占总 Windows 用量的 82.5%），且存在 **大量取消/失败运行浪费**（Cancelled 浪费 3,869 分钟，Failure 浪费 1,606 分钟，合计无效浪费占比 **81.3%**）。该问题已于 10-07 在 commit `6de762c` 中将 CI 打包收敛为手动触发。
  3. **私有仓库换算结论**：按 GitHub 官方规则（Windows 2x 倍数），10 月相同用量折合为 **13,025 分钟 Linux 等效分钟**，占 GitHub Free 每月 2,000 分钟免费额度的 **651.3%**（超额 5.51 倍）；超出部分将产生 **$66.15 ~ $88.20** 的实扣账单。
  4. 此外，10 月两次 Release 共生成 **42 个构件，总计 129.63 GB 存储**，在私有仓库中若未设置短期自动清理，每月将产生约 **$32.40** 的超额存储费用。
- **验证手段**：通过 `gh api` 抓取 2026-10 全量 runs、jobs、timing 及 artifacts 数据，由脚本进行确定性解析与账目拟合。
- **行动建议**：推荐实施 **选项 A + C + D + F + G** 组合，在不改动现有 `release/VERSION` 发布契约与产物完整性的前提下，将私有仓库超额风险降至 **0**。

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
| **.github/workflows/build-release-conda.yml** (语法报错未起 job) | 22 | 失败 22 | Push: 22 | 0 | 0s (0m) | **0m** | 0m | 0m |
| **Temporary PowerShell Parse Check** | 2 | 成功 1, 失败 1 | Push: 2 | 2 | 32s (0.5m) | **2m** | 2m | 0m |
| **Temporary Ruff Format** | 1 | 成功 1 | Push: 1 | 1 | 10s (0.2m) | **1m** | 0m | 1m |
| **Publish v1.10.1** | 1 | 成功 1 | Push: 1 | 1 | 11s (0.2m) | **1m** | 0m | 1m |
| **合计** | **90** | **成功 35, 取消 21, 失败 34** | **PR: 43, Push: 47** | **651** | **383,719s (6395.3m)** | **6,731m** | **6,294m** | **437m** |

### 2. 操作系统类型统计

| 机器类型 | Job 数量 | 原始时长 (秒) | 原始时长 (分钟) | 计费分钟 (Ceiling) | 占总计费时长比例 |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Windows (`windows-latest`)** | 502 | 361,495s | 6,024.9m | **6,294m** | **93.5%** |
| **Linux (`ubuntu-latest`)** | 111 | 22,224s | 370.4m | **437m** | **6.5%** |
| **macOS** | 0 | 0s | 0.0m | **0m** | **0.0%** |
| 未启动 Job (语法错误) | 38 | 0s | 0.0m | 0m | 0.0% |
| **总计** | **651** | **383,719s** | **6,395.3m** | **6,731m** | **100.0%** |

### 3. API 权限说明
【已实测】执行人 ANTI，运行 `gh api "users/Marcus515J/settings/billing/actions"` 时返回 HTTP 404 及 `gh: This API operation needs the "user" scope`。因此 GitHub CLI 当前凭据不包含 Billing 查询权限，无法直接从 API 导出账单底层扣费明细。

---

## 三、对账 $57.72：构成分析与拆解

【已实测】+【推测，未验证】
在账单页中，$57.72 是 GitHub 给出的该仓库 10 月原价值（Gross Amount）。我们通过多重模型拟合还原其来源：

1. **Successful Jobs 原价折算模型（拟合度极高：$56.70 vs $57.72）**：
   - 官方标准单价【已查证】：Linux $0.008/分钟，Windows $0.016/分钟。
   - 10 月份全部成功运行的 Job（Successful jobs）计费分钟为：Windows 3,333 分钟，Linux 421 分钟。
   - 原价折算：`3,333 × $0.016 + 421 × $0.008 = $53.328 + $3.368 = $56.696 ≈ $56.70`。
   - 与账单显示 $57.72 **仅差 $1.02**。该 $1.02 的极小差额通常由部分在 cancelled/failure 中已完成前置 step 但状态被标为未成功的 job，或特定时长阶梯取整所构成。
2. **构件存储（Artifacts Storage）排查**：
   - 【已实测】调用 `gh api repos/Marcus515J/Faster-Whisper-TransWithAI-ChickenRice/actions/artifacts` 发现当前保留有 **42 个构件，合计 129.63 GB**。
   - 【已查证】对于公开仓库（Public Repository），Actions 分钟与 Artifact 存储均为免费（免除计费）。但账单系统在统计原始用量价值时，若计入存储（按 $0.25/GB/月 折算），129 GB 存活数天的折算价值亦在几美元区间。
3. **结论与建议**：
   - $57.72 主要由 **Windows Runner 原价（$0.016/min）折算** 构成，并非只有 Actions 免费额度内的那几美元。
   - 若需精确到美分的项目分类拆分（区分 Actions Compute 分钟 vs Storage），请 J 在 **GitHub Settings → Billing & Plans → Usage** 页面导出 2026-10 的 Usage CSV 对账。

---

## 四、重复与白跑清单（具体 Run 与浪费分钟）

通过对 90 次运行的数据透视，发现严重资源空转现象：

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
- **小计**：21 次取消，共浪费 **3,869 Windows 分钟 + 18 Linux 分钟**。

### 2. Failure（早期/中期失败）的运行：浪费 1,616 计费分钟
- **典型浪费 Run 编号**：
  - `37397268119` (CI, PR fix/word-timestamp-segmentation@8f768c2)：矩阵跑至后期失败，浪费 **352m** Windows + 1m Linux
  - `37408989239` (CI, PR chore/fix-ruff-format@cd37256)：浪费 **340m** Windows + 1m Linux
  - `37406814219` (CI, PR fix/subtitle-end-hold-srt-only@c04cefa)：浪费 **332m** Windows + 1m Linux
  - `37399542841` (CI, push main@879aa9b)：浪费 **303m** Windows + 1m Linux
  - `37560863307` (Build and Release with Conda, push main@1f4605a)：Release 流水线失败，浪费 **273m** Windows + 1m Linux
  - 另外 22 次为 `build-release-conda.yml` 因 YAML 缩进错误在入口即失败（耗时 0 秒，0 计费分钟）。
- **小计**：共浪费 **1,606 Windows 分钟 + 10 Linux 分钟**。

### 3. CI 中放置全量 Windows 打包 Matrix（历史配置缺陷）：浪费 5,193 计费分钟
- 10-06 期间，`ci.yml` 每次 push/PR 都会无条件调起 `build-windows.yml` 的 21 个 Windows 打包 job。
- 统计显示，仅 CI 中的 Windows 打包 Job 就消耗了 **5,193 分钟**（占 CI 总耗时的 98.2%）。
- 该问题已于 10-07 在 commit `6de762c` 中修复（收敛为 `if: github.event_name == 'workflow_dispatch'`）。

### 4. 临时工作流残留与触发：消耗 3 计费分钟
- `Temporary PowerShell Parse Check` (Run `37410696054`, `37410588674`)：消耗 2m Windows。
- `Temporary Ruff Format` (Run `37408771768`)：消耗 1m Linux。
- 虽然分钟数较少，但验证了临时调试工作流留在仓库中被自动触发的隐患。相关文件随后已从代码库删除。

### 5. Push 与 PR 双触发及并发：
- 同一 SHA 出现 `push` 与 `pull_request` 重复触发（例如 SHA `d96be85` 与 `d2fb886`）。但因 CI 配置了 `cancel-in-progress: true`，重复运行多被快速掐断，直接浪费分钟较小（约 2 分钟）。

---

## 五、私有仓库账目折算（核心测算）

### 1. 官方计费规则基准
- **参考官方文档**【已查证】：
  - [About billing for GitHub Actions](https://docs.github.com/en/billing/managing-billing-for-your-products/managing-billing-for-github-actions/about-billing-for-github-actions) (查阅日期：2026-10-24)
  - [GitHub Actions product billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions) (查阅日期：2026-10-24)
- **规则要点**：
  - 公开仓库免费；私有仓库按账号计划每月赠送固定分钟数池。
  - **分钟折算倍数（Multiplier）**：
    - Linux：**1x**
    - Windows：**2x**（1 分钟 Windows 消耗 2 分钟免费额度池）
    - macOS：**10x**
  - **免费额度池**：
    - **GitHub Free**：每月 **2,000 分钟**（Linux 等效分钟），500 MB 存储。
    - **GitHub Pro**：每月 **3,000 分钟**（Linux 等效分钟），1 GB 存储。
  - **超出额度后单价**：
    - 标准 Linux（2-core）：$0.008/分钟（新标准 $0.006/分钟）
    - 标准 Windows（2-core）：$0.016/分钟（新标准 $0.010/分钟）
    - 超额存储单价：$0.25 / GB / 月。

### 2. 测算算法与公式
$$\text{等效 Linux 分钟} = \text{Linux 计费分钟} \times 1 + \text{Windows 计费分钟} \times 2$$
$$\text{总等效分钟} = 437 \times 1 + 6,294 \times 2 = 437 + 12,588 = 13,025 \text{ 分钟}$$

### 3. 折算结论表

| 计划类型 | 每月免费额度 | 10 月等效总用量 | 额度占用率 | 超额分钟数 | 超额产生费用 (按 $0.008 计) | 超额产生费用 (按 $0.006 计) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **GitHub Free** | 2,000 分钟 | 13,025 分钟 | **651.3%** | 11,025 分钟 | **$88.20** | **$66.15** |
| **GitHub Pro** | 3,000 分钟 | 13,025 分钟 | **434.2%** | 10,025 分钟 | **$80.20** | **$60.15** |

> **核心结论句**：  
> **「同样的 10 月用量放私有仓库 = 13,025 分钟换算，占 2000 分钟免费额度的 651.3%（超额 5.51 倍）；超额部分若未设防，将实扣 \$66.15 ~ \$88.20。」**

### 4. 关键洞察：单次 Release 的成本
在 CI 移除了自动 Windows 打包后，10-07 单日仅跑正式发布（Release v1.11.0）与日常 CI：
- Linux：217 分钟，Windows：689 分钟。
- 等效分钟：`217 + 689 × 2 = 1,595 分钟`。
- **单单发布一次完整版本，就会吃掉 2,000 分钟免费额度的 79.8%（约 1,600 分钟）！**
这意味着在私有仓库中，**每个月只要跑 1.5 次完整 Release，就会将整月的免费额度完全耗尽**。

---

## 六、防超额建议清单（选项 A ~ H）

每项独立可选，未经维护者确认前**不进行任何实际改动**：

| 选项 | 做什么 | 省多少（真实数据折算） | 代价 | 改动范围 | 回退方式 | 是否影响现有发布流程 |
| :---: | :--- | :--- | :--- | :--- | :--- | :---: |
| **A** | **CI 坚决禁用自动 Windows 打包**（已在 10-07 实施，需制度化确立） | **节省 10,386 换算分钟**（占 10 月总量的 79.7%） | PR 阶段不打包 Windows 二进制，改在发布时统一打包 | 确认 `.github/workflows/ci.yml` 保持 manual 条件 | 将 `if: workflow_dispatch` 移除 | **无影响**（发布走 `build-release-conda.yml`） |
| **B** | **PowerShell 检查改在 Linux (`ubuntu-latest`) 下跑 `pwsh`** | 节省 38 换算分钟（Windows 2x 降为 Linux 1x，省 50%） | Linux 预装的是 PowerShell Core 7，无法 100% 模拟 Windows 5.1 原生环境怪癖 | 修改 `ci.yml` 中 `powershell-parse` 的 `runs-on: ubuntu-latest`, `shell: pwsh` | 改回 `runs-on: windows-latest` | **无影响** |
| **C** | **在 Release 流水线补充 `concurrency` 与 `cancel-in-progress: true`** | **防范至少 500 ~ 900 换算分钟/次**（防止连续重试同时并行两个全量打包） | 在快速追加 TRIGGER 重试时，会自动中止前一次没跑完的 Release 构建 | 修改 `.github/workflows/build-release-conda.yml` 增加 `concurrency` 配置 | 删掉该配置段 | **安全受益**（安全支持 `release/TRIGGER` 重试） |
| **D** | **为所有 Job 设置严格 `timeout-minutes`**（如 Windows 打包 60m，CI 10m） | **防挂起兜底**：一旦 PyInstaller/conda 卡死，单 job 最多浪费 60m 而非默认的 360m（省 300m Windows = 600 换算分/次） | 若网络极度恶劣导致真实构建超过 60 分钟会被超时终止 | 修改 `.github/workflows/*.yml` 各 job | 删掉 `timeout-minutes` | **无影响**（当前最长 Windows 打包约 25 分钟，60 分钟余量充裕） |
| **E** | **精简私有环境发布矩阵（只保留 CUDA 核心包）** | 单次发布从 21 个 job 降为 4 个 job，单次发布**节省约 720 换算分钟**（从 900m 降至 180m） | 放弃自动构建 AMD gfx 架构和部分 CUDA 旧版本，小众环境需手动单独打 | 修改 `build-release-conda.yml` 的 matrix | 还原 matrix 列表 | **有影响**（减少 Release 资产多样性，需维护者拍板） |
| **F** | **设置 Artifacts 保留期为 1 天 (`retention-days: 1`)** | **每月节省约 \$32.40 潜在存储费**（避免 129 GB 构件在私有仓库中按月计费） | 构件 1 天后过期，不能在数周后回溯下载当时的临时构建（但 Release 资产不受影响） | 修改 `build-windows.yml` upload-artifact 步骤加 `retention-days: 1` | 改回默认 90 天 | **无影响**（发布包在流水线结束前已上传到 GitHub Releases） |
| **G** | **GitHub 账户级防御：Spending Limit 设为 \$0** | **100% 物理消除扣费风险**（超额即停，绝不扣信用卡一分钱） | 额度耗尽后私有仓库 Actions 停止执行，需等下月重置或临时调高额度 | 在 GitHub 网页 Settings → Billing → Spending limits 设置 | 随时在网页调高限额 | **私有仓库额度耗尽时受限**（公开仓库不受限） |
| **H** | **私有仓库只保留手动触发 (`workflow_dispatch`)** | **节省 100% 被动触发分钟** | 失去自动化 CI 保护，所有构建必须人工去 Actions 页面点击 | 修改各 workflow `on:` 仅留 `workflow_dispatch` | 加回 `push`/`pull_request` | **有重大影响**（改变 `release/VERSION` 合并自动发布的行为契约） |

---

## 七、推荐组合与实施建议

### 推荐组合：A + C + D + F + G（零业务破坏 + 极致安全兜底）

- **推荐理由**：
  1. **零业务破坏**：完全不改动 AGENTS.md 规定的 `release/VERSION` 触发发布、`release/TRIGGER` 安全重试契约，产物包种类（21 个全矩阵）一个不少；
  2. **消除无效浪费**：通过 C（防重叠）+ D（防挂死 60m 兜底）+ F（1 天构件过期，清空 129GB 存储积压），消灭一切非必要浪费；
  3. **底线安全兜底**：通过 G（Spending Limit = $0），无论发生何种意外，直接从账号层面锁死扣费，J 绝不需要担心收到账单扣款通知。
- **执行原则**：本报告仅作决策参考，在 J 审查并选定方案前，不改动任何仓库代码、工作流与设置。
