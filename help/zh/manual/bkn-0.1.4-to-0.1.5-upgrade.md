# BKN Foundry 0.1.4 → 0.1.5 升级 Runbook

> **目标集群** `hw.local`（master1 + node1–5 · v1.23.14 · CentOS 7.9）· 命名空间 `openbkn` · 入口 `openbkn.changhong.com`
> **适用拓扑** Community 版 · 中间件全外置（MariaDB/OpenSearch/Redis/Kafka/MinIO）· 复用 matrix 的 `nginx-hw-public` ingress
> 基于 2026-10-12 的 P0 只读勘察结果编写。**每一步都给了预期结果，不符合就停下，不要往下走。**

---

## 0. 这份文档怎么用

| 阶段 | 是否停机 | 内容 |
| --- | --- | --- |
| **P1 准备** | 不停机 | 备份、放锁文件、备运行时、拉 chart/镜像、写 manifest、进窗口前基线复核 |
| **P2 维护窗口** | **停机** | 挂 CronJob → 封入口 → **部署 0.1.5（建表）** → 验表 → 停业务 → dry-run → **权限迁移（apply）→ 回填** → 恢复业务 |
| **P3 冒烟与开放** | 逐步恢复 | 冒烟 → 开入口 → 验证 → 收尾 |

P1 可以提前几天做完（但 **P1.10 基线复核必须在进窗口前重跑一次**，P0 的快照会过期）。
P2 → P3 必须连在一起做完（预计 2–4 小时，变量是镜像拉取）。

> **2026-10-16 修正**：部署已提前到迁移**之前**（原「P3 部署」并入 P2.3），两个 dry-run
> 从 P1 移入窗口（P2.6 / P2.8）。**原因见 §2.5**——迁移工具要求 0.1.5 的表已存在，
> 而表只有部署这一步会建。原顺序跑不起来。
>
> 窗口内另外定了两件事：**权限迁移 apply（P2.7）排在回填（P2.8）之前**（理由见 §7 第 2 条）；
> 以及 **P2.2「封住对外入口」本次实际未执行，入口全程开放**（后果见 §7 第 3 条）。

---

## 1. P0 勘察结论（2026-10-12 17:22）

| 项 | 实测 | 影响 |
| --- | --- | --- |
| `/opt/bkn-foundry/VERSION` | `0.2.0`，`release-manifests/` 只到 **0.1.4** | 缺 0.1.5 锁文件 → **P1.2 必须补** |
| `deploy/scripts/upgrades/0.1.5/` | ✅ **两个迁移包都在** | 回填与权限迁移可直接本地跑，无需下载 |
| 迁移包内容 | 与 v0.1.5 tag 一致（仅 `go.mod/go.sum` 有差异，且自带已编译的 `authz-migrate`） | **不需要 Go**，不需要重建 |
| `git` | ❌ 缺失 | 不能 clone openbkn-deploy → 用 P1.2 的锁文件 |
| `python3` | ❌ 3.6.8，**无 PyMySQL**，无 3.9+ | 迁移脚本跑不了 → **P1.3 必须备运行时** |
| `mysql`/`mariadb`/`mariadb-dump` | ❌ 全部缺失 | `migrate.py` 强制要求 `mariadb-dump` 或 `mysqldump` 在 PATH → **P1.3 必须解决** |
| `kubectl` / `helm` | ✅ 1.23.14 / **3.12.3** | 满足要求 |
| GHCR / SWR | ✅ 均返回 401（可达，匿名未授权属正常） | chart 可直接 `helm pull` |
| 中间件四端口 | ✅ 3306/9200/9000/9092 全通 | 迁移网络无障碍 |
| 集群健康 | ✅ 16 个 Deployment 全 1/1，18 Pod Running，**0 重启** | 基线干净，可回滚 |
| CronJob | ⚠️ 2 个 `SUSPEND=False`（每日 03:00） | P2 必须挂起 |
| 磁盘 | `/` 剩 20G；`/var/lib/docker` 剩 184G | 备份/镜像走 `/var/lib/docker` 分区 |
| 主机规格 | master1 4 核 / 7.4G | 容器方案要限制资源 |

**P0 没能拿到的**：数据库实际状态（本机无 MySQL 客户端）。→ P1.3 备好运行时后**第一件事就是补这个勘察**。

---

## 2. 变更摘要

### 2.1 what
把 `openbkn` 命名空间的应用层从 **0.1.4 升到 0.1.5**，包含两个强制的一次性数据迁移：

1. **创建者授权回填**（`network_builder_scope`）—— 0.1.5 把 `network_builder` 的种子授权从「catalog / knowledge_network 全量 CRUD」收窄成只剩 `create`。不先回填，用户对自己创建过的目录和知识网络会**丢掉管理权限**。
2. **权限模型迁移**（`permission_model_transition`）—— 官方指定的一次性切换入口，含 BKN 数据、Vega 目录、授权策略三步，成功后写入带校验和的迁移标记。

### 2.2 影响面（blast radius）
- **停机**：`bkn-safe`、`bkn-backend`、`vega-backend`、`ontology-query`、`agent-operator-integration` 五个 Deployment 缩到 0。其余服务不停，但没有 bkn-safe 就是不可用状态——**对外等于全停**。
- **改动范围**：仅 `openbkn` 命名空间。**不碰**矩阵平台的 ingress 控制器、不碰集群其他命名空间、不碰外置中间件的软件本身（只读写数据）。
- **数据写入**：外置 MariaDB（`10.67.51.9:3306`）上的 `openbkn` 库（BKN 资源 + 代理数据）和 `safe` 库（授权）。`bkn_trace` / `deploy` 库不动。
- **行为变更**（升级后即生效，不依赖迁移脚本）：
  - **`normal_user` 内置角色被删除，且是 bkn-safe 0.1.5 自己动手删的**（0.1.4 有 6 个内置角色，0.1.5 只剩 5 个）。
    见下面单独一节——**这是本次最容易低估的一条**。
  - `find_skills`、`search_tools`、PTC 端点、语义检索端点被 `search_capabilities` 和标准 MCP 面替代。**有外部系统在调这些接口的话，升级即断。**

#### ★ `normal_user` 的真实影响（2026-10-16 实测 + 源码）

**机制**：不是「迁移脚本不管」，而是 **bkn-safe 0.1.5 在第一次启动时就地删除**。
`Boot()` 里无条件调用（`app.go:104-111`，注释写明 "Run the normal_user withdrawal
independently of `seed_on_start`"）：

```go
// seed.go:305-330  ReconcileWithdrawnNormalUserRole
enforcer.RemoveRoleCompletely(normalUserRoleID)   // 删 g 绑定 + p 策略
db.Delete(&model.Role{}, "id = ?", normalUserRoleID)  // 删角色行
```
`RemoveRoleCompletely`（`authz.go:745-753`）明确"purges every casbin trace of a role:
its bindings (grouping g-lines with role=roleID) and its own permission grants
(p-lines with sub=roleID)"。**幂等。**

**在本次窗口里它发生在 P2.3**——比 `migrate.py apply` 自建的那份备份还早，
所以**唯一的恢复手段是 P1.5 的备份**。

**你库里的实测数字**（2026-10-16）：**12 个用户绑定 + 7 条策略，而全库总共只有 14 个用户**——
也就是说 **86% 的用户受影响**。对照 v0.1.4 的 `seed/data/grants.json`，这 7 条正是：

| 资源类型 | 被删掉的操作 |
| --- | --- |
| `small_model`、`large_model` | `display`、`execute` |
| `operator`、`skill`、`mcp`、`tool_box` | `view`、`execute` |
| `agent` | `use` |

**0.1.5 的 5 个角色里没有任何一个承接这些操作**——`network_builder` 在 0.1.5 只保留
那些类型的 `create`（`grants.json` 逐条对比可验）。**不存在角色级替代。**

#### 但影响很可能没有听起来那么大（三条理由）

1. **那 12 个人全部同时拥有 `network_builder`**（实测），只有 1 个人还多一个 `admin`。
   没有一个人是"只有 `normal_user`"。
2. **`account_type` 全是 `other`**，即本地人类账号的默认值
   （其他取值是 `id_card` / `app` / `contactor`，`model.go:30-36`）——
   **不是外部集成的系统账号**，所以不存在"集成被切断"。
3. **0.1.5 用「公共授权」承接了**——**但要分清只覆盖内置组件**（2026-10-16 查实）：

   - `PublicAccessorID = "00000000-0000-0000-0000-000000000000"`（全零 UUID），
     matcher 里 `p.sub == PublicAccessorID` 视为**公共授权，对任何请求者生效**
     （`authz.go:44-45,63,66-70`）。
   - 写入它的函数是 `CreateIntCompPolicyForAllUsers`
     （`operator-integration/server/logics/auth/policy.go:26-40`），授予
     **`public_access` + `execute`**，注释：*"The default root department (everyone) of
     **built-in components** has public access and execution permissions."*
   - **触发条件是 `IsInternal`**，位置在导入的后处理里：
     ```go
     // Built-in component: Create a full authorization policy (public_access + execute)
     if boxDB.IsInternal {
         s.AuthService.CreateIntCompPolicyForAllUsers(ctx, ...)
     }
     ```
     （`logics/toolbox/impex.go:104-115`、`logics/operator/impex.go:118-149`）
   - **实测：你库里现在一条 `PublicAccessorID` 行都没有**（0.1.4 不需要它——
     那时是 `normal_user` 的类型级授权在兜底）。

   **→ 所以准确的结论是**：

   | 资源 | 0.1.5 里那 12 人的处境 |
   | --- | --- |
   | **内置** toolbox / operator / skill（`IsInternal=true`） | ✅ 导入时自动拿到全员 `public_access`+`execute`，不受影响 |
   | **用户自建**的能力（skill / mcp / tool_box / operator） | ⚠️ 不再是"全员可用"。原来靠 `normal_user` 的 `skill:* view,execute` 类型级授权，现在没有类型级授权，**别人的对象要显式授权才能用**；自己的对象由创建者授权覆盖 |
   | 模型、agent | 同上，按对象授权 |

   **这是 0.1.5 有意的设计变更**，不是缺陷：0.1.4 的注释已经埋了伏笔——
   *"a type-wide allow cannot be narrowed by an object grant in an allow-only engine"*，
   0.1.5 干脆把类型级允许全部撤掉，改成纯对象级 + 内置组件公共授权。

   **→ 最终判断**：**不是"12 个人被锁在门外"**。真实变化是
   **用户之间不再默认互相可见可执行对方自建的能力**，需要显式授权。
   这是个**收紧**，大概率符合预期，但要知会这 12 个人。

**结论**：进窗口前**不需要做任何授权调整**。P5.7② 只需按上表实测两点：
①用一个受影响账号跑一次**内置**技能/工具箱 → 应当正常；②访问**别人自建**的技能 → 应当被拒
（**被拒是预期**，不是故障）。

> **不要手工把那 7 条 `p` 策略插回去。** 0.1.5 的授权以 `authorization_grant` 台账为准，
> 手工写 `casbin_rule` 会绕过台账、与校验和对不上。真要补授就走界面/接口。

#### ★ 一个由「部署先于迁移」直接导致的后果

那 7 条策略在 **P2.3**（bkn-safe 首次启动）就被删了，而**迁移是在那之后才读
`casbin_rule` 的**。也就是说，`03-authorization` 那一步做历史行分类时，**这 7 条已经不在表里**。

如果按官方「先迁移后部署」的顺序，它们本会被分类步骤看到并可能转成对象级授权。
**但那个顺序被证明跑不起来**（§2.5），所以这个损失在当前方案里是**结构性、不可避免**的。
它也是「P5.7② 必须人工确认」这条要求的根本原因。

### 2.3 ⚠️ 先分清平台里的两个数据库

这套部署同时存在 **MariaDB** 和 **PostgreSQL**，很容易混淆，但职责完全不重叠：

| | 位置 | 装什么 | 本次升级 |
| --- | --- | --- | --- |
| **MariaDB** | **外置** `10.67.51.9:3306` | **全部业务数据**：bkn-safe 的 users / roles / `authorization_grant` / `casbin_rule`（`safe` 库）、vega 目录、bkn-backend 知识网络（`openbkn` 库） | **读写，是迁移目标** |
| **PostgreSQL** | **集群内** `bkn-safe-postgres`（PVC 10Gi） | **只有 hydra**：OAuth2/OIDC 的 client / token / consent。`POSTGRES_DB=hydra` | **完全不碰** |

依据：`bkn-safe/charts/bkn-safe/templates/deps.yaml`（"PostgreSQL (hydra's DB — **MariaDB can't host hydra**) is always bundled here"）、`bkn-safe/charts/hydra/values.yaml:31-33`（"MariaDB is NOT supported"）；bkn-safe 的业务库连接则由 ConfigMap 从 `depServices.rds` 取（chart 注释 "When present, the bkn-safe app DB uses it"），也就是你配置里的 MariaDB。

**本文档里的 `mariadb` 客户端命令、`mariadb-dump`、`SAFE_DB_*` 全都指向那台外置 MariaDB**，与集群内的 PG 无关。（`mariadb-client` 包里 `mysql` 是 `mariadb` 的别名，两者等价；本文档统一写 `mariadb` 以免歧义。）

### 2.4 rollback
- **应用层**：用 `release-manifests/0.1.4/bkn-foundry.yaml` 重新 `helm upgrade` 即可回到 0.1.4（15 个 release 全部无状态）。**注意**：hotfix 版本（`agent-operator-integration` / `sandbox` / `agent-retrieval` 三个钉的是 `0.1.4-hotfix-supply-sample-p1`）只在 GHCR 有，SWR 上没有——回滚时这三个镜像要走 GHCR。
- **数据层**：**没有反向脚本**。权限迁移一旦写入，只能靠 P1.5 的备份恢复。这是整个方案唯一不可逆的部分。
- **★ 部署本身也是单向门**（2026-10-16 新发现）：P2.3 会执行
  `migrations/bkn-backend/mariadb/0.1.5/01-remove-business-domain.sql`，删掉
  `t_knowledge_network.f_business_domain` 与 `t_operation_audit` 的两列两索引。
  0.1.4 的 bkn-backend 会显式 SELECT `f_business_domain`
  （`knowledge_network_access.go:160,223,362`）——**版本退回去但不恢复 `openbkn` 库，0.1.4 会直接报 `Unknown column`**。
  该 SQL 文件也是本批里唯一**没有** rollback 段的一个。详见 §6.5。

### 2.5 ★ 为什么必须先部署再迁移（2026-10-16 修正）

**原 runbook 的顺序是「迁移完再部署」。实测证明这个顺序跑不起来。**

**证据链**（全部来自源码与实测，非推断）：

1. `migrate.py` 的 dry-run **也**要求 0.1.5 的表已存在。`run()` 里
   `load_proxy_plan()`（`bkn_data.py:2252`）先跑，`if mode == "dry-run"`（`:2261`）后判断；
   而 `load_proxy_plan` 第一件事就是 `require_safe_proxy_schema(safe_connection)`（`:911`），
   该函数（`:778-795`）要求 8 张表，缺任何一张就抛
   `MigrationError("bkn-safe 0.1.5 schema is unavailable; missing tables: ...")`。
   **没有跳过开关。**
2. 紧接着它还查 `t_kn_proxy_account` / `t_kn_capability_binding` /
   `t_kn_proxy_published_grant_source`（`:913-923`），缺了同样抛错。
3. **实测**（你的库，2026-10-16）：`safe` 14 张表，缺
   `managed_proxy_accounts`、`proxy_grant_source`、`proxy_grant_policy`、`authorization_grant`；
   `openbkn` 缺那三张 `t_kn_*`。→ 上述两处检查都会失败。
4. **这些表只有部署 0.1.5 会建**，分两条互不相干的路径：
   - `openbkn` 侧：锁文件里 `core-data-migrator` **排第一个**且 `stage: pre`，
     其 Job 带 `helm.sh/hook: pre-install,pre-upgrade`（chart `templates/job.yaml`），
     跑 `data-migrator.py migrate`；镜像内 `/app/repos` 就是仓库根的 `migrations/`
     （`data-migrator/Dockerfile:32`），而 `config.monorepo.yaml` 把 `bkn-backend` 映射到
     `migrations/bkn-backend` → 应用 `migrations/bkn-backend/mariadb/0.1.5/{01..05}.sql`。
   - `safe` 侧：bkn-safe 0.1.5 进程启动时 `AutoMigrate(model.AllModels()...)`
     （`database.go:65`），`AllModels()`（`model.go:474-482`）正好含
     `ManagedProxyAccount` / `ProxyGrantSource` / `ProxyGrantPolicy` / `AuthorizationGrant`。
     **bkn-safe 不在 data-migrator 的 `services:` 列表里**，所以没有别的途径。

**由此得到本窗口的顺序**：

```
封入口 → 部署 0.1.5（建表）→ 停业务 → dry-run → apply → 回填 → start → 冒烟 → 开入口
```

**为什么「部署先于停业务」是安全的**：

| 保证 | 依据 | 本次是否成立 |
| --- | --- | --- |
| 外部无流量 | P2.2 封入口 → 返回 503 | ❌ **本次未执行 P2.2，入口全程开放** —— 见下方「本次偏离」 |
| **bkn-safe 根本不接请求** | 缺迁移标记时 `Run()` 直接返回错误、进程退出（`app.go:209-214`）——不是「拒绝判定」而是「起不来」，比 fail-closed 更彻底 | ✅ |
| **不会被误判为全新安装而跳过迁移** | `IsFreshAuthorizationStore()` 只认「`casbin_rule` 表不存在」为全新信号（`gate.go:50-54`）；你的 `casbin_rule` 存在 → `wasFresh=false` → `SeedFreshInstallMarker` 转而 `VerifyCurrentMarker` 并失败（`gate.go:87-89`），**不写标记** | ✅ |
| **建表在崩溃之前完成** | AutoMigrate 在 `Boot()` 里（`app.go:98`），`Run()` 的检查在其后（`:212`）；MySQL DDL 自动提交，进程退出不回滚已建的表 | ✅ |

> **⚠️ 本次偏离（2026-10-16 事后确认）**：第一行的保证**没有成立**。操作者当时决定不封入口，
> `openbkn.changhong.com` 从 P2.3 到 P2.9 **全程可达**。实际成立的是下面三条。
> 完整后果评估见 §7 第 3 条。

**代价（必须明确记下）**：从 P2.3 部署开始到 P2.5 `stop` 之间，**整轮部署时长**（实测 0.2.0 脚本约 1 分钟；v0.1.5 脚本因 `--wait` 约 15 分钟）
里那另外 4 个服务（bkn-backend / vega-backend / ontology-query / agent-operator-integration）
会以 0.1.5 跑在未迁移的数据上。授权面由 bkn-safe 起不来而完全断开。
**本次入口未封，所以这一段是暴露在外部流量下的** —— 见 §7 第 3 条。

> **一个附带的、必须提前接受的现象**：`bkn-safe` 这个 release 在 P2.3 里会
> **显示为 `failed`，Pod 处于 `CrashLoopBackOff`**。这是设计如此，不是故障——
> 它要等 P2.7 写入标记后才会自愈。**不要为了「让它变绿」去改标记或手工补数据。**

> **与原 runbook 的差异汇总**：① 部署提前到迁移之前；② 两个 dry-run 从 P1 移进窗口
> （P2.6 / P2.8）；③ 回滚从「退回版本」升级为「退回版本 + 恢复两个库」；
> ④ 新增 P2.4 硬闸（验表）。P1 其余步骤与全部命令参数均未改动。

---

## 3. P1 准备（全程不停机）

### P1.1 建工作目录，备份部署根与配置

```bash
export W=/var/lib/docker/bkn-upgrade-0.1.5     # / 只剩 20G，备份与镜像走大分区
mkdir -p "$W"/{reports,backup,rt}
chmod 700 "$W"

# 部署根只备份会被本次修改的文件：锁文件目录 + 配置文件 + 迁移包
cp -a /opt/bkn-foundry/deploy/release-manifests "$W/backup/release-manifests.orig"
cp -a /opt/bkn-foundry/my-config.yaml "$W/backup/my-config.yaml"
cp -a /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5 "$W/backup/upgrades-0.1.5.orig"

# 整份 deploy/ 打包留底
# 理由：这是 0.2.0 时期的发布包快照，而 upstream 已于 2026-10-12 把 deploy/
# 整体移出 bkn-foundry 仓库（commit c3ea77407）——损坏了没有同形态整包可重下。
tar czf "$W/backup/bkn-foundry-deploy-$(date +%Y%m%d).tar.gz" -C /opt/bkn-foundry deploy
ls -lh "$W/backup/bkn-foundry-deploy-"*.tar.gz

# 已经存在的入口回退文件确认在
ls -l /root/openbkn-entry-tls.yaml
```

**预期**：无报错，`deploy` 整包 tar.gz 生成（约几十 MB），`/root/openbkn-entry-tls.yaml` 存在（这是 §5.3 恢复入口的依据）。

> **`$W` 要在同一个 shell 会话里才有值**。断开重连后先重新执行一次：
> ```bash
> export W=/var/lib/docker/bkn-upgrade-0.1.5
> ```
> 下面所有命令都依赖它。

### P1.2 放入 0.1.5 锁文件

0.1.5 的锁文件**不在 bkn-foundry 仓库里**——它在独立仓库 `openbkn-ai/openbkn-deploy`，且那边叫 `openbkn.yaml`。而 `deploy.sh` 的解析逻辑是 `${RELEASE_MANIFESTS_DIR}/${version}/bkn-foundry.yaml`（已核对 `deploy/scripts/lib/common.sh:773`），**文件名不匹配**。所以放到正确名字下：

```bash
mkdir -p /opt/bkn-foundry/deploy/release-manifests/0.1.5
cat > /opt/bkn-foundry/deploy/release-manifests/0.1.5/bkn-foundry.yaml <<'EOF'
# Release lockfile for OpenBKN 0.1.5 — pins the chart version of every
# component that makes up the product. Consumed by:
#     deploy.sh openbkn install --version=0.1.5
# All charts are published at 0.1.5 by the v0.1.5 release build.
apiVersion: deploy.openbkn.ai/v0.1.5
kind: VersionSet
product: bkn-foundry
version: 0.1.5
source:
  type: oci
  registry: oci://ghcr.io/openbkn-ai/charts
releases:
  core-data-migrator:
    chart: core-data-migrator
    version: 0.1.5
    stage: pre
  bkn-safe:
    chart: bkn-safe
    version: 0.1.5
  mf-model-manager:
    chart: mf-model-manager
    version: 0.1.5
  mf-model-api:
    chart: mf-model-api
    version: 0.1.5
  vega-backend:
    chart: vega-backend
    version: 0.1.5
  bkn-backend:
    chart: bkn-backend
    version: 0.1.5
  ontology-query:
    chart: ontology-query
    version: 0.1.5
  agent-operator-integration:
    chart: agent-operator-integration
    version: 0.1.5
  oss-gateway-backend:
    chart: oss-gateway-backend
    version: 0.1.5
  sandbox:
    chart: sandbox
    version: 0.1.5
  agent-retrieval:
    chart: agent-retrieval
    version: 0.1.5
  bkn-agent:
    chart: bkn-agent
    version: 0.1.5
  agent-observability:
    chart: agent-observability
    version: 0.1.5
  otelcol-contrib:
    chart: otelcol-contrib
    version: 0.1.5
  bkn-studio:
    chart: bkn-studio
    version: 0.1.5
EOF
```

> 这份内容取自 `openbkn-deploy@v0.1.5` 的 `release-manifests/0.1.5/openbkn.yaml`（2026-10-12 下载核对），**只改了文件名**，内容一字未动。
> **15 个 release 与你现有的 15 个 helm release 一一对应**；不要用 `bkn-foundry.template.yaml`，那是 dev 生成器模板，多一个 `kafka-connect`（`deploy/scripts/bkn-foundry.template.yaml` 开头就写明 "NOT a release lockfile"）。

**验证脚本能解析到它**：

```bash
cd /opt/bkn-foundry/deploy
bash ./deploy.sh --config=/opt/bkn-foundry/my-config.yaml openbkn status 2>&1 | head -20
```

**预期**：能正常输出状态表，不出现 `No release manifest found for bkn-foundry`。

### P1.3 准备迁移运行时（容器）

`migrate.py` 和回填脚本都需要 **Python 3.9+ / PyMySQL 1.1.0 / `mariadb-dump`**，master1 三样全无。用节点上的 docker 跑容器是最省事的办法。

**先探测网络可达性**（决定走哪条路）：

```bash
docker pull python:3.9-slim && echo "路线1 OK" || echo "路线1 失败"
curl -s -o /dev/null -w 'pypi:%{http_code}\n' --max-time 10 https://pypi.tuna.tsinghua.edu.cn/simple/
curl -s -o /dev/null -w 'huaweimirror:%{http_code}\n' --max-time 10 https://mirrors.huaweicloud.com/
```

**路线 1（首选）**：能拉 `python:3.9-slim` 且 pip 镜像可达。

```bash
cd "$W/rt"
docker pull python:3.9-slim

cat > Dockerfile <<'EOF'
FROM python:3.9-slim
# PyMySQL 用国内镜像装，避免 pypi.org 不可达
RUN pip install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple pymysql==1.1.0
# mariadb-dump：migrate.py 强制要求它在 PATH
RUN sed -i 's|deb.debian.org|mirrors.huaweicloud.com|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true \
 && apt-get update -o Acquire::Retries=3 \
 && apt-get install -y --no-install-recommends mariadb-client \
 && rm -rf /var/lib/apt/lists/*
EOF

docker build -t bkn-migrate:0.1.5 .
```

**路线 2**：拉不到 docker.io，但能拉 SWR → 把基础镜像换成华为云 SWR 的 docker.io 代理，`sed` 改 `Dockerfile` 第一行，其余不变。

**路线 3（兜底）**：两条路都不通 → 停止 P1，把探测输出贴回来，改用「本地构建后 `docker save` / `docker load` 导入」的方式（你 Mac 上有 Docker 的话）。

**验证容器**：

```bash
# 先确认 kubeconfig 的真实位置（后面每一条带 kubectl 的命令都要挂它）
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}'; echo
if [[ -f /root/.kube/config ]]; then
  echo "kubeconfig: /root/.kube/config"
else
  echo "!! 不在 /root/.kube/config，用下面的命令找："
  find /root /etc/kubernetes -maxdepth 3 \( -name 'config' -o -name '*.conf' \) 2>/dev/null | head
fi

# 迁移包完整性 + 可执行位（发布包解压时权限可能丢，丢了 migrate.py 会直接报错）
U=/opt/bkn-foundry/deploy/scripts/upgrades/0.1.5
ls -l "$U/permission_model_transition/authz_migrate/authz-migrate"
[[ -x "$U/permission_model_transition/authz_migrate/authz-migrate" ]] || {
  echo "!! authz-migrate 没有可执行位，补上："
  chmod +x "$U/permission_model_transition/authz_migrate/authz-migrate"
}
file "$U/permission_model_transition/authz_migrate/authz-migrate" 2>/dev/null | head -1
for f in migrate.py bkn_data.py vega/vega_data.py service_control.sh \
         ../../../network_builder_scope/backfill_creator_grants.py; do
  printf '%-42s ' "$f"; [[ -e "$U/permission_model_transition/$f" ]] && echo OK || echo "缺失!"
done

# 容器自检
docker run --rm --network host \
  -v /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5:/work:ro \
  -v /root/.kube:/root/.kube:ro \
  -v /usr/local/bin/kubectl:/usr/local/bin/kubectl:ro \
  bkn-migrate:0.1.5 bash -lc '
    python3 --version
    python3 -c "import pymysql;print(\"pymysql\",pymysql.__version__)"
    which mariadb-dump
    kubectl version --client=true 2>/dev/null | head -1
    kubectl get ns openbkn >/dev/null && echo "kubectl 连通集群 OK"
    /work/permission_model_transition/authz_migrate/authz-migrate --help >/dev/null 2>&1 \
      && echo "authz-migrate 可在容器内执行 OK" || echo "!! authz-migrate 执行失败（多为架构不符或权限位丢失）"
    ls /work'
```

**预期**：`Python 3.9.x`、`pymysql 1.1.0`、`/usr/bin/mariadb-dump`、`kubectl 连通集群 OK`，并列出 `/work` 下的 `network_builder_scope` 和 `permission_model_transition`。

> 若最后一行没有 `kubectl 连通集群 OK`，说明 kubeconfig 路径不是 `/root/.kube/config`。把上面找到的真实路径换成挂载源，并把它所在目录挂到容器内同一位置即可。**这一步必须先通过**，P2.3 / P2.5 / P3 的 start 都依赖它。

### P1.4 补做数据库勘察（P0 缺的那块）

> **★ 口令传递的坑（已在下面每条命令里避开，手敲时要留意）**
>
> 这些命令用 `-e DB_PW` 把口令传进容器，而 `-e VAR`（不带 `=值`）是
> **从 docker 进程自己的环境**里取值的。所以 `read -rsp ... DB_PW` 之后**必须
> `export DB_PW`**——只设 shell 变量不导出，docker 看不到它，会传一个空串进去，现象是：
>
> ```
> ERROR 1045 (28000): Access denied for user 'openbkn'@'10.67.51.x' (using password: NO)
> ```
>
> **`using password: NO` 就是口令为空的意思，不是口令错。** 看到它先回头检查 `export`，
> 别去改口令或怀疑账号。
>
> （为什么不写成 `-e DB_PW="$DB_PW"` 来免掉 `export`：那样口令会出现在进程列表和
> shell 历史里。`export` + `-e DB_PW` 是有意的选择。）

```bash
read -rsp 'MariaDB 口令（用户 openbkn）: ' DB_PW; echo; export DB_PW

docker run --rm --network host -e DB_PW -v "$W/reports":/reports bkn-migrate:0.1.5 bash -lc '
export MYSQL_PWD="$DB_PW"
q(){ mariadb -h 10.67.51.9 -P 3306 -u openbkn --batch --raw -e "$1" 2>&1 | head -40; }
echo "== 库大小(MB) =="; q "SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,1) mb, COUNT(*) tbls FROM information_schema.tables WHERE table_schema IN (\"openbkn\",\"safe\",\"bkn_trace\",\"deploy\") GROUP BY table_schema;"
echo "== 迁移标记表（应不存在）=="; q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"safe\" AND table_name=\"authorization_migration_marker\";"
echo "== 内置角色 =="; q "SELECT id,name FROM safe.roles ORDER BY name;"
echo "== normal_user 绑定（★ 必须按 UUID 查，不能按名字）=="; q "SELECT ptype,v0,v1,COUNT(*) n FROM safe.casbin_rule WHERE v0=\"b5f9ac3e-992c-4bbd-8126-95e87e51c46e\" OR v1=\"b5f9ac3e-992c-4bbd-8126-95e87e51c46e\" GROUP BY ptype,v0,v1;"
echo "== t_catalog 创建者覆盖 =="; q "SELECT COUNT(*) catalogs, SUM(f_creator IS NULL OR f_creator=\"\") no_creator, SUM(f_creator_type<>\"user\") creator_not_user, SUM(f_internal) internal_ FROM openbkn.t_catalog;"
echo "== t_knowledge_network 创建者覆盖 =="; q "SELECT COUNT(*) kns, SUM(f_creator IS NULL OR f_creator=\"\") no_creator, SUM(f_creator_type<>\"user\") creator_not_user FROM openbkn.t_knowledge_network;"
echo "== 授权表规模 =="; q "SELECT ptype,COUNT(*) FROM safe.casbin_rule GROUP BY ptype;"
'
unset DB_PW
```

> **★ 查 `normal_user` 必须用角色 UUID `b5f9ac3e-992c-4bbd-8126-95e87e51c46e`。**
> `casbin_rule` 里存的是**角色 ID 而不是角色名**，按 `LIKE '%normal%'` 查会返回空——
> 那是「查法不对」，**不是**「没有绑定」。早先的版本犯过这个错，会给出虚假的安心感。
> （角色 ID 出处：`bkn-safe/server/internal/seed/data/roles.json`；0.1.4 有 6 个内置角色，
> 0.1.5 删掉的就是这一个。）
>
> 若上面查出来有 `g` 类型的行，说明**有用户绑在 `normal_user` 上**——记下这些人，
> P5.7② 要逐个确认他们升级后还能访问该访问的东西。

**预期与判读**：
- **迁移标记表 = 0**（不存在）→ 确认没被提前跑过。若为 1 且有行，**立即停止**，说明迁移已执行过。
- **`no_creator` 必须全为 0**（目录和知识网络都是）。**任何非 0 → 停**：回填脚本会把「创建者缺失」判为 `block` 并中止本次运行。这时候需要先决定这些历史对象归属谁，再继续。
- **`creator_not_user` 也应为 0**（非用户创建者同样 block）。
- 记下 **库大小**，P1.5 的备份空间按它估。

> **已知的预期报错**：`safe.authorization_grant` 在 0.1.4 上**不存在**，任何查它的语句都会报
> `ERROR 1146 (42S02): Table 'safe.authorization_grant' doesn't exist`。**这是正常的**，
> 不要当成故障——它正是 §2.5 整节要解决的问题。0.1.4 实测的 `safe` 库是这 14 张表：
> `access_logs`、`api_keys`、`audit_logs`、`casbin_rule`、`departments`、`group_members`、
> `groups`、`licenses`、`operations`、`resource_parents`、`resource_types`、`roles`、
> `user_departments`、`users`。

### P1.5 独立备份四个数据库

**不要依赖 `migrate.py` 的自保备份**——它只覆盖 BKN 和 Safe，且只在 apply 阶段生成。先自己拿一份完整的：

```bash
read -rsp 'MariaDB 口令（用户 openbkn）: ' DB_PW; echo; export DB_PW

docker run --rm --network host -e DB_PW -v "$W/backup":/backup bkn-migrate:0.1.5 bash -lc '
set -o pipefail                     # 关键：没有它，dump 失败会被 gzip 的 0 退出码掩盖
export MYSQL_PWD="$DB_PW"
TS=$(date +%Y%m%d-%H%M%S)
rc=0
for db in openbkn safe bkn_trace deploy; do
  echo ">>> dumping $db"
  if mariadb-dump -h 10.67.51.9 -P 3306 -u openbkn \
       --single-transaction --routines --triggers \
       --default-character-set=utf8mb4 \
       "$db" | gzip -1 > "/backup/${db}-${TS}.sql.gz"; then
    echo "    OK  $(du -h "/backup/${db}-${TS}.sql.gz" | cut -f1)"
  else
    echo "    !!! $db 失败"; rc=1
  fi
done
echo "--- 备份内容自检（应为非空 SQL 头）---"
for f in /backup/*-${TS}.sql.gz; do
  printf "%-45s " "$(basename "$f")"
  gzip -dc "$f" | head -3 | tr "\n" " "; echo
done
exit $rc
'
echo "退出码: $?"
unset DB_PW
```

**预期**：四个文件都显示 `OK` 和大小，自检每行都能看到 `-- MariaDB dump` 之类的文件头，容器退出码 `0`。**任一 `!!!` 或退出码非 0 就停**。

> `set -o pipefail` 不能省：没有它时 `mariadb-dump` 报错会被管道末端 `gzip` 的退出码 0 吃掉，留下一个**空的 `.gz` 却报告成功**。备份这一步宁可啰嗦也不能假绿。

> 备份落在 `/var/lib/docker` 分区（184G 可用）。**这些文件在升级成功并稳定运行一周前不要删。**
>
> **为什么备份列表里没有 `bkn-safe-postgres`（hydra 的 PG）**：它装的是 OAuth client / token / consent，本次迁移完全不写它，helm upgrade 也不会重建它的 PVC（`strategy: Recreate` + Retain PV）。备份它属于「顺手做也行、但不属于本次变更的保险」。如果想加一份，用：
> ```bash
> kubectl -n openbkn exec deploy/bkn-safe-postgres -- pg_dumpall -U hydra | gzip -1 > "$W/backup/hydra-pg-$(date +%Y%m%d-%H%M%S).sql.gz"
> ```

### P1.6 预拉 0.1.5 chart

避免维护窗口里才发现拉不到 chart。

```bash
mkdir -p /opt/bkn-charts          # helm pull -d 不会自建目录，缺了会 15 行全 FAIL
cd /opt/bkn-foundry/deploy
for c in core-data-migrator bkn-safe mf-model-manager mf-model-api vega-backend bkn-backend \
         ontology-query agent-operator-integration oss-gateway-backend sandbox agent-retrieval \
         bkn-agent agent-observability otelcol-contrib bkn-studio; do
  printf '%-30s ' "$c"
  helm pull "oci://ghcr.io/openbkn-ai/charts/$c" --version 0.1.5 -d /opt/bkn-charts >/dev/null 2>&1 \
    && echo OK || echo FAIL
done
ls -1 /opt/bkn-charts/*0.1.5*.tgz | wc -l
```

**预期**：15 行全 OK，最后一个命令输出 `15`。

> `core-data-migrator` **必须在列表里**——它是 P2.3 建 `openbkn` 侧那三张表的那个 pre-stage hook
> （§2.5）。漏了它，部署会在第一个 release 就找不到 chart。
>
> 15 个名字就是 0.1.5 锁文件的全部 release。若某个 `FAIL`，把 `>/dev/null 2>&1` 去掉重跑一次看真实报错——
> 常见原因是节点到 `ghcr.io` 的出口不通，那就得换 `<registry>` 或先把 tgz 拷进来。

### P1.7 写迁移 manifest

Community 版（已确认：`ee.assembly.was_assembled=false` + 空 `rule_evidence` + `activation=null` 是代码里的正常分支，见 `enterprise.go:95-107` 与 `:513-517`）：

```bash
cat > "$W/authz-migration.json" <<'EOF'
{
  "lifecycle_evidence": [],
  "ee": {
    "assembly": {
      "was_assembled": false,
      "evidence_ref": "community-edition:no-ee-assembly"
    },
    "rule_evidence": [],
    "activation": null
  }
}
EOF
chmod 600 "$W/authz-migration.json"
```

> `lifecycle_evidence` 留空是对的：该字段只用于「权威的生命周期事实」显式声明，Community 无 Enterprise 历史规则需要对齐。留空时 `validateLifecycleEvidence` 返回空表，不产生 anomaly。

### ⛔ P1.8 / P1.9 已移入维护窗口（2026-10-16 修正）

**这里原本是两个 dry-run。它们现在跑不了，已移到窗口内，见 P2.6 和 P2.8。**

原因（实测 + 源码双证，详见 §2.5「为什么必须先部署再迁移」）：

- `migrate.py dry-run` **不写业务数据，但要求 0.1.5 的表已经存在**。调用链是
  `run()` → `load_proxy_plan()`（`bkn_data.py:2252`）→ `require_safe_proxy_schema()`
  （`:911` → `:778`），而 dry-run 分支（`:2261`）在它**之后**才判断。
- 这些表在 0.1.4 上没有：你的 `safe` 库实测 14 张表，缺 `managed_proxy_accounts`、
  `proxy_grant_source`、`proxy_grant_policy`、`authorization_grant`；
  `openbkn` 库缺 `t_kn_proxy_account`、`t_kn_capability_binding`、
  `t_kn_proxy_published_grant_source`。
- 造出这些表的**只有部署 0.1.5 这一步**（机制见 §2.5）。

所以 dry-run 只能挪进窗口、排在部署之后。**这是本次与原 runbook 唯一的流程性改动**，
其余准备步骤（P1.1–P1.7、P1.10）全都不变。

### P1.10 进窗口前的基线复核

**P0 勘察是 2026-10-12 做的快照。P1 可能跨几天做完，期间 CronJob 每天 03:00 会跑。进维护窗口前必须重新确认一次"现在这一刻集群是健康的"。**

理由很实际：如果带着一个已经出问题的基线进 P2，之后出任何故障，你都分不清是自己搞坏的还是本来就坏的。这一步花 30 秒，换来的是**归因能力**。

```bash
cd "$W"
{
  echo "=== 复核时间: $(date) ==="
  echo "--- nodes ---";     kubectl get nodes
  echo "--- pods ---";      kubectl -n openbkn get pods -o wide
  echo "--- deploy ---";    kubectl -n openbkn get deploy
  echo "--- cronjob ---";   kubectl -n openbkn get cronjob
  echo "--- helm ---";      helm list -n openbkn
  echo "--- ingress ---";   kubectl -n openbkn get ingress
  echo "--- 磁盘 ---";      df -h / /var/lib/docker
  echo "--- 备份文件 ---";  ls -lh "$W/backup"
  echo "--- chart ---";     ls -1 /opt/bkn-charts/*0.1.5*.tgz | wc -l
} 2>&1 | tee "$W/reports/pre-window-baseline.txt"
```

**★ 额外一项：确认 migrator 拿得到外置 MariaDB。**（P2.3 的部署靠它建表，配错了会在第一个 release 就失败）

`openbkn.sh` 把 `my-config.yaml` 以 `-f` 传给**每一个** release（`openbkn.sh:1137`、`:1194`），
包括 `core-data-migrator`。那个 chart 的 `depServices.rds` 默认值是**集群内**地址
（`mariadb-mariadb-master.resource.svc.cluster.local`，见 chart 的 `values.yaml`）——
你们是外置库，必须由 `my-config.yaml` 覆盖掉，否则 pre-upgrade hook 会去连一个不存在的地址。

**⚠️ 不要只用 `sed`/`grep` 肉眼看配置——要学会用脚本真正的解析器验。**

`deploy.sh` 读 `depServices.<section>.<field>` 走的是 `common.sh:1024-1034` 的 awk：

```awk
!in_b && $1 == sec && substr($0, 1, 2) == "  " {in_b=1; next}
in_b && NF && $0 !~ /^    / {exit}                 # ← 非空且非4空格缩进就退出
in_b && $1 == fld {gsub(/'"'"'|"/, "", $2); print $2; exit}
```

**它对块内注释极其敏感**：`  # 注释`（2 空格缩进）会让它**提前 exit**，
后面的字段全部读不到。2026-10-16 真实踩过——配置内容完全正确，
仅因三行 2 空格注释，`deploy.sh` 报
`BKN Trace requires depServices.rds.source_type in ...; set it to internal or external`
而**同时**打印 `RDS source_type is set to 'external'`（那个检查用 `grep -A 10`，
不在乎注释，所以两个解析器结论相反——**看到这个矛盾组合就是缩进问题，不是配置问题**）。

```bash
C=/opt/bkn-foundry/my-config.yaml
probe(){ awk -v sec="$1:" -v fld="$2:" '
    !in_b && $1 == sec && substr($0, 1, 2) == "  " {in_b=1; next}
    in_b && NF && $0 !~ /^    / {exit}
    in_b && $1 == fld {gsub(/'"'"'|"/, "", $2); print $2; exit}
' "$C"; }

# 逐字段确认脚本真的读得到（不打印口令）
for pair in "rds source_type" "rds host" "rds port" "rds user" "rds password" \
            "opensearch host" "opensearch port" "opensearch protocol" "opensearch user" "opensearch password" \
            "mq mqHost" "mq mqPort" "mq mqType" "redis connectType"; do
  set -- $pair
  [ -n "$(probe "$1" "$2")" ] && printf '✅ %-24s 可读\n' "$1.$2" || printf '❌ %-24s 读不到\n' "$1.$2"
done
```

**修复**（把 `depServices` 内 2 空格缩进的注释右移到 4 空格；注释不影响 YAML 语义）：

```bash
grep -n '^  #' "$C"                                  # 先看有几处
cp -a "$C" "$W/backup/my-config.yaml.pre-comment-fix"
sed -i -E 's/^  (#.*)$/    \1/' "$C"
grep -n '^  #' "$C" || echo "✅ 已无 2 空格注释"
```

> **★ 探针的假阴性：`opensearch.user` / `opensearch.password` 报 ❌ 通常是正常的。**
> 上面那个探针把「字段不存在」和「字段存在但值为空」都显示成 ❌。
> 你的配置里是 `user: ''`（**空值**），所以必然报 ❌。
>
> **无害的理由**：`_openbkn_prepare_trace_opensearch_secret` 第一件事就是
> `if [[ "${protocol}" == "http" ]]; then return 0; fi`（`openbkn.sh:802-806`），
> **根本不读 user/password**。只有 `protocol: https`（启用了 security 插件）才要求它们。
> `protocol` 能读到 `http` 就说明这一段是好的。
>
> **真正要全绿的**：`rds.source_type` / `rds.host` / `rds.user` / `opensearch.host` /
> `opensearch.protocol` / `mq.mqHost` / `mq.mqPort` / `redis.connectType`。

**逐项判定**：

| 项 | 必须满足 | 不满足怎么办 |
| --- | --- | --- |
| nodes | 全部 `Ready`。**不要用「6 个」当判据**——节点数会变 | 有 `NotReady` → **停**。集群本身有问题，先修 |
| **★ `depServices` 字段都能被脚本读到** | 见下面单独一段。**别用 `sed` 肉眼看**，要用脚本真正的 awk 解析器验 | 有 ❌ → 多半是 2 空格缩进的注释截断了 awk，右移到 4 空格 |
| **每个可调度节点都有 0.1.5 镜像** | **见下面单独一段。这是最容易漏、代价最高的一项** | 缺 → **停**，先补镜像或把该节点列为不可调度 |
| pods | 全部 `Running`，**重启数不增加**（对比 P0 的 0） | 有新增重启 → 查明原因再决定 |
| deploy | 16 个的 READY 与 P0 一致（关键 5 个是 `1/1`） | 有 Deployment 掉副本 → **停** |
| cronjob | 两个都 `SUSPEND=False`，ACTIVE 列没有堆积的 `1` | 有卡住的 Job → 查 `kubectl -n openbkn get jobs` |
| helm | 15 个 release 全部 `deployed` | 有 `failed`/`pending` → **停**，先修 helm 状态 |
| ingress | 13 份（11 平台 + 2 你的），CLASS 全 `nginx-hw-public` | 数量或 class 变了 → 查明再动 |
| 磁盘 `/` | 剩余 ≥ 10G | 不够 → 清理后再进窗口 |
| 备份 | P1.5 的四份 `.sql.gz` 都在，且是**复核前不久**的 | 备份超过一天 → 重跑 P1.5 |
| chart | 输出 `15` | 少于 15 → 重跑 P1.6 |

#### ★★ 镜像覆盖：必须逐节点确认（2026-10-16 基线复核抓到的真问题）

**不要用「6 个节点」当判据。** 2026-10-16 的复核发现集群**已经是 7 个节点**——
`master1`/`node1`~`node5` 是 39d，而 **`node6`/`node7` 只有 2d**（即 2026-10-14 新加的）。
但 0.1.5 的镜像离线包当初只铺到了 master1 + node1~node5 **六个节点**。

**后果**：P2.3 部署时 helm 会重建 Pod，**调度到没镜像的节点上就是 `ImagePullBackOff`**，
而且是在维护窗口里才发现。

```bash
# ① 哪些节点可以承接 Pod
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,UNSCHEDULABLE:.spec.unschedulable,TAINTS:.spec.taints[*].key'

# ② 逐节点数 0.1.5 产品镜像（期望 32 = 16 镜像 × 2 标签）
for n in master1 node1 node2 node3 node4 node5 node6 node7; do
  printf '%-10s ' "$n"
  ssh -o ConnectTimeout=5 "$n" \
    "docker images --format '{{.Repository}}:{{.Tag}}' | grep -c 'openbkn-ai.*0\.1\.5'" \
    2>/dev/null || echo "ssh 不通 / 需换方式"
done
```

**判定与处置**：

| 情况 | 处置 |
| --- | --- |
| 所有**可调度**节点都是 `32` | ✅ 通过 |
| 某节点 `UNSCHEDULABLE=true` 或有 `NoSchedule` 污点 | ✅ 该节点不收 Pod，**不需要**镜像。记下来即可 |
| **可调度**节点数 < 32 | ⚠️ **停**。二选一：<br>(a) 把 `bkn-0.1.5-images.tar.gz` 传上去 load（最干净）；<br>(b) 窗口内把该节点 `kubectl cordon`——**但集群上有你其他业务，cordon 会影响它们，先确认影响面再决定** |
| 节点能直连 registry 拉到 0.1.5 | ✅ 那就不需要离线包（P0 未测过节点到 `ghcr.io`/SWR 的出口，别默认可用） |

> **实测（2026-10-16）：8 个节点全部 `32`，通过。** 但污点决定了 Pod 实际落点，值得记住：
>
> | 节点 | 污点 | 会接业务 Pod 吗 |
> | --- | --- | --- |
> | `master1` | `node-role.kubernetes.io/master` | ❌ |
> | `node1` | **`ingress-only`**（自定义） | ❌ 专用于 ingress |
> | `node2` ~ `node7` | 无 | ✅ **实际只有这 6 个承接 Pod** |
>
> 所以基线复核里要盯的是 **node2~node7**。master1/node1 上有镜像也无妨（多占点盘）。
> 集群**从 6 个节点长到了 8 个**（`node6`/`node7` 是 2026-10-14 新加的，即 P0 之后）——
> 这正是这条检查存在的理由：**节点数会变，判据不能写死。**

> **别忘第三方镜像**：`otel/opentelemetry-collector-contrib:0.148.0`、`oryd/hydra:v26.2.0`、
> `postgres:16`（各两种命名）。`docker images | grep -Ec 'opentelemetry|hydra|postgres'` 应 ≥ 6。

### P1.11 ★ 列出受 `normal_user` 删除影响的用户（进窗口前必须做完）

**为什么必须现在做**：这 12 个绑定会在 **P2.3** 被 bkn-safe 自动删掉（机制见 §2.2），
早于迁移备份。进窗口前把名单拿到手，才能决定「先补授权」还是「升级后逐个补」。

```bash
read -rsp 'MariaDB 口令（用户 openbkn）: ' DB_PW; echo; export DB_PW

docker run --rm --network host -e DB_PW -v "$W/reports":/reports bkn-migrate:0.1.5 bash -lc '
export MYSQL_PWD="$DB_PW"
mariadb -h 10.67.51.9 -u openbkn --batch --raw -e "
SELECT u.id, u.account, u.name, u.enabled, u.source, u.account_type,
       GROUP_CONCAT(DISTINCT r.name ORDER BY r.name) AS all_roles
FROM safe.casbin_rule cr
JOIN safe.users u ON u.id = cr.v0
LEFT JOIN safe.casbin_rule cr2 ON cr2.ptype=\"g\" AND cr2.v0 = u.id
LEFT JOIN safe.roles r ON r.id = cr2.v1
WHERE cr.ptype=\"g\" AND cr.v1=\"b5f9ac3e-992c-4bbd-8126-95e87e51c46e\"
GROUP BY u.id, u.account, u.name, u.enabled, u.source, u.account_type
ORDER BY u.account;"
echo "--- 总用户数（含停用）---"
mariadb -h 10.67.51.9 -u openbkn --batch --raw \
  -e "SELECT COUNT(*) AS total, SUM(enabled) AS enabled FROM safe.users;"
' 2>&1 | tee "$W/reports/normal-user-impact.txt"
unset DB_PW
```

**判读**（把这张表贴回来一起看）：

| 看到什么 | 含义 |
| --- | --- |
| `all_roles` 里**只有** `normal_user` | ⚠️ **升级后这些人只剩平台基本登录**，技能/模型/agent 全没了。最需要处理 |
| `all_roles` 里还有 `network_builder` / `admin` 等 | 影响小得多，他们还有其他角色的授权兜底 |
| `account_type` 是 `app` | ⚠️ 系统/集成账号，**升级会直接断掉它对接的外部系统**，必须提前知会 |
| `account_type` 是 `other` | 本地人类账号的默认值，属常规情况 |
| 名单里有**停用**账号 | `enabled=0`，优先级低，但记下来 |

> **本环境的实测结果（2026-10-16，已填）**：12 人受影响，**全库只有 14 个用户**；
> 12 人**全部**另有 `network_builder`，其中 1 人另有 `admin`；`account_type` 全为 `other`。
> → 属于上表第 2 行，**不需要提前调整授权**，改为在 P5.7② 实测确认。
> 详见 §2.2。

> **名字显示成 `???` 不是数据问题**，是 `mariadb` 客户端的字符集。要看清中文名加
> `--default-character-set=utf8mb4`。

> **这批人不会被自动补偿**：0.1.5 的 5 个角色没有一个授予
> `skill/mcp/tool_box/operator` 的 `view`/`execute`、`agent` 的 `use`、模型的 `display`/`execute`
> （§2.2 有逐条对比）。0.1.5 改用**对象级 + 公共授权**（`PublicAccessorID` 全零 UUID）
> 承接这批能力——**是否覆盖完整只能在 P5.7② 实测**。
> **不要手工往 `casbin_rule` 插回那 7 条策略**（会绕过 `authorization_grant` 台账）。

**P1 完成判定**：P1.2 状态可查、P1.3 容器可用、P1.4 无 `no_creator`、P1.5 四份备份齐、P1.6 十五个 chart 齐、**P1.10 基线复核逐项通过**（含 `depServices.rds` 和**镜像逐节点覆盖**那两项）、**P1.11 名单已拿到并已决定处置方式**。**到此为止都没有停过机。**

> **备份时效**：P1.5 若是在复核前好几天做的，期间的业务写入不在备份里。要么重跑 P1.5，要么接受"恢复到数天前"的粒度。**这个取舍在进窗口前明确记下来**，别等出事才发现备份是旧的。

**这一步的输出留好**——P5.5 的收尾检查要拿它对比。

> 进窗口前再确认一次这条**硬约束**：**绝不能跑 `deploy.sh k8s reset`**——集群上还有你其他业务在跑，reset 会清整个命名空间乃至更广的范围。本次升级的任何一步都不需要它。

---

## 4. P2 维护窗口

> ⚠️ **从这里开始停机。以下步骤必须连续做完，不要在中间过夜。**

**本窗口的固定顺序**（与原 runbook 不同，见 §2.5）：

```
P2.1 挂起 CronJob
P2.2 封住对外入口
P2.3 部署 0.1.5            ← 建出迁移所需的全部新表
                              ★ bkn-safe 的 Pod 会 CrashLoop —— 预期，别修（helm 状态见 §2.2）
P2.4 ★硬闸：确认新表就位
P2.5 停业务（migrate.py stop）
P2.6 ★硬闸：权限迁移 dry-run 并审核
P2.7 ★硬闸：权限模型迁移 apply（写迁移标记）
P2.8 网络构建者范围回填（★ 需先打一行补丁；本次止于 dry-run，见下）
P2.9 恢复业务（migrate.py start）  ← bkn-safe 到这里才真正起来
P3   授权冒烟 → 开放入口
```

**三个 ★ 硬闸（P2.4 / P2.6 / P2.7）不通过就不要往下走；任何一个失败都按 §6 回滚。**

**全程需要预判的两个「像故障的正常现象」**（细节见 P2.3）：
1. `bkn-safe` release 显示 `✗ Failed to install bkn-safe`，Pod `CrashLoopBackOff`，约 600s 后被跳过；
2. 部署因此比预期慢 ~10 分钟。

### P2.1 挂起 CronJob

```bash
kubectl -n openbkn get cronjob
kubectl -n openbkn patch cronjob bkn-backend-trace-outbox-cleanup    -p '{"spec":{"suspend":true}}'
kubectl -n openbkn patch cronjob ontology-query-trace-outbox-cleanup -p '{"spec":{"suspend":true}}'
kubectl -n openbkn get cronjob     # SUSPEND 应为 True
```

**预期**：两个 CronJob 的 `SUSPEND` 变成 `True`。

### P2.2 封住对外入口（**推荐做法 —— 本次未执行**）

> **⚠️ 2026-10-16 事后确认：这一步在你的实际窗口里没有做。** 入口全程开放，
> 从 P2.3 一直可达。事后评估见 **§7 第 3 条** —— 没有观测到问题，但那是 bkn-safe
> 起不来顺带挡住的结果，**不是这一步挡住的结果**。
> 下面保留原样作为**推荐做法**（给下次或给别人用），但**不要把它读成已发生的事实**。

**为什么必须显式做这一步**：chart 里是 `replicas: {{ .Values.replicaCount }}`，所以 P2.3 的 `helm upgrade` 会**直接把 Pod 拉起来**。官方 README 要求的「在外部入口仍关闭的情况下启动新版本、完成冒烟」这套拓扑下不会自动成立，必须手工封。

**为什么不能停控制器**：`nginx-hw-public` 是 matrix 平台的 DaemonSet（`nodeSelector: matrix.ingress=hw-public`），是全集群公共入口，**不能动**。

**做法**：改你自己建的那两份 Ingress，把路径指向一个不存在的后端 → 该域名返回 503。

> ⚠️ **不能直接删这两份 Ingress**：删掉之后域名会回落到平台那 11 份无 host 的 Ingress（catch-all），流量照样通，等于没封。必须保留 host 声明、只换后端。

```bash
# 备份现状（回退用）
kubectl -n openbkn get ingress hw-public-openbkn.changhong.com-443        -o yaml > "$W/backup/ing-443.yaml"
kubectl -n openbkn get ingress hw-public-openbkn.changhong.com-443-studio -o yaml > "$W/backup/ing-443-studio.yaml"

BLOCK='[{"op":"replace","path":"/spec/rules/0/http/paths","value":[{"path":"/","pathType":"Prefix","backend":{"service":{"name":"bkn-maintenance-block","port":{"number":1}}}}]}]'
kubectl -n openbkn patch ingress hw-public-openbkn.changhong.com-443        --type=json -p "$BLOCK"
kubectl -n openbkn patch ingress hw-public-openbkn.changhong.com-443-studio --type=json -p "$BLOCK"
```

**验证已封住**：

```bash
curl -sk -o /dev/null -w 'studio:%{http_code}\n' https://openbkn.changhong.com/studio
curl -sk -o /dev/null -w 'api:%{http_code}\n'    https://openbkn.changhong.com/api/safe/v1/capabilities
```

**预期**：两条都是 `503`（不再是 `200` / `401` / `308`）。**出现 200/301/302/401 说明没封住，停下检查。**

### P2.3 部署 0.1.5（这一步同时把迁移需要的新表建出来）

**为什么部署排在这里，而不是原来的「迁移完再部署」**：见 §2.5。一句话——dry-run 就要求
0.1.5 的表存在，而表只有部署这一步会建。

```bash
cd /opt/bkn-foundry/deploy
export OPENBKN_SKIP_PLATFORM_BOOTSTRAP=true
export OPENBKN_SKIP_DATA_SERVICES_BUNDLE=true

# ★ 开跑前自检：必须各输出一行。没有就先别跑（见 §6.8）
env | grep OPENBKN_SKIP

bash ./deploy.sh \
    --config=/opt/bkn-foundry/my-config.yaml \
    --force-upgrade \
    openbkn install \
    --version=0.1.5 \
    --version_file=/opt/bkn-foundry/deploy/release-manifests/0.1.5/bkn-foundry.yaml \
    --charts_dir=/opt/bkn-charts \
    --access_address=https://openbkn.changhong.com
```

> ⚠️ **不要写成 `VAR=x \` 续行格式。** 逐行粘贴时续行会失效，两行退化成孤立赋值，
> 脚本看不到这两个变量 → **它会去装 MariaDB/Redis/Kafka/OpenSearch，并且重写
> `my-config.yaml`**。2026-10-16 真实踩过，见 §6.8。

> **参数位置不是随意的**。`deploy.sh` 分两段解析（`deploy.sh:447-471` 模块前、`openbkn.sh:40-115` 模块后）：
> `--config` / `--force-upgrade` 只在前段识别，`--version` / `--version_file` / `--charts_dir` 只在后段识别。放错位置会被静默忽略。
>
> **三个必须坚持的点**：
> 1. **两个 `OPENBKN_SKIP_*` 都要给**。只给第一个，脚本仍会补装整个数据服务捆绑包（MariaDB / Redis / Kafka / OpenSearch），把外置方案覆盖掉。
> 2. **`--version=0.1.5` 和 `--version_file` 同时给**。只给 `--version` 会去找 `0.1.5/bkn-foundry.yaml`（我们已经补上，所以能解析），同时给 `--version_file` 让脚本额外校验 manifest 里的 `version` 字段与预期一致（`common.sh:605`），双保险。
> 3. **绝对不能漏 `--version_file` / `--version`**。不带版本参数时脚本走「取最新 manifest」逻辑（`openbkn.sh:1686`），你本地最新的是 **0.1.4**——会**原地重装一遍 0.1.4**，停机两小时后发现版本没变。

> **⚠️ 部署一跑就回不了头**：pre-stage migrator 会执行
> `migrations/bkn-backend/mariadb/0.1.5/01-remove-business-domain.sql`，
> 其中 `ALTER TABLE t_knowledge_network DROP COLUMN f_business_domain`。
> 0.1.4 的 bkn-backend **显式 SELECT 这一列**
> （`knowledge_network_access.go:160,223,362`），所以一旦执行完，
> **回 0.1.4 就必须连 `openbkn` 库一起恢复**（见 §6.5）。
> 确认 P1.5 的四份备份可用之后再按回车。

**预期顺序**（留意日志里的 release 名，它们是有序的）：

1. `core-data-migrator` —— 锁文件里排第一个（`stage: pre`），Job 带
   `helm.sh/hook: pre-install,pre-upgrade`，跑 `data-migrator.py migrate`，
   对 `openbkn` 库应用 `migrations/bkn-backend/mariadb/0.1.5/{01..05}.sql`。
   **这一步会消费掉 P1.10 里警告的「MANUAL SQL INITIALIZATION REQUIRED」——建表实际由它完成，不需要你手工导 SQL。**
2. `bkn-safe` —— **Pod 会 CrashLoopBackOff，这是预期行为，不要修。**
   - 进程起来后先跑 `AutoMigrate(model.AllModels()...)`（`database.go:65`），
     **建出** `managed_proxy_accounts` / `proxy_grant_source` / `proxy_grant_policy` / `authorization_grant` —— 我们要的表在这一刻就有了（MySQL DDL 自动提交，进程随后退出不影响它）。
   - 紧接着 `Run()` 调 `ensureAuthorizationMigrationReady`（`app.go:212`）。
     此时**迁移标记还不存在**，于是返回 `ErrMigrationMarkerRequired` → 进程**直接退出**
     → CrashLoopBackOff。`Run()` 里的原话：「an upgraded store still needs the
     offline marker before any listener can accept traffic」（`app.go:209-211`）——
     **这是刻意的 fail-closed：没迁移完，bkn-safe 一个请求都不接。**
   - `bkn-safe` 会在 **P2.7 写入标记之后自愈**（重启时标记已在，`Run()` 通过）。
   - **helm release 的状态取决于你这份脚本版本**：
     - v0.1.5 版脚本给本地 chart 路径传了 `--wait --timeout=600s`（`openbkn.sh:1135`），
       于是会**白等约 600s 然后标成 `failed`**，且安装循环不检查返回码（`openbkn.sh:1512-1519`），后面的 release 照常装。
     - **0.2.0 时期的脚本没有 `--wait`**，helm 不等就返回 → release 显示 `deployed`，
       整轮约 1 分钟。2026-10-16 在 master1 上实测走的是**后者**。
     - **两种情况都不影响结论**：看 `kubectl -n openbkn get pods` 里 `bkn-safe` 是不是
       CrashLoopBackOff，而不是看 helm 状态。
3. **`bkn-backend` 也会 CrashLoop（`panic`），这是 bkn-safe 的连带故障**（2026-10-16 实测并逐层查实）：

   ```
   bkn-backend Init（启动时 "Init BKN Dataset"）
     → vega GET /api/vega-backend/in/v1/catalogs/adp_bkn_catalog
        → catalog_service.GetByIDs（catalog_service.go:526）
           → cs.ps.FilterVisibleResourcesWithOperations(...)   （:552）
              → safeClient.filterResources
                 → POST http://bkn-safe/api/safe/v1/authz/resource-filter
                 → bkn-safe 不可用 → err
           → return nil, err                                   （:556-558）
        → httpErrorOrInternal → HTTP 500
     → panic: GetCatalogByID returned HTTP 500
   ```

   依据：`adp/vega/vega-backend/server/drivenadapters/permission/safe_permission_access.go:22`
   （`// safeClient talks to bkn-safe's clean authz API (/api/safe/v1/authz/*)`）、
   `:104-124`（`filterResources` → `/api/safe/v1/authz/resource-filter`）。

   **它同样在 P2.7 之后自愈**（bkn-safe 起来 → 权限过滤通过 → 返回 200）。
   `vega-backend` 自己**日志干净**——`replyError` 不打 error 级日志，所以别按 vega 日志判断，
   按 `kubectl -n openbkn get pods` 里 bkn-backend 是不是 CrashLoop 判断。

   > **判别要点**：404 不会 panic（`vega_backend_access.go:109-112` 把 404 当成
   > 「目录不存在，去创建」返回 `nil, nil`）。**只有 500 才 panic** —— 所以看到 panic
   > 就说明 vega 侧真的出错了，不是「catalog 不存在」。
4. 其余 12 个 release 正常。另外会多出一个 `install-status-*` Pod（脚本发布的安装状态页）。

```bash
kubectl -n openbkn get pods
helm list -n openbkn
```

**预期**：`helm list` 里 15 个 release 的 CHART 列全部是 `0.1.5`，**STATUS 全部是 `deployed`**
（你的脚本没有 `--wait`，helm 不等待 rollout，不会因 `bkn-safe` 的 CrashLoop 标成 `failed` —— 2026-10-16 实测如此）；
Pod 方面 `bkn-safe-*` 处于 `CrashLoopBackOff`（**预期**），其余 Pod Running，`core-data-migrator-job-*` 为 Completed。

**□ 判定表**：

| 现象 | 判定 |
| --- | --- |
| `bkn-safe` Pod `CrashLoopBackOff`（release 状态仍是 `deployed`） | ✅ **预期**，继续。日志里应能看到 `authorization migration gate: current authorization migration marker required` |
| `bkn-safe` Pod 里连 **AutoMigrate 都没跑**（日志停在更早的错误） | ❌ 真故障。查 `kubectl -n openbkn logs deploy/bkn-safe --previous` |
| 除 `bkn-safe` 外还有别的 release `failed` | ❌ 贴日志回来，按 §6.4 判断 |
| `core-data-migrator` 的 Job 没跑到 `Completed` | ❌ 硬故障，按 §6.4 |

**此时 `replicas` 被 chart 重置为 1，Pod 会带着新镜像起来。** 这是**有意接受**的暴露，
窗口 ≈ **整轮部署时长**（实测约 1 分钟；v0.1.5 脚本约 15 分钟），不是几秒钟：

- ~~入口已封（P2.2），外部没有流量，不会产生新的业务写入；~~
  **⚠️ 本条款本次不成立** —— P2.2 未执行，入口全程开放。**这条缓解措施不能计入**，
  实际暴露与评估见 §7 第 3 条；
- bkn-safe **根本不接请求**（上面那条 fail-closed），授权面没有暴露；
- 且它**不会**把你这套当成全新安装而跳过迁移：`IsFreshAuthorizationStore()` 只认
  「`casbin_rule` 表不存在」为全新信号（`gate.go:50-54`），而你的 `casbin_rule`
  存在（316 行 p 策略）→ `wasFresh=false` → `SeedFreshInstallMarker` 拒绝写标记，
  转而要求迁移（`gate.go:87-89`）。**不会静默跳过迁移。**

**真故障就停下**：不要手工补 SQL、不要改标记、不要手工把 release 标成 deployed，贴日志回来。回滚见 §6.4。

> **可以重跑**。这套 SQL 全部写成幂等形式（`CREATE TABLE IF NOT EXISTS`、
> `ALTER TABLE … ADD/DROP COLUMN IF [NOT] EXISTS`），且 `deploy.sh openbkn install
> --force-upgrade` 本身支持重复执行（`FORCE_UPGRADE=true` 会让
> `should_skip_upgrade_same_chart_version` 永不跳过，`common.sh:993-996`）。
> 所以修好原因后**直接重跑 P2.3** 是安全的，不需要先回滚。
> 唯一例外：若决定**放弃升级回 0.1.4**，那必须先按 §6.5 恢复 `openbkn` 库。

### P2.4 ★ 硬闸：确认新表已就位

**不通过就不要往下走。** 这一步用 P2.3 之前的同一套凭据做纯只读检查。

```bash
read -rsp 'MariaDB 口令（用户 openbkn）: ' DB_PW; echo; export DB_PW
docker run --rm --network host -e DB_PW bkn-migrate:0.1.5 bash -lc '
export MYSQL_PWD="$DB_PW"
echo "===== safe 库应有 8 张 ====="
mariadb -h 10.67.51.9 -u openbkn --batch --raw -e "
SELECT want.table_name AS tbl,
       CASE WHEN t.table_name IS NULL THEN \"❌ 缺\" ELSE \"✅\" END AS ok
FROM (SELECT \"users\" AS table_name UNION ALL SELECT \"managed_proxy_accounts\"
      UNION ALL SELECT \"proxy_grant_source\" UNION ALL SELECT \"proxy_grant_policy\"
      UNION ALL SELECT \"authorization_grant\" UNION ALL SELECT \"casbin_rule\"
      UNION ALL SELECT \"resource_parents\" UNION ALL SELECT \"operations\") want
LEFT JOIN information_schema.tables t
  ON t.table_schema=\"safe\" AND t.table_name=want.table_name;"
echo "===== openbkn 库应有 3 张 ====="
mariadb -h 10.67.51.9 -u openbkn --batch --raw -e "
SELECT want.table_name AS tbl,
       CASE WHEN t.table_name IS NULL THEN \"❌ 缺\" ELSE \"✅\" END AS ok
FROM (SELECT \"t_kn_proxy_account\" AS table_name
      UNION ALL SELECT \"t_kn_capability_binding\"
      UNION ALL SELECT \"t_kn_proxy_published_grant_source\") want
LEFT JOIN information_schema.tables t
  ON t.table_schema=\"openbkn\" AND t.table_name=want.table_name;"
echo "===== 迁移标记表：此刻应当还不存在 ====="
mariadb -h 10.67.51.9 -u openbkn --batch --raw -e "
SELECT CASE WHEN COUNT(*)=0 THEN \"✅ 尚不存在（正确）\" ELSE \"❌ 已存在，停下\" END AS marker
FROM information_schema.tables
WHERE table_schema=\"safe\" AND table_name=\"authorization_migration_marker\";"
'
unset DB_PW
```

> **注意这里查的是「表存不存在」，不是 `COUNT(*)`。** `authorization_migration_marker`
> **不在** bkn-safe 的 `AllModels()` 里（`model.go:474-482`），它只由
> `persistFreshMarker`（全新安装，`gate.go:254`）或 `authz-migrate`（我们的 P2.7）
> 创建。所以在 P2.4 这一刻它**必然不存在**——直接 `SELECT COUNT(*) FROM
> safe.authorization_migration_marker` 会报 1146，那是查法问题，不是故障。

**逐项判定**：

| 项 | 必须满足 | 不满足怎么办 |
| --- | --- | --- |
| `safe` 8 张 | 全部 `✅` | 缺 `authorization_grant` 等 → bkn-safe 没跑到 AutoMigrate，`kubectl -n openbkn logs deploy/bkn-safe --previous` |
| `openbkn` 3 张 | 全部 `✅` | 缺 → pre-stage migrator 没成功，查 `kubectl -n openbkn get jobs` / `logs job/core-data-migrator-job` |
| marker 表 | **「尚不存在」** | 显示「已存在」= 有东西替你做完了迁移的记账。**立刻停下贴回来**，不能带这个状态往下走 |

### P2.5 停业务

```bash
cd /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5/permission_model_transition
read -rsp 'MariaDB 口令（用户 openbkn）: ' DB_PW; echo; export DB_PW

docker run --rm --network host -e DB_PW \
  -v /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5:/work:ro \
  -v "$W":/state -v /root/.kube:/root/.kube:ro \
  -v /usr/local/bin/kubectl:/usr/local/bin/kubectl:ro \
  bkn-migrate:0.1.5 bash -lc '
python3 /work/permission_model_transition/migrate.py stop \
  --namespace openbkn \
  --state-file /state/workloads.tsv \
  --expected-context kubernetes-admin@hw.local
'
unset DB_PW
```

> `kubectl` 是从宿主机只读挂进容器的（静态 Go 二进制，任何 Linux 容器都能跑），kubeconfig 同理。

**预期**：五个 Deployment 依次缩到 0，并写出 `/var/lib/docker/bkn-upgrade-0.1.5/workloads.tsv`。

```bash
kubectl -n openbkn get deploy vega-backend ontology-query agent-operator-integration bkn-backend bkn-safe
```

**预期**：五个的 READY 都是 `0/0`。

> 这一停，P2.3 那段「新版本跑在旧数据上」的暴露窗口就结束了。
> `bkn-safe` 那个 CrashLoop 的 Pod 也随 `--replicas=0` 一起消失。
> `stop` 每个 Deployment 最多等 300s（`service_control.sh:243-259`）。

### P2.6 ★ 硬闸：权限迁移 dry-run 并审核

**这是整个方案最重要的一道闸。** dry-run 不写任何业务数据。

> 原 P1.8。移到这里是因为它要求 0.1.5 的表已存在（那时还没有，现在有了）。

> **★ 两个必踩的坑（2026-10-16 实测）：**
>
> **① `--report-dir` 必须是空目录。** `prepare_report_directory`（`migrate.py:91-96`）
> 见到非空就报 `report directory is not empty`。而**失败时它会往里面写一份
> `summary.json`**（`:241`）——所以**任何一次失败重跑前都要先把旧目录移走**：
>
> ```bash
> mv "$W/reports/p2-dry-run" "$W/reports/p2-dry-run.failed-$(date +%Y%m%d-%H%M%S)"
> ```
>
> 这是它在保护既有证据，不是故障。`apply` 用的 `p2-apply` 同理。
>
> **② 密码变量不是 `MYSQL_PWD`。** 两个消费者读的是不同的名字：
>
> | 谁 | 读什么 |
> | --- | --- |
> | Python 步骤（`bkn_data.py` / `vega_data.py`） | `BKN_DB_PASSWORD`（`bkn_data.py:1826-1829`）；`SAFE_DB`/`VEGA_DB` 都以 `BKN_DB` 为 fallback（`vega_data.py:457-460`） |
> | Go 二进制 `authz-migrate` | `SAFE_DB_PASSWORD`（`authz_migrate/config.go:59`） |
> | ~~`MYSQL_PWD`~~ | **谁都不读**——它是脚本调 `mariadb-dump` 时**设给子进程**的（`bkn_data.py:2034-2037`） |
>
> 用错会报 `Access denied for user 'openbkn'@'<客户端IP>' (using password: NO)`。
> **顺带**：那个 IP 是**客户端**地址（容器用 `--network host`，所以是宿主机自己的 IP），
> 不是目标库地址——能走到口令校验说明网络和 host 授权都没问题。

```bash
read -rsp 'MariaDB 口令（用户 openbkn）: ' DB_PW; echo; export DB_PW

docker run --rm --network host -e DB_PW \
  -v /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5:/work:ro \
  -v "$W/reports":/reports -v "$W/authz-migration.json":/manifest.json:ro \
  bkn-migrate:0.1.5 bash -lc '
export SAFE_DB_HOST=10.67.51.9 SAFE_DB_PORT=3306 SAFE_DB_USER=openbkn SAFE_DB_NAME=safe
export BKN_DB_HOST=10.67.51.9  BKN_DB_PORT=3306  BKN_DB_USER=openbkn  BKN_DB_NAME=openbkn
export VEGA_DB_HOST=10.67.51.9 VEGA_DB_PORT=3306 VEGA_DB_USER=openbkn VEGA_DB_NAME=openbkn
export BKN_DB_PASSWORD="$DB_PW"     # ★ Python 步骤（bkn-data / vega-data）读这个
export SAFE_DB_PASSWORD="$DB_PW"    # ★ Go 二进制 authz-migrate 读这个
python3 /work/permission_model_transition/migrate.py dry-run \
  --source-version 0.1.4 \
  --manifest /manifest.json \
  --authz-migrator /work/permission_model_transition/authz_migrate/authz-migrate \
  --report-dir /reports/p2-dry-run
'
unset DB_PW

ls -l "$W/reports/p2-dry-run/"
```

**预期**：生成 `01-bkn-data.json`、`02-vega-data.json`、`03-authorization.json`、`summary.json`。

**审核要点**（把四份报告贴回来一起看）：

> ⚠️ `summary.json` 的 `completed: true` **只表示报告文件非空**。它没有 `anomalies` 字段，
> 也不代表「没有异常」。真正的判据在每个步骤自己的报告里，而且三份的「失败语义」各不相同：
>
> | 报告 | 失败时的行为 | 含义 |
> | --- | --- | --- |
> | `01` | `bkn_data.py:2254` 在任何 failure 上先 `raise` | **文件存在 ⇒ 零 failure** |
> | `02` | `vega_data.py:472` **先写报告再 raise** | 文件可能存在且带 failures，**必须自己看** |
> | `03` | `main.go` 里 `if mode == modeDryRun { return report, nil }` | **anomaly 完全不会让命令失败**，必须人读 |

1. `01-bkn-data.json`：`managed_proxies.skipped_skill_grants` 为 `0`；`archived_tombstones` 为空；
   `networks` / `sources` 数量与知识网络数吻合。
2. `02-vega-data.json`：`failures` 为空、`failure_summary` 为 `{}`；`catalogs.creator_grants` 与
   P1.4 的非内置目录数吻合；`creator_accounts_skipped` 空（有值 = 创建者账号已删，属正常跳过）；
   `resource_parents.hidden_resources_skipped` 非 0 属正常（无目录归属的资源行）。
3. `03-authorization.json`：**`core.anomalies` 必须为空**；`core.summary` 看分类计数；
   `enterprise.ee_table_state` 应为 `absent`、`ee.summary.rows` 为 `0`、`ee.anomalies` 为空。

**`core.anomalies` 非空就不要往下走。**有异常就贴回来，我们改 manifest 或先处理数据，不要硬上。

> 如果这里报 `bkn-safe 0.1.5 schema is unavailable; missing tables: ...` 或
> `BKN 0.1.5 schema is unavailable; missing tables: ...`，说明 P2.3/P2.4 没真正建全表，
> **退回 P2.4 排查**，不要绕过。

### P2.7 ★ 硬闸：权限模型迁移（apply，写迁移标记）

> **执行顺序：本步在 P2.8 回填之前。** 官方 `permission_model_transition/README.zh.md`
> 把 `dry-run → stop → apply` 定义为中间不插任何写入的序列，而回填写的是本迁移要 plan 的
> `authorization_grant` + `casbin_rule`。插在中间，你在 P2.6 批准的那份 dry-run 就不再等于
> apply 的状态。放在前面两边证据都干净，而且迁移面对的正是我们刚审过的原始 0.1.4 状态
> （`kept: 0 / classified: 311 / removed: 5`），走最受测的那条路径。

```bash
read -rsp 'MariaDB 口令（用户 openbkn）: ' DB_PW; echo; export DB_PW

docker run --rm --network host -e DB_PW \
  -v /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5:/work:ro \
  -v "$W":/state -v "$W/reports":/reports -v "$W/authz-migration.json":/manifest.json:ro \
  -v /root/.kube:/root/.kube:ro -v /usr/local/bin/kubectl:/usr/local/bin/kubectl:ro \
  bkn-migrate:0.1.5 bash -lc '
export OPENBKN_MIGRATION_BACKUP_DIR=/state/backup
export SAFE_DB_HOST=10.67.51.9 SAFE_DB_PORT=3306 SAFE_DB_USER=openbkn SAFE_DB_NAME=safe
export BKN_DB_HOST=10.67.51.9  BKN_DB_PORT=3306  BKN_DB_USER=openbkn  BKN_DB_NAME=openbkn
export VEGA_DB_HOST=10.67.51.9 VEGA_DB_PORT=3306 VEGA_DB_USER=openbkn VEGA_DB_NAME=openbkn
export BKN_DB_PASSWORD="$DB_PW"     # ★ Python 步骤（bkn-data / vega-data）读这个
export SAFE_DB_PASSWORD="$DB_PW"    # ★ Go 二进制 authz-migrate 读这个
python3 /work/permission_model_transition/migrate.py apply \
  --source-version 0.1.4 \
  --manifest /manifest.json \
  --authz-migrator /work/permission_model_transition/authz_migrate/authz-migrate \
  --state-file /state/workloads.tsv \
  --namespace openbkn \
  --expected-context kubernetes-admin@hw.local \
  --report-dir /reports/p2-apply
'
unset DB_PW
```

> ⚠️ `--report-dir /reports/p2-apply` **必须是一个还不存在（或空）的目录**（`migrate.py:91-96`）。
> 重跑前先把旧目录移开：
> `mv "$W/reports/p2-apply" "$W/reports/p2-apply.failed-$(date +%Y%m%d-%H%M%S)"`

**预期**：`apply` 先复核五个 Deployment 仍在停止状态；BKN 步骤在首次写入前生成并校验 BKN + Safe 的完整逻辑备份；然后依次跑 bkn-data → vega-data → authorization，最后写入带校验和的迁移标记。`03-authorization.json` 里会多出 `marker` 段。

**验证标记已写入**：

```bash
read -rsp 'MariaDB 口令: ' DB_PW; echo; export DB_PW
docker run --rm --network host -e DB_PW bkn-migrate:0.1.5 bash -lc \
  'export MYSQL_PWD="$DB_PW"; mariadb -h 10.67.51.9 -u openbkn --batch --raw \
   -e "SELECT version, ee_table_state, core_policy_count, core_grant_count, checksum, applied_at FROM safe.authorization_migration_marker;"'
unset DB_PW
```

**预期**：一行，`checksum` 非空。**任一步失败都不要继续**——按 §6 回滚。

> **✅ 本次实测（2026-10-16）：apply 成功，标记已写入。**
>
> - 标记一行就位，`checksum` 非空且**两端一致**；`core_policy_count` / `core_grant_count` 各 **345**。
> - **345 可精确对账**：311（P2.6 dry-run 的 `classified`）+ 30（代理策略）+ 4（vega 创建者授权）。
>   `03-authorization.json` 里 `CoreSourceSummary` = `{"community_bundle":2, "legacy":178,
>   "role_permission":133, "system_derived":32}`，合计 345。
> - **执行中的唯一插曲**：我给的校验 SQL 用了 `migration_version`，而真实列名是 `version`
>   （GORM 侧 `Where("version = ?", ...)`），于是报 `ERROR 1054 Unknown column`。
>   **报这个错反而证明 apply 成功了** —— 表存在才会有「列名错」这种报错。
>   上面那条 SQL 已是修正后的版本。
> - 未走路：**没有**任何一步失败，**没有**用到 §6.2 / §6.3。

### P2.8 网络构建者范围回填（★ 需先打一行补丁）

**为什么排在 apply 之后**：两个包为 Catalog 生成的创建者授权是**同一个 `grant_id`** ——
回填的 `projection_key` 与 vega 的 `stable_key` 都是
`sha256("\x00".join((accessor, object, operation, effect, policy_source, authority_source)))`，
加上回填用 `INSERT ... ON DUPLICATE KEY UPDATE grant_id = grant_id`，两边天然幂等、不会冲突。
所以顺序可以自由选；选 apply 在前，是为了保住 P2.6 那份已批准的 dry-run 证据。
回填在 apply 之后只会报 Catalog `keep` + 知识网络 `insert`，**顺带验证两个包的结果一致**。

> **★ 上游 bug：这个包读的列名没跟着改名走**
>
> `backfill_creator_grants.py:128` 读 `SELECT ... f_internal FROM t_catalog`，但
> `migrations/vega-backend/mariadb/0.1.5/09-add-resource-internal.sql` 已经把它
> `RENAME COLUMN f_internal TO f_builtin` —— 而这条迁移在 P2.3 就由 pre-stage migrator 跑过了
> （你库里 `t_resource.f_builtin` 存在就是硬证据，它也是 09 加的）。**不打补丁直接跑会
> `Unknown column 'f_internal' in 'field list'`。**
>
> 上游 `#1656`（2026-09-18 改名重构）改了全仓库引用，唯独漏了
> `deploy/scripts/upgrades/0.1.5/network_builder_scope/` 这个包（`#1534`，09-13 加入）。
> **2026-10-16 已核实到新仓库**：`openbkn-deploy@main` 与 `@release/0.1.5` 上路径是
> `scripts/upgrades/0.1.5/network_builder_scope/backfill_creator_grants.py`（`deploy/` 前缀已去掉），
> 文件与移出前**逐字节一致**，第 128 行仍是 `f_internal`。
> 这是同一次 RENAME，列值语义完全一致，所以改一个词即可。
>
> **为什么你必须打这个补丁**：包内 README 要求「**部署前**跑回填」（`README.md` 第 3 行），
> 但那个顺序**实际不可行** —— 脚本还要查 `authorization_grant`，而该表在 0.1.4 的库里
> **不存在**（v0.1.4 全仓库 0 命中，也没有任何 SQL 建它；它只由 0.1.5 bkn-safe 启动时的
> GORM `AutoMigrate` 创建）。本方案的顺序是**部署在前**（§7 第 2 条），
> `09-add-resource-internal.sql` 在 P2.3 就由 pre-stage migrator 跑过了，所以列名已经变了。
> **两种顺序都会失败，只有「部署后跑 + 本补丁」能通。** 详见 issue 草稿 B。

**第一步：打补丁**

```bash
cd /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5/network_builder_scope
/bin/cp -a backfill_creator_grants.py backfill_creator_grants.py.orig   # 不能写 cp，root 的 cp 是 cp -i
sed -i 's/f_internal FROM t_catalog/f_builtin FROM t_catalog/' backfill_creator_grants.py
diff backfill_creator_grants.py.orig backfill_creator_grants.py
```

✅ diff 只应有一处 `128c128`：`f_internal` → `f_builtin`。多出任何一处就停下贴回来。

**第二步：dry-run**（原 P1.9）

```bash
read -rsp 'MariaDB 口令（用户 openbkn）: ' DB_PW; echo

# DSN 里的口令必须 URL 编码：脚本用 urlparse 解析，口令含 @ : / # ? 会直接解析错位
DB_PW_ENC=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$DB_PW")
export BKN_DSN="mysql://openbkn:${DB_PW_ENC}@10.67.51.9:3306/openbkn"
export SAFE_DSN="mysql://openbkn:${DB_PW_ENC}@10.67.51.9:3306/safe"

docker run --rm --network host \
  -v /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5/network_builder_scope:/nb:ro \
  -v "$W/reports":/reports \
  -e BKN_DSN -e SAFE_DSN \
  bkn-migrate:0.1.5 \
  python3 /nb/backfill_creator_grants.py --mode dry-run \
    --bkn-dsn "$BKN_DSN" --safe-dsn "$SAFE_DSN" 2>&1 | tee "$W/reports/p2-backfill-dryrun.txt" | tail -40
unset DB_PW DB_PW_ENC BKN_DSN SAFE_DSN
```

> ⚠️ **DSN 必须带 `mysql://` 前缀**。脚本的 `parse_mysql_dsn`（`backfill_creator_grants.py:104-107`）用 `urlparse` 校验 scheme，写成 `user:pw@host:port/db` 会直接报 `DSN must be mysql://user:password@host:port/database`。

**预期**：`summary` 为 `{"block": 2, "keep": 2, "skip": 2}`（共 6 项）：

| 资源 | 数量 | 判定 | 原因 |
| --- | --- | --- | --- |
| Catalog `adp_bkn_catalog` / `bkn_execution_factory_catalog` | 2 | `skip` | 内置（`f_builtin=1`） |
| Catalog `db3l4i4hujr6ann6svfg` / `db551mshujr6ann714n0` | 2 | `keep` | P2.7 的 vega 步骤已建过同样的两条授权 |
| 知识网络 `dev_know_net` / `honglian_eadp_dev` | 2 | `block` | `partial direct creator grant` —— **只缺 `execute`，见第三步** |

出现 `block` 时**不要**直接认定是故障 —— 先按第三步复核。`block` 的四种 reason
（`missing f_creator` / `creator is not a user` / `creator is absent from bkn-safe users` /
`partial direct creator grant`）里，只有第一种和第三种可能需要动数据。

> 顺带解释 P2.6 报告里那 5 条 `remove`：它们的 `object` 全是 `knowledge_network:*` / `knowledge_network:<id>`，
> `operation` 全是 `task_manage`。而本脚本对 `knowledge_network` 的期望集合是
> `{view_detail, modify, delete, query_data, execute, authorize}` —— **不含 `task_manage`**。
> 边界的退役与回填的期望值严丝合缝，说明这 5 条删除是设计而非数据问题。
> 注意 Catalog 那一侧是**保留** `task_manage` 和 `resource_manage` 的。

**第三步：`apply` —— 本次为「跳过」，理由如下**（2026-10-16 决策）

> **实测：`summary = {"block": 2, "keep": 2, "skip": 2}`，两个知识网络被
> `partial direct creator grant` 拦下。经审阅，这是回填在正确地保护数据，不是故障，
> 所以本次止于 dry-run、不写任何数据。**
>
> 复核过的三项事实：
>
> 1. **缺的只有一个 operation：`execute`。** 两个创建者各持 6 条直接授权
>    （`view_detail / create / modify / delete / query_data / authorize`），而期望集合 = 
>    `community_bundle.go` 里 `community_bundleOperations["knowledge_network"]`
>    （`{view_detail, modify, delete, query_data, execute}`）加单独授予的 `authorize`
>    —— 只多这一个。
> 2. **`execute` 在 0.1.4 里从未授予过任何人。** P2.6 的迁移前快照里，连 `network_builder`
>    角色（policy 51–56）也只有 `view_detail / create / modify / delete / query_data /
>    task_manage`。0.1.5 是**把 `task_manage` 换成了 `execute`、并把 `create` 挪到类型级**
>    （`grants.json` 里 network_builder 对 `knowledge_network` 只剩 `create`），
>    **不是权限被削**。
> 3. **回填的覆盖面已经完整。** 6 个资源项 = 4 个目录（`keep`）+ 2 个知识网络（创建者各已有
>    直接授权）。**没有任何对象的创建者处于「无授权」状态** —— 这包存在的理由
>    （*"for each non-internal Catalog and Knowledge Network **with no direct creator grant**"*）
>    已由历史数据满足。
>
> 补齐 `execute` 等于**凭空授予一个历史上从未存在的权限**，正是脚本那句
> *"blocks the run rather than broadening access"* 要防的。本次部署还有 0 个 `action_type`
> （`01-bkn-data.json` 的 `resources.action_type: 0`），KN 级 `execute` 暂无回退对象，无实际影响。
>
> **证据留档**：`$W/reports/p2-backfill-dryrun.txt`（dry-run 全量输出）。
>
> **什么情况才该真的 apply**：dry-run 报的是 `insert`（创建者**完全没有**直接授权）——
> 那才是这包要补的场景。届时不带 `--confirm-apply` 先跑 dry-run 复核，再按下面执行。

```bash
read -rsp 'MariaDB 口令（用户 openbkn）: ' DB_PW; echo
DB_PW_ENC=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$DB_PW")
export BKN_DSN="mysql://openbkn:${DB_PW_ENC}@10.67.51.9:3306/openbkn"
export SAFE_DSN="mysql://openbkn:${DB_PW_ENC}@10.67.51.9:3306/safe"

docker run --rm --network host \
  -v /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5/network_builder_scope:/nb:ro \
  -e BKN_DSN -e SAFE_DSN \
  bkn-migrate:0.1.5 \
  python3 /nb/backfill_creator_grants.py --mode apply --confirm-apply backfill-creator-grants \
    --bkn-dsn "$BKN_DSN" --safe-dsn "$SAFE_DSN" 2>&1 | tee "$W/reports/p2-backfill-apply.txt" | tail -40
unset DB_PW DB_PW_ENC BKN_DSN SAFE_DSN
```

**预期**：写入 `authorization_grant` 及其对应的 `casbin_rule` 投影，一个事务内完成；每个 `insert`
项写 2 条（`full_business_access`/`community_bundle` + `authorize`/`system_derived`）。

### P2.9 恢复迁移登记的副本数（migrate.py start）

标记写入后，把 P2.5 停掉的五个 Deployment 恢复。**这是 0.1.5 服务第一次带着已迁移的数据 + 已写入的标记运行**，authzgate 从这一步起才会正常放行授权判定。

```bash
read -rsp 'MariaDB 口令: ' DB_PW; echo; export DB_PW
docker run --rm --network host -e DB_PW \
  -v /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5:/work:ro -v "$W":/state \
  -v /root/.kube:/root/.kube:ro -v /usr/local/bin/kubectl:/usr/local/bin/kubectl:ro \
  bkn-migrate:0.1.5 \
  python3 /work/permission_model_transition/migrate.py start \
    --namespace openbkn --state-file /state/workloads.tsv \
    --expected-context kubernetes-admin@hw.local
unset DB_PW
```

**预期**：五个 Deployment 的 READY 回到 `1/1`。**`bkn-safe` 这时才第一次真正起来**——
标记已写入，`Run()` 的 `ensureAuthorizationMigrationReady` 通过（`app.go:212`）。

```bash
kubectl -n openbkn get deploy vega-backend ontology-query agent-operator-integration bkn-backend bkn-safe
kubectl -n openbkn get pod -l app=bkn-safe      # CrashLoopBackOff 应已消失
```

**若 `bkn-safe` 仍是 `CrashLoopBackOff`**：

```bash
kubectl -n openbkn logs deploy/bkn-safe --previous --tail=30
```

- 若仍报 `authorization migration gate: current authorization migration marker required`
  → 标记没写进去，回 P2.7 确认（§6.3）。
- 若报的是别的错 → 贴回来。

> **★ `start` 的超时是每个 Deployment 300s**（`service_control.sh:70`，
> `OPENBKN_MIGRATION_TIMEOUT_SECONDS` 可调）。而且 `START_ORDER` 把
> **`bkn-safe` 排第一个**、并对每个跑 `kubectl rollout status`
> （`service_control.sh:23-29,311-313`）。所以**若 `bkn-safe` 没在 300s 内 Ready，
> `start` 会中止，后面四个保持停止**——但状态文件不会被删（`rm` 在循环之后），
> 修好原因后可以**直接重跑 `migrate.py start`**。
>
> 遇到这种情况先把超时放宽再重跑：
> ```bash
> # 在 docker run 里加 -e OPENBKN_MIGRATION_TIMEOUT_SECONDS=600
> ```
> 另外 `migrate.py start` 成功后会**删掉** `workloads.tsv`，这是正常的
> （`service_control.sh:315`）——别再以为丢了状态。

> **注意顺序**：`start` 必须在 `apply` **之后**。早一步恢复业务，就是让 0.1.5 服务在读一份没迁移完的权限数据。
> 而且 `migrate.py apply` 自己会在写入前**复核那五个 Deployment 仍在停止状态**——
> 提前 `start` 会让 `apply` 直接拒绝执行。
>
> 原 runbook 把「部署」放在迁移之后，正是为了天然满足这一点；现在部署提前了，这条约束改由 `stop`/`start` 这对闸门来保证。

**关于 helm 状态：不需要做任何事。** `bkn-safe` 的 release 本来就一直是 `deployed` ——
你的脚本没有 `--wait`，helm 不等 rollout，所以不会因 CrashLoop 标成 `failed`（2026-10-16 实测）。
CrashLoop 只体现在 Pod 上，标记一写它自愈。**不要为了「刷状态」去重跑部署**（重跑的副作用见 §5.5）。

---

## 5. P3 授权冒烟与开放入口

外部入口仍然封堵，先走集群内验证。

### 5.1 收尾确认（~~入口仍封闭~~ **本次入口是开的**）

> **标题更正（2026-10-16）**：原文假设 P2.2 已封入口。本次没封，所以这一步**不是在封闭状态下做的**。
> 下面的检查项本身与入口开关无关，照跑即可。

```bash
kubectl -n openbkn get pods
helm list -n openbkn
```

**预期**：约 17 个 Pod Running，`core-data-migrator-job-*` 为 Completed，**`bkn-safe` 和 `bkn-backend` 处于 CrashLoopBackOff（预期）**；`helm list` 里 15 个 release 的 CHART 列全部是 `0.1.5`。

### 5.2 授权冒烟（走集群内）

用 `port-forward` 走，**不要**在集群里新起一个 curl Pod——那要额外拉镜像，而节点能不能拉到公共镜像是未知数。

```bash
kubectl -n openbkn port-forward svc/bkn-safe 3000:3000 >/dev/null 2>&1 &
PF=$!
sleep 3
curl -s -o /dev/null -w 'change-password: %{http_code}\n' \
  -X POST http://127.0.0.1:3000/api/safe/v1/auth/change-password \
  -H 'Content-Type: application/json' -d '{}'
curl -s -o /dev/null -w 'capabilities:    %{http_code}\n' \
  http://127.0.0.1:3000/api/safe/v1/capabilities
kill $PF
```

**预期**：`change-password: 400`（缺参数字段）、`capabilities: 401`。**若 change-password 是 404，说明路由或版本不对，不要开入口**——这正是 0.1.4 / 0.1.5 健康检查路由错位那类问题的典型症状。

再用超管登录一次，确认授权链路通：

```bash
openbkn --version      # 升级后 CLI 可以放开了
openbkn auth login     # 需要 CLI 与平台同为 0.1.5
openbkn bkn list       # 应能列出知识网络
```

> **CLI 解禁**：0.1.5 平台配上 0.1.5 CLI，之前那个「健康检查路由错位」的问题没有了。可以撤掉 `ONBOARD_SKIP_OPENBKN_INSTALL=true`（见 `hybrid-deploy.md` §6.2）。但**先别急着跑 `onboard.sh`**——它会做业务初始化，等入口开了、验证完再说。

### 5.3 开放入口

```bash
kubectl apply -f /root/openbkn-entry-tls.yaml
```

**验证**：

```bash
openssl s_client -connect openbkn.changhong.com:443 -servername openbkn.changhong.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates          # 应仍是 GlobalSign 的 *.changhong.com，2026-12-12 到期
for u in http://openbkn.changhong.com/studio https://openbkn.changhong.com/studio \
         http://openbkn.changhong.com/api/safe/v1/capabilities https://openbkn.changhong.com/api/safe/v1/capabilities; do
  printf '%s\t' "$u"; curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' "$u"
done
```

**预期**：证书不是 Fake Certificate；四条路径回到 `308` / `301 → /studio/` / `401` / `401`。

### 5.4 恢复 CronJob

```bash
kubectl -n openbkn patch cronjob bkn-backend-trace-outbox-cleanup    -p '{"spec":{"suspend":false}}'
kubectl -n openbkn patch cronjob ontology-query-trace-outbox-cleanup -p '{"spec":{"suspend":false}}'
kubectl -n openbkn get cronjob     # SUSPEND 应回到 False
```

### 5.5 收尾检查

**① 先看 helm 状态 —— 多半什么都不用做**

```bash
helm list -n openbkn
```

✅ **15 个 release 全部 `deployed`** → **跳到 ②，不要重跑部署。** 你的脚本没有 `--wait`，
helm 不等待 rollout，`bkn-safe` 的 CrashLoop 从来不会把它标成 `failed`（2026-10-16 实测）。

**仅当真出现 `failed` / `pending` 时**，才用下面这条重跑：

```bash
cd /opt/bkn-foundry/deploy
export OPENBKN_SKIP_PLATFORM_BOOTSTRAP=true
export OPENBKN_SKIP_DATA_SERVICES_BUNDLE=true

# ★ 开跑前自检：必须各输出一行。没有就先别跑（见 §6.8）
env | grep OPENBKN_SKIP

bash ./deploy.sh \
    --config=/opt/bkn-foundry/my-config.yaml \
    --force-upgrade \
    openbkn install \
    --version=0.1.5 \
    --version_file=/opt/bkn-foundry/deploy/release-manifests/0.1.5/bkn-foundry.yaml \
    --charts_dir=/opt/bkn-charts \
    --access_address=https://openbkn.changhong.com
```

> ⚠️ **不要写成 `VAR=x \` 续行格式。** 逐行粘贴时续行会失效，两行退化成孤立赋值，
> 脚本看不到这两个变量 → **它会去装 MariaDB/Redis/Kafka/OpenSearch，并且重写
> `my-config.yaml`**。2026-10-16 真实踩过，见 §6.8。

**重跑是安全的**：SQL 幂等，`--force-upgrade` 让所有 release 都重新渲染（`common.sh:993-996`）。
但**它有代价，而这正是「状态正常就别重跑」的理由**：hydra 的 OAuth client 会被
`client-seed-job` 重新登记一遍（`post-install,post-upgrade` hook，先 DELETE 再 POST，
`client-seed-job.yaml`）—— client_id 不变，但**走 SSO 的外部系统需要重新取一次 token**。

**② 收尾判定**：

```bash
cd /opt/bkn-foundry/deploy
bash ./deploy.sh --config=/opt/bkn-foundry/my-config.yaml openbkn status
helm list -n openbkn
kubectl -n openbkn get pods | grep -v Running
```

**全绿判定**：`deploy.sh openbkn status` 无 drift；`helm list` 里 **15 个 release 全部 `deployed`**；
全部 Pod Running 且重启数不再增长；`core-data-migrator-job` 为 Completed；入口证书正确。

### 5.6 浏览器走一遍

工作台 → 登录（`/login` → hydra 回调）→ 改密码页 → 进一个知识网络看**创建者是否还有管理权限**（这是本次回填的直接验证点）。

### 5.7 升级后必做的三件事

**① ingress 路径 diff** —— 0.1.5 可能新增了对外路径，而你的 host 一旦声明，catch-all 就不再兜底这个域名，**漏掉的路径直接 404**（`hybrid-deploy.md` §4.4 维护约束 2）：

```bash
kubectl -n openbkn get ingress -o jsonpath='{range .items[*]}{range .spec.rules[*].http.paths[*]}{.path}{" -> "}{.backend.service.name}{":"}{.backend.service.port.number}{"\n"}{end}{end}' | sort -u > /tmp/live-after.txt
diff /tmp/bkn-paths-live.txt /tmp/live-after.txt        # 左边是升级前基线（P0 存的）
```

只出现在右边的新路径，要补进 `hw-public-openbkn.changhong.com-443` 并同步 `/root/openbkn-entry-tls.yaml`。

> **本次实测（2026-10-16）：diff 是 `21a22,25` —— 纯新增，没有任何业务路径消失**，所以不存在
> 「原本能走、升级后 404」的业务回归；四条功能路径实测 `308 / 301→/studio/ / 401 / 401` 全部命中预期。
>
> 新增的 4 条全是 `/install-status*`（`/install-status`、`.json`、`.pods.json`、`.workloads.json`），
> 它们来自**部署脚本自己**的组件：`deploy/conf/install-status/endpoint.yaml`，由 `status.sh` 创建
> （`install-status` **不在 0.1.5 的 15 个 chart 里**）。它的 Ingress **有意不带 host**，靠 catch-all 兜底。
>
> **★ 这 4 条要补**（2026-10-16 修正 —— 我先前写的是「不要补」，那是判错了）：
>
> `openbkn.sh:1899-1907` 在安装结束时会把 `https://<access_address>/install-status` 作为
> **「Verify your installation」的链接打印给操作者**。而 host 专属 Ingress 一旦声明，
> catch-all 就不再兜底该域名 —— **那个链接在你这里是坏的**。补上：
>
> ```bash
> cat > /tmp/install-status-paths.json <<'JSON'
> [
>   {"op":"add","path":"/spec/rules/0/http/paths/-","value":{"path":"/install-status","pathType":"Exact","backend":{"service":{"name":"install-status","port":{"number":80}}}}},
>   {"op":"add","path":"/spec/rules/0/http/paths/-","value":{"path":"/install-status.json","pathType":"Exact","backend":{"service":{"name":"install-status","port":{"number":80}}}}},
>   {"op":"add","path":"/spec/rules/0/http/paths/-","value":{"path":"/install-status.pods.json","pathType":"Exact","backend":{"service":{"name":"install-status","port":{"number":80}}}}},
>   {"op":"add","path":"/spec/rules/0/http/paths/-","value":{"path":"/install-status.workloads.json","pathType":"Exact","backend":{"service":{"name":"install-status","port":{"number":80}}}}}
> ]
> JSON
>
> kubectl -n openbkn patch ingress hw-public-openbkn.changhong.com-443 \
>   --type=json -p "$(cat /tmp/install-status-paths.json)"
> ```
>
> `pathType: Exact`，与现有 Prefix 路径不冲突。补完**同步进 `/root/openbkn-entry-tls.yaml`**
> （那是这份 Ingress 的声明源），再验证：
>
> ```bash
> curl -s -o /dev/null -w 'install-status: %{http_code}\n' https://openbkn.changhong.com/install-status
> ```
>
> ✅ `200`
>
> ⚠️ **知情后再决定**：`.pods.json` 与 `.workloads.json` 就是 `kubectl get pods -o json` 与
> `kubectl get deploy,sts -o json` 的原样输出（Pod 名、镜像 tag、节点名、Pod IP、就绪状态）。
> 脚本的 ServiceAccount（`endpoint.yaml` 里的 Role）只对 pods/deployments/statefulsets 有只读权，
> **无 secrets、无 helm**，上游注释称其为 "non-sensitive"。
> **但这是要放到对外域名下的东西 —— 先确认这个域名是内网还是公网。**
>
> 另外这层暴露**其实已经存在**：该 Ingress 无 host，所以任何**未被其他 Ingress 声明的域名**下
> 这些端点都可达（命名空间里 13 份 Ingress 都是无 host 的）。那是 matrix 平台侧的另一件事，
> 与本次升级无关，可单独提给维护者。

**② `normal_user` 的补偿（**必做**）** —— 该角色在 **P2.3** 已被 bkn-safe 自动删除
（含 12 个用户绑定 + 7 条能力面策略，机制见 §2.2），**0.1.5 没有任何角色承接这些操作**。

拿 P1.11 的名单 `$W/reports/normal-user-impact.txt` 逐个处理：

```bash
# 先确认确实已经被删干净（三行都应该是 0）
read -rsp 'MariaDB 口令: ' DB_PW; echo; export DB_PW
docker run --rm --network host -e DB_PW bkn-migrate:0.1.5 bash -lc '
export MYSQL_PWD="$DB_PW"
mariadb -h 10.67.51.9 -u openbkn --batch --raw -e "
SELECT (SELECT COUNT(*) FROM safe.roles WHERE id=\"b5f9ac3e-992c-4bbd-8126-95e87e51c46e\") AS role_rows,
       (SELECT COUNT(*) FROM safe.casbin_rule WHERE ptype=\"g\" AND v1=\"b5f9ac3e-992c-4bbd-8126-95e87e51c46e\") AS g_rows,
       (SELECT COUNT(*) FROM safe.casbin_rule WHERE ptype=\"p\" AND v0=\"b5f9ac3e-992c-4bbd-8126-95e87e51c46e\") AS p_rows;"'
unset DB_PW
```

**然后按人补授**。0.1.5 里对应这批能力的资源类型是
`skill` / `mcp` / `tool_box` / `operator`（`view`、`execute`）、`agent`（`use`）、
`small_model` / `large_model`（`display`、`execute`）。

**实测两点（§2.2 已给出预期）**：

| 测什么 | 预期 | 不符怎么办 |
| --- | --- | --- |
| 用受影响账号跑一次**内置**技能 / 工具箱 | ✅ 正常（内置组件有全员公共授权） | ❌ 内置的都不行 → 贴回来，说明公共授权没生效 |
| 用受影响账号访问**别人自建**的技能 | ⚠️ **被拒是预期**（0.1.5 取消了类型级允许） | 若能访问 → 说明公共授权范围比预期宽，记录即可 |
| 该账号访问**自己建的**技能 | ✅ 正常（创建者授权） | ❌ 贴回来 |

**只有当内置资源也不可用时才算真问题**，那时再按资源逐个补授：
安全 → 角色权限，或对具体资源做对象级授权。**补完通知这 12 个人。**

**③ sandbox 的 DNS egress（★ 必做，且有 10 分钟延迟暴露）** —— 0.1.5 的 sandbox chart
新增了一条 egress NetworkPolicy，其 DNS 规则只认 `kube-system/k8s-app=kube-dns`，
而本集群用 **NodeLocal DNSCache**（`169.254.25.10`）→ **新建的 agent 会话解析不了任何域名
→ s3fs 等满 300s 超时 → 约 10 分钟一轮 crashloop**。完整根因、证据链、影响面见 **§7 第 9 条**。

```bash
# 贴一次修复（幂等）
kubectl apply -f /tmp/sandbox-executor-egress-site.yaml

# 验证：新建一个 agent 会话，然后
kubectl -n openbkn get pod -l app=sandbox-executor --no-headers | awk '{print $1, $4, $5}'
#   RESTARTS 应停住（不再每 ~10 分钟 +1）
kubectl -n openbkn logs -l app=sandbox-executor -c executor --tail=20 | grep container_ready
#   应看到 container_ready sent successfully
```

❌ 若 RESTARTS 仍在涨 → 把 `kubectl -n openbkn describe pod <sandbox-executor-pod>` 与
`kubectl -n openbkn get networkpolicy -o yaml` 贴回来。

✅ **本次已通过（2026-10-16）**：除上面的重启计数外，**走控制面新开了一个全新会话
（新 session id）也能正常起来** —— 这才是这一步的验收点。

> **这一条容易漏**：它**不会在升级窗口内报出来** —— 窗口里跑的是升级前建的会话 Pod，
> 那些 Pod 不受新策略影响。**它只在升级后第一次有人新建 agent 会话时才炸**，
> 且周期长、日志只给一句 `Software caused connection abort`，很容易被当成业务侧问题。
> 因此 §5.7③ 不能等到「有人报障」再做。

---

## 6. 失败与回滚

**通用原则**：`migrate.py apply` 任一步失败 → **后续步骤不再运行，业务服务保持停止**。此时**不要手工伪造成功标记，也不要在部分迁移的数据上继续执行**。

> **★ 先记住这条**：**P2.3 一跑，回 0.1.4 就必须恢复数据库。**
> `01-remove-business-domain.sql` 删掉了 `t_knowledge_network.f_business_domain` 和
> `t_operation_audit` 的两列 + 两个索引，而 0.1.4 的 bkn-backend 会显式 SELECT
> `f_business_domain`（`knowledge_network_access.go:160,223,362`）。
> 只把 helm 版本退回去、不恢复库，0.1.4 会直接报 `Unknown column`。
> 这个文件里也**没有** rollback 段（其余几个都有），说明上游不打算让它反向执行。

### 6.1 P2.4 硬闸没过（表没建全）
**业务还没停，这是最便宜的中止点。**
1. **不要往下走。** 入口保持封闭。
2. 按 P2.4 的表定位到是哪一半缺：`safe` 缺 → 查 `bkn-safe` 日志；`openbkn` 缺 → 查 `core-data-migrator-job` 日志与 Job 状态。
3. 修好原因后**重跑 P2.3**（`deploy.sh openbkn install --version=0.1.5` 是幂等的，可以重复执行）。
4. 若 `marker_rows` 不为 0，**立刻停下贴回来**——这说明迁移记账被别的东西写了，属于需要单独判断的状态。

### 6.2 P2.6 / P2.8 硬闸没过（dry-run 或回填 plan 有 block）
数据未被改动。修掉 block 原因（补 `f_creator` / 确认创建者账号存在 / 调 manifest）后重跑。
业务保持停止，入口保持封闭。**此时回 0.1.4 的代价仍然只是「恢复两个库」**（见 6.5）。

### 6.3 P2.7 迁移 apply 失败
1. **保持五个 Deployment 停止，保持入口封闭。**
2. 用 `$W/reports/p2-apply/01-bkn-data.json` 里记录的恢复命令，同时恢复 **BKN 和 Safe** 两份备份。
3. 此时 `openbkn` 库已是「0.1.5 schema + 0.1.4 数据」的混合态，**除非连同 P1.5 的备份一起恢复，否则不能降回 0.1.4**。
4. 判断方向：向前修（重跑 `apply`）还是向后回（走 6.5 的完整恢复）。

### 6.4 部署本身失败（P2.3 中途挂掉）

**先把「预期失败」排除掉**：

> **`bkn-safe` 显示 `failed` + Pod `CrashLoopBackOff` 是预期的**，
> 因为迁移标记还没写（§2.5）。**只要 Job `core-data-migrator-job` 到了 `Completed`、
> 而 `bkn-safe` 的日志停在那句 `authorization migration gate: ...`，就不是故障**——
> 继续走 P2.4，不要在这里回滚。

排除掉之后，先看 `helm list -n openbkn` 判断卡在哪个 release：

- **卡在 `core-data-migrator`**：`openbkn` 库**可能已经**被改了（钩子是 pre-upgrade，SQL 在 Job 里逐条执行）。
  **先查库再决定**：
  ```bash
  read -rsp 'MariaDB 口令: ' DB_PW; echo; export DB_PW
  docker run --rm --network host -e DB_PW bkn-migrate:0.1.5 bash -lc '
  export MYSQL_PWD="$DB_PW"
  mariadb -h 10.67.51.9 -u openbkn --batch --raw -e "
  SELECT COUNT(*) AS kn_has_business_domain FROM information_schema.columns
   WHERE table_schema=\"openbkn\" AND table_name=\"t_knowledge_network\" AND column_name=\"f_business_domain\";
  SELECT COUNT(*) AS audit_has_tenant FROM information_schema.columns
   WHERE table_schema=\"openbkn\" AND table_name=\"t_operation_audit\" AND column_name=\"tenant_id\";"'
  unset DB_PW
  ```
  - 两个都是 `1` → 还没动，**直接走 6.5 恢复 `openbkn` 后回 0.1.4**，或修好原因重跑。
  - 有一个是 `0` → 已经被改，**必须走 6.5**。
- **卡在 `bkn-safe` 之后的 release**：表已建好，数据未迁移。修好原因重跑 `deploy.sh`；若决定放弃，走 6.5。
- **卡在 `bkn-safe` 本身且日志不是 marker 那句**：真故障，贴日志回来。

### 6.5 回到 0.1.4（完整步骤）

```bash
# ① 保持五个 Deployment 停止、入口封闭（若已 start 过，先再 stop 一次）

# ② 恢复两个库（顺序无关，都来自 P1.5，不是 migrate.py 自建的那份）
gunzip -c "$W/backup/openbkn-<时间戳>.sql.gz" | docker run --rm -i --network host -e DB_PW \
  bkn-migrate:0.1.5 sh -c 'export MYSQL_PWD="$DB_PW"; mariadb -h 10.67.51.9 -u openbkn openbkn'
gunzip -c "$W/backup/safe-<时间戳>.sql.gz"    | docker run --rm -i --network host -e DB_PW \
  bkn-migrate:0.1.5 sh -c 'export MYSQL_PWD="$DB_PW"; mariadb -h 10.67.51.9 -u openbkn safe'

# ③ 版本退回 0.1.4
cd /opt/bkn-foundry/deploy
OPENBKN_SKIP_PLATFORM_BOOTSTRAP=true OPENBKN_SKIP_DATA_SERVICES_BUNDLE=true \
  bash ./deploy.sh --config=/opt/bkn-foundry/my-config.yaml --force-upgrade \
    openbkn install --version=0.1.4 \
    --version_file=/opt/bkn-foundry/deploy/release-manifests/0.1.4/bkn-foundry.yaml \
    --charts_dir=/opt/bkn-charts --access_address=https://openbkn.changhong.com

# ④ 恢复副本数、验证旧权限行为，最后才开入口
```

> **`deploy/` 里必须有 0.1.4 的 manifest**。P1.1 已经整份 `tar` 过 `deploy/`，别把那份备份弄丢。
> 0.1.4 的三个 hotfix 镜像只在 GHCR 有，SWR 上没有——若节点上没有缓存，回退这一步会拉不到镜像。**这是回退最可能卡住的地方**，进窗口前确认一下节点上还留着 0.1.4 的镜像。

### 6.6 入口回退
```bash
kubectl apply -f /root/openbkn-entry-tls.yaml                       # 恢复正式入口
# 或恢复封堵前快照
kubectl apply -f "$W/backup/ing-443.yaml"
kubectl apply -f "$W/backup/ing-443-studio.yaml"
```

### 6.8 ★ 误装数据服务（两个 `OPENBKN_SKIP_*` 没生效）

**2026-10-16 真实发生。** 症状：`deploy.sh` 日志里出现

```
[INFO] Ensuring platform data services (MariaDB/Redis/Kafka/OpenSearch)...
[INFO] Installing MariaDB (single-node) via mariadb Helm chart...
[INFO] Installing local-path-provisioner (hostPath local PV)...
[INFO] Wrote config file: /opt/bkn-foundry/my-config.yaml
```

**根因**：`OPENBKN_SKIP_*` 写成了孤立赋值行（`VAR=x` 单独一行）而不是 `export`。
`bash ./deploy.sh` 启动时环境里没有它们，脚本按默认行为去装数据服务。

**这里有两处伤害，必须分别处理：**

#### ① `my-config.yaml` 被整文件重写

`config.sh` 用 `cat > "${out}" <<EOF`（**全量覆盖，不是合并**）。
它只保留少数几个显式读取的字段（`bknSafe.initialPassword`、`image.registry`），
`depServices` 是**重新生成**的——外置 MariaDB/Redis/Kafka/OpenSearch 的配置**会整段丢失**。

**症状**：下一次跑 `deploy.sh` 会在 release 循环之前就中止，报

```
[ERROR] BKN Trace requires depServices.rds.source_type in .../my-config.yaml; set it to internal or external
[ERROR] BKN Trace installation profile is not ready
```

（`openbkn.sh:1500-1506`，位置在 `for release_name in ...` 循环 `:1511` **之前**，
所以这时**一个 release 都没被升级**，集群仍是 0.1.4。）

**恢复**（`$W/backup/my-config.yaml` 是 P1.1 用 `cp -a` 拷的，保留时间戳所以 `ls` 显示旧日期，
内容却是升级前的原件）：

```bash
export W=/var/lib/docker/bkn-upgrade-0.1.5
cp -a /opt/bkn-foundry/my-config.yaml "$W/backup/my-config.yaml.DAMAGED-$(date +%Y%m%d-%H%M%S)"
cp -a "$W/backup/my-config.yaml" /opt/bkn-foundry/my-config.yaml
chmod 600 /opt/bkn-foundry/my-config.yaml
grep -n 'source_type: external' /opt/bkn-foundry/my-config.yaml   # 应看到 rds + redis 两处
```

**有差异就从备份恢复原件再重跑**——不要拿一份丢了 `depServices` 的配置去升级，
那会把外置库的拓扑整个覆盖掉。

#### ② 集群里多出来的对象（可能波及别人）

2026-10-16 实测多出这些，**都是 run #1 建的**（`[WARN] No StorageClass found` 这句证明
在此之前集群里一个 StorageClass 都没有，所以这些全是新增）：

| 对象 | 危害 |
| --- | --- |
| **StorageClass `local-path`，且带 `(default)`** | ⚠️ **最危险**。集群级默认行为改变：其他命名空间里**新建的、未写 `storageClassName` 的 PVC** 以前会 Pending，现在会绑到 hostPath、且 `RECLAIMPOLICY=Delete` |
| `kube-system/local-path-provisioner` + 其 sa/role/rolebinding/cm + clusterrole/clusterrolebinding | 集群级组件，占资源 |
| namespace `resource` + **`1/1 Running` 的 `mariadb-0`** StatefulSet + 2 个 Service + PVC `data-mariadb-0` | helm release 显示 `failed` 但工作负载**是活的**，会一直跑 |
| helm release `mariadb`（`failed`） | 半装状态 |

**★ 关键判断：BKN 根本不需要 StorageClass。** 实测 `openbkn/bkn-safe-postgres-data`
绑定的是**静态 PV** `bkn-safe-postgres-pv`，STORAGECLASS 列为空。所以这套 provisioner
对本平台毫无用处，纯属新增——**可以整体移除，回到误装前的状态**。

**先摘 `default` 标注**（这一步就把最重要的行为恢复了，可以立刻做）：

```bash
kubectl get pvc -A --sort-by=.metadata.creationTimestamp   # 先确认没有新 PVC 依赖它
kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class-
```

**再按顺序清理**（顺序不能颠倒：先删 PVC 让 provisioner 回收 PV，最后才删 provisioner 和 SC）：

```bash
helm uninstall mariadb -n resource
kubectl -n resource delete pvc data-mariadb-0
sleep 5; kubectl get pv | grep -E 'pvc-|local-path'
kubectl -n resource get all,cm,secret,sa,pvc      # 确认只剩这些
kubectl delete ns resource

# 核对对象名和年龄（都应是误装那一刻新建的），再删
kubectl -n kube-system get sa,role,rolebinding,deploy,cm | grep -i local-path
kubectl get clusterrole,clusterrolebinding,sc | grep -i local-path
kubectl -n kube-system delete deploy local-path-provisioner
kubectl -n kube-system delete sa local-path-provisioner-service-account
kubectl -n kube-system delete role local-path-provisioner-role
kubectl -n kube-system delete rolebinding local-path-provisioner-bind
kubectl -n kube-system delete cm local-path-config
kubectl delete clusterrole local-path-provisioner-role
kubectl delete clusterrolebinding local-path-provisioner-bind
kubectl delete sc local-path

kubectl get sc          # 应 "No resources found"
```

#### ③ 一个 `cp -i` 的坑（恢复配置时会踩）

root 的 `cp` 常被 alias 成 `cp -i`。把 `cp` 和后续命令**贴在同一段里**时，
**下一行会被当成 answering 提示符**，于是静默跳过覆盖：

```
cp: overwrite '/opt/bkn-foundry/my-config.yaml'? chmod 600 /opt/bkn-foundry/my-config.yaml
```

**用 `/bin/cp -af` 绕过别名，并用 `cmp` 验证**（不要用 `grep` 判：
redis 那段的键是 `sourceType` 驼峰、rds 是 `source_type` 下划线，两个 pattern 不同）：

```bash
/bin/cp -af "$W/backup/my-config.yaml" /opt/bkn-foundry/my-config.yaml
chmod 600 /opt/bkn-foundry/my-config.yaml
cmp "$W/backup/my-config.yaml" /opt/bkn-foundry/my-config.yaml && echo "✅ 逐字节一致"
```

> **避免方式**：`export` 单独成行 + `env | grep OPENBKN_SKIP` 自检（见 P2.3）。

### 6.9 备份恢复（最后手段）

用 P1.5 的四份 `.sql.gz`。**注意两点**：
1. 恢复 `safe` 库要连同 `authorization_migration_marker` 一起回到迁移前状态，否则下次迁移会被标记挡住。
2. **`openbkn` 库也必须一起回**（6.5 的核心理由）——它被 `01-remove-business-domain.sql` 改过结构。

> **P1.1 的配置备份**：`$W/backup/my-config.yaml`（P1.1 拷贝的原始件）以及
> `$W/backup/bkn-foundry-deploy-*.tar.gz` 里 `deploy/` 整包中的同名文件，
> 都是 §6.8 场景下的恢复来源。确认这两份存在且可比对。

---

## 7. 已知风险与遗留项

1. **K8s v1.23.14 低于平台支持下限 1.24**。整个 0.1.4 部署是渲染成功并跑起来的，但 0.1.5 的 chart 模板若有 API 版本变化，可能在 `helm upgrade` 阶段才暴露。这是本次最大的不确定性。→ 缓解：P1.6 预拉 chart 后可以先 `helm template` 渲染一遍看有没有报错。

2. **回填与权限迁移的先后顺序无权威依据**。两者在仓库里互不引用（各自的 README 也不提对方）。
   本 runbook 定的是 **权限迁移 apply 在前（P2.7）、回填在后（P2.8）**（2026-10-16 定）：
   官方 `permission_model_transition/README.zh.md` 把 `dry-run → stop → apply` 定义为中间不插写入的
   序列，而回填写的是该迁移要 plan 的 `authorization_grant` + `casbin_rule` —— 插在中间会让
   P2.6 批准的那份 dry-run 不再等于 apply 的状态。反过来则两边证据都干净，且迁移面对的正是
   已审过的原始 0.1.4 状态。顺序本身可以自由选，因为两个包为 Catalog 生成的授权是**同一个
   `grant_id`**（`projection_key` 与 `stable_key` 同算法），天然幂等。
   **P2.6 / P2.8 两道硬闸是验证这个选择的关口。**

   > ~~「唯一的硬约束是回填必须在新 bkn-safe 启动前完成」~~ ——
   > **2026-10-16 更正（我先前把这条写成「被证伪」，错了）**：这条约束**不是我的推测，
   > 是包内 README 白纸黑字写的**，`network_builder_scope/README.md` 第 3 行：
   >
   > > Run this package **before** deploying a bkn-safe image whose `network_builder` seed grants
   > > contain only `catalog:* / create` and `knowledge_network:* / create`.
   > > … It must finish successfully before restarting bkn-safe with the narrowed seed grants.
   >
   > 准确的说法是：**本方案有意偏离了这条官方顺序**（部署含 bkn-safe 启动排在回填之前）。
   > 之所以仍然安全，是因为 README 担心的那件事 —— 创建者在收窄后的 seed grants 下失去访问 ——
   > 在 bkn-safe **能服务任何请求之前**就被挡住了：它在迁移标记写入前因 `ErrMigrationMarkerRequired`
   > fail-closed（§2.5 表格第 2、3 条），而标记由 P2.7 写入、P2.9 才 `start`。
   > （原文这里接着写了「入口全程封闭」—— **那也是错的**：P2.2 未执行，入口全程开放，
   > 见 §7 第 3 条。）
   > 真正的硬约束是**回填必须在 `migrate.py start` 之前**，它满足（回填 = P2.8，`start` = P2.9）。
   >
   > **顺带的代价**：正因为顺序反了，回填跑在 rename 之后，撞上了 `f_internal` 那个缺陷
   > （P2.8 的补丁）。
   >
   > ⚠️ **再更正一次（同一轮内第二次，见 issue 草稿 B）**：我先前接着写「按 README 的顺序跑
   > 本可避开」—— **这句也是错的**。README 那个顺序**根本跑不起来**：回填脚本还会查
   > `authorization_grant`，而这张表在 **0.1.4 的库里不存在**（v0.1.4 全仓库 0 命中；
   > 没有任何 SQL 建它；它只由 0.1.5 bkn-safe 启动时的 GORM `AutoMigrate` 创建，
   > `model.go:480` 的 `AllModels()` + `database.go:64`）。**所以从 0.1.4 基线出发，
   > 两种顺序都会失败**，唯一能通的就是「部署后跑 + 打列名补丁」—— 也就是我们实际做的。
   > 这不是本方案的选择，是当时唯一可走的路。

   > **实际结局（2026-10-16 实测）**：回填**止于 dry-run，未 apply**。两个知识网络的创建者被
   > `partial direct creator grant` 拦下，缺的只是 `execute` —— 而该 operation 在 0.1.4 里
   > **从未授予过任何人**（0.1.5 是把 `task_manage` 换成了 `execute`，并把 `create` 挪到类型级）。
   > 补齐它等于凭空授权。两个创建者各自保留 6 条历史直接授权，相对迁移前唯一的变化是
   > `task_manage` 被 0.1.5 主动退役 —— 与迁移其余部分口径一致。详见 P2.8 第三步。

3. **部署先于迁移带来的较长新版本运行窗口**（§2.5 末尾）。从 P2.3 开始到 P2.5 `stop`
   之间约 **1 分钟**（0.2.0 脚本无 `--wait`；v0.1.5 脚本约 15 分钟），另外 4 个服务以 0.1.5
   跑在未迁移数据上。
   **这是本方案唯一新增的实质风险**，进窗口前要认可它。

   > ⚠️ **本次实际暴露（2026-10-16 事后确认，与原文不符）**
   >
   > 原文写的缓解是「入口已封、bkn-safe 完全不接请求、无外部写入」。**第一条不成立**：
   > 操作者当时决定不封入口（P2.2 未执行），`openbkn.changhong.com` 从 **P2.3 到 P2.9 全程可达**。
   > 所以这一段的真实状态是：
   >
   > | 项 | 实际情况 |
   > | --- | --- |
   > | 外部入口 | ❌ **开放**（原计划的 503 封堵从未生效） |
   > | bkn-safe | ✅ 起不来（缺标记，`Run()` 直接退出）→ **授权面完全断开** |
   > | bkn-backend | ✅ 同样 CrashLoop（§5.1）→ 主 API 不通 |
   > | 另外 4 个服务 | ⚠️ 以 0.1.5 跑在未迁移数据上，**且入口可达** |
   >
   > **净效果**：外部流量确实能打到集群，但打到的是**主 API 已垮、只剩 4 个下游服务**的平台 ——
   > 而其中 3 个（vega / ontology-query / agent-operator-integration）要通过 bkn-backend 才有人用。
   > **这属于「侥幸收敛」而不是「设计安全」**：它是 bkn-safe 起不来这个副作用顺带挡住的，
   > 不是 P2.2 挡住的。计划里承诺的缓解措施**一条都没执行**。
   >
   > **未观测到的部分（不要当成没事）**：没有证据表明窗口内有真实用户请求打进来，
   > 也**没有证据表明没有** —— 入口全程开放、无访问日志核对。如果之后发现这段时间有异常数据
   > 或异常审计记录，回来看这一条。
   >
   > **P2.2 因此的定位**：它在文档里仍标着「必须显式做这一步」，但**本次未执行且未出事**。
   > 保留它作为推荐做法，但**不要把「入口已封」当作已发生的既成事实**引用。

   > ~~**同一现象的第二个后果**：`bkn-safe` 的 helm release 在 P2.3 里会显示 `failed`
   > （Pod CrashLoop 到 P2.7 写入标记为止），**但要在 P5.5 用重跑刷回 `deployed`**~~
   >
   > **这条在 2026-10-16 被实测证伪**（我先前写错了）：你的脚本没有 `--wait`，helm 不等 rollout，
   > 所以 `bkn-safe` 的 CrashLoop 从来不会把它标成 `failed` —— `helm list` 里 15 个 release
   > **全部是 `deployed`**。CrashLoop 只体现在 Pod 上，P2.7 写完标记就自愈。
   > **P3.5 没有「刷状态」这件事要做**，重跑反而会带来 `client-seed-job` 重登记 OAuth client 的副作用。

4. **`deploy.sh` 与 manifest 不是同一 tag 的产物**。服务器上的检出是 `VERSION=0.2.0` 时期（晚于 v0.1.5），跑 0.1.5 的锁文件。上游的规范是「脚本、VERSION、锁文件、chart 同源」，你们这套从一开始就是混的（0.2.0 检出 + 0.1.4 锁文件）。选择沿用现成脚本是因为它在你们集群上验证过、且比 v0.1.5 更新（`openbkn.sh` 在 v0.1.5→HEAD 之间改了很多升级处理逻辑）。若坚持同源，替代方案是用 `openbkn-deploy@v0.1.5` 作为部署根——那是更大的变更。

   > **相关的新情况（2026-10-12）**：上游已把 `deploy/` 从 bkn-foundry 仓库**整体移出**（`c3ea77407`，302 文件 / 53286 行），官方安装文档改指 `openbkn-ai/openbkn-deploy`。
   >
   > **好消息**：服务器上 `/opt/bkn-foundry` **不是 git 检出**——P0 的 `ls -la` 显示它含 `.github` 和 `.gitignore` 但**没有 `.git`**，是一次**发布包解压**（这也解释了为什么机器上根本没装 git）。所以**不存在「误 `git pull` 导致 `deploy/` 被删」的风险**。
   >
   > **但仍建议**：P1.1 之外再单独 `tar` 一份 `/opt/bkn-foundry/deploy` 到备份区。理由不是 git，而是——**这个包是 0.2.0 时期的快照，而 0.2.0 之后再没有新的整包发布**（`deploy/` 已迁走）。一旦这份 `deploy/` 有任何损坏，你**没有可重新下载的同形态整包**了，只能改从 `openbkn-deploy` 取，那是不同形态的交付物。
   >
   > 长期方案是迁到 `openbkn-deploy` 作为部署根，但那属于本次升级之后的独立工作，本次不动。

5. **`normal_user` 删除是破坏性行为变更，且由 bkn-safe 自己执行**（§2.2）。
   实测：**12 个用户绑定 + 7 条策略**（全库仅 14 个用户），在 **P2.3** 就被删掉，
   **早于 `migrate.py apply` 的备份**——唯一的恢复手段是 P1.5 的备份。
   0.1.5 的 5 个角色**没有一个**承接 `skill`/`mcp`/`tool_box`/`operator` 的
   `view`/`execute`、`agent` 的 `use`、模型的 `display`/`execute`；改由**对象级 + 公共授权**
   （`PublicAccessorID` 全零 UUID）承接。

   **影响评估（实测后）**：那 12 人**全部**另有 `network_builder`、`account_type` 全为
   `other`（本地人类账号）。内置组件由 `CreateIntCompPolicyForAllUsers` 自动获得全员
   `public_access`+`execute`（`policy.go:26-40`，触发条件 `IsInternal`），所以
   **不是"12 个人被锁在门外"**。真实变化是**用户之间不再默认互相可见可执行对方自建的能力**。

   **确认方式（P5.7②）**：用受影响账号跑一次内置技能（应正常）、访问一次别人自建的技能
   （**被拒是预期**）。**进窗口前不需要做任何授权调整。**

   > 这条是本 runbook 在 2026-10-16 之前**低估**的一项：原文写「迁移脚本不处理它」，
   > 事实是 bkn-safe 会**主动删除**（`app.go:104-111` → `seed.go:305-330`），
   > 而且删除**早于迁移读 `casbin_rule`**，导致这 7 条策略**不可能被迁移分类保留**。
   > 这是「部署先于迁移」结构性带来的，无法规避。

6. **客户端接口破坏性变更**（`find_skills` / `search_tools` / PTC / 语义检索）。有外部调用方的话，升级前先通知。

7. **`bkn_trace` 库本次不动**。官方的 trace 迁移（0.2.0 才需要）不在本次范围。

8. **证书 2026-12-12 到期**。与本次升级无关，但顺带记着：轮换时要同步 `openbkn` 命名空间的那份副本。

9. **★ 0.1.5 给 sandbox 新增的 NetworkPolicy 会让「新建的 agent 会话」失去 DNS，进而挂不上 S3 工作区**
   （2026-10-16 实测发现并定位，**本站已修复并验证闭环，上游未修**）。**任何「跑 NodeLocal DNSCache
   + CNI 真的执行 NetworkPolicy」的集群都会中招** —— 这不是本方案的配置问题，是 chart 缺陷，
   已按 §5.7③ 记录并单独上报。

   **症状**：`sandbox-executor` 容器起来后卡住，约 **10 分钟**一轮 crashloop，日志尾部是

   ```
   mkdir: cannot create directory '...': Software caused connection abort
   ```

   **根因（已逐条实测确认）**：0.1.5 的 sandbox chart 新增了一条 egress NetworkPolicy
   （`infra/sandbox/deploy/helm/sandbox/templates/networkpolicy.yaml` → `…-executor-egress`），
   它的 DNS 规则是：

   ```yaml
   - to: [{namespaceSelector: {kubernetes.io/metadata.name: kube-system},
           podSelector: {k8s-app: kube-dns}}]
     ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
   ```

   —— 只允许发给 **`kube-system` 里 `k8s-app=kube-dns` 的 Pod（CoreDNS 的 ClusterIP 形态）**。
   而你们的集群装了 **NodeLocal DNSCache**，每个 Pod 的 `/etc/resolv.conf` 是
   `nameserver 169.254.25.10`（链路本地地址），**不属于 `kube-system` 命名空间、也不是 Pod**，
   于是被这条策略挡在外面。

   证据链（2026-10-16，`openbkn` 命名空间内）：

   | 观测 | 结果 |
   | --- | --- |
   | `cat /etc/resolv.conf` | `nameserver 169.254.25.10` |
   | 连控制面 `10.233.0.223:8000`（**策略里显式允许**） | **OPEN** —— 证明 egress 本身通，只有 DNS 被挡 |
   | 连 `169.254.25.10:53` | **TimeoutError** |
   | `getent hosts <任何名字>` | 永久挂起 |

   **为什么表现为 10 分钟一轮**：`sandbox-executor` 用 **s3fs** 挂 workspace。DNS 挂起后 s3fs
   走到自己默认的 `connect_timeout=300s`，超时后报 `ECONNABORTED`，进程 exit 1。
   300s 超时 × 重试 ≈ 10 分钟 —— 这个周期是 s3fs 的，不是 K8s 的，所以 `kubectl describe`
   里看不到任何 probe 失败或 OOM，只有 exit code 1。

   **同一策略对 BYOK 外置 MinIO 也有第二个缺口（逻辑推定，非实测）**：策略里 `minio.enabled`
   为真时才放通 **MinIO Pod**；你们是 `minio.enabled=false` + 外置 `10.67.51.9:9000`。
   而 `policyTypes: [Egress]` + 非空 egress 列表 = **未匹配即拒绝**，`10.67.51.9` 既不是
   `kube-system`、也不是 MinIO Pod、也不在 `publicHttps` 那条里（那条的 `except` 明确列了
   `10.0.0.0/8`）。所以即便 DNS 修好，**S3 端点本身也仍然不可达**。修复清单里必须一起带上它。

   **修复方式**：另加一条策略，靠 NetworkPolicy 的**加法语义**（多条策略选中同一 Pod 时，
   任一条允许即允许）补洞。把 `<SITE>` 换成站点值后 apply：

   ```bash
   cat > /tmp/sandbox-executor-egress-site.yaml <<'YAML'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: sandbox-executor-egress-site      # 名字刻意不同：不归任何 helm release 管
     namespace: openbkn
   spec:
     podSelector:
       matchLabels:
         app: sandbox-executor
         managed_by: sandbox-control-plane
         sandbox-type: execution
     policyTypes: [Egress]
     egress:
       # ① NodeLocal DNSCache 的链路本地地址
       - to: [{ipBlock: {cidr: 169.254.25.10/32}}]
         ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
       # ② 外置 MinIO 的真实端点
       - to: [{ipBlock: {cidr: 10.67.51.9/32}}]
         ports: [{protocol: TCP, port: 9000}]
       # ③ 同一个 MinIO 的 Service ClusterIP（不同 CNI 在 egress 上判定 DNAT 前/后地址，
       #    两条都留以覆盖两种行为；留着无害）
       - to: [{ipBlock: {cidr: 10.233.49.14/32}}]
         ports: [{protocol: TCP, port: 9000}]
   YAML

   kubectl apply -f /tmp/sandbox-executor-egress-site.yaml
   ```

   > `169.254.25.10` 是 NodeLocal DNSCache 的**固定**链路本地地址（不是每个集群随机）；
   > `10.67.51.9:9000` / `10.233.49.14:9000` 是你们这台的值。
   > 若集群换了 NodeLocal 地址或 MinIO 端点，这三条的 CIDR 要跟着改 ——
   > **这份文件不属于任何 helm release，chart 升级不会覆盖它，但也因此不会自动跟着变。**

   **验证**（放进 §5.7③）：

   ```bash
   P=$(kubectl -n openbkn get pod -l app=sandbox-executor,managed_by=sandbox-control-plane -o name | head -1)
   kubectl -n openbkn exec "$P" -c executor -- getent hosts hw-minio-api.openbkn.svc.cluster.local   # 要出 IP
   kubectl -n openbkn get pod -l app=sandbox-executor --no-headers | awk '{print $1, $4, $5}'      # RESTARTS 应停住
   ```

   **怎么判定「停住了」——单看 `RESTARTS` 数值不够**。它可能是修复前留下的计数，
   必须同时看**当前容器已经连续存活多久**。崩溃周期是 ~10.5 分钟，所以判据是
   「当前容器连续存活 > 15 分钟且计数没涨」：

   ```bash
   kubectl -n openbkn get pod <sandbox-executor-pod> \
     -o custom-columns='RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.containerStatuses[0].state.running.startedAt,LASTCRASH:.status.containerStatuses[0].lastState.terminated.finishedAt'
   ```

   `STARTED` 是**当前容器**的启动时间，不含上一次崩溃前的历史，直接就是「这一轮跑了多久」。
   `LASTCRASH` 为 `<none>` 表示这个容器**一次都没崩过**（崩溃过就会有值），是最强的单项证据。

   ✅ **本集群已完全闭环（2026-10-16 实测）**：`RESTARTS 0` / `LASTCRASH <none>` /
   连续存活 **17.8 分钟**（跨过 1.7 个崩溃周期）。修复前该 Pod 是 **21 分钟 2 次重启**。
   修复时的即时验证是 `dns= 10.233.36.76`、`minio=OPEN`，日志重新出现
   `container_ready sent successfully`。

   ✅ **最终验收也已通过**：**走控制面新开了一个全新会话（新 session id），跑通。**
   这是本条的真正验收点 —— 即「升级后第一个新人建会话」那个场景（见下）。
   至此本条可以当作**已修复且已验证**，不再是未决项。

   **影响面（写清楚，避免误判）**：只影响**升级后新建**的 agent 会话 Pod；升级前已在跑的
   会话 Pod 有旧的（空的）策略选择结果，会一直正常到你重建它为止。**所以这个问题不会在升级
   窗口内暴露，而是在升级后第一次有人新建会话时才暴露** —— 这就是它必须放进 §5.7 原因。

   **上限与替代方案**：另加策略是「就地可用」的做法。**若你们的 `my-config.yaml` / 部署脚本
   能把值透传到 sandbox chart**，更干净的是走 chart 自带的
   `networkPolicy.additionalEgress`（模板里有 `{{- with }}` + `toYaml` 块，原样渲染）——
   **但这条透传链路我没有验证过，作为待评估项记着，不要当作已确认。**

   > 上报用的 issue 草稿见 `help/zh/manual/bkn-0.1.5-upstream-issues.md`（草稿，未提交上游）。

---

## 附：本次用到的权威依据

> ⚠️ **`deploy/` 已于 2026-10-12 从 bkn-foundry 仓库移出**（upstream commit `c3ea77407` `chore(deploy): remove in-repo deployment assets (#2117)`，302 文件 / 53286 行删除）。官方安装文档现在写的是「安装通过 **openbkn-deploy** 仓库或其发布包中的 `deploy.sh` 完成」。
>
> 所以下表里所有 `deploy/...` 的路径**在当前工作区已不存在**。查阅方式二选一：
> - 本仓库的历史版本：`git show v0.1.4:deploy/scripts/lib/common.sh`（tag 里的树仍然完整）
> - 现役部署源：`github.com/openbkn-ai/openbkn-deploy`
>
> 这反过来印证了 P1.2 的做法：**0.1.5 的交付渠道本来就是 openbkn-deploy**，锁文件不在 bkn-foundry 里不是遗漏，是设计如此。

| 内容 | 位置 |
| --- | --- |
| 权限模型迁移官方流程 | `deploy/scripts/upgrades/0.1.5/permission_model_transition/README.zh.md` |
| 创建者授权回填 | `deploy/scripts/upgrades/0.1.5/network_builder_scope/README.md` |
| 0.1.5 锁文件（15 个 chart） | `openbkn-ai/openbkn-deploy@v0.1.5` → `release-manifests/0.1.5/openbkn.yaml` |
| 0.1.5 release notes | `github.com/openbkn-ai/bkn-foundry/releases/tag/v0.1.5` |
| 锁文件解析逻辑 | `deploy/scripts/lib/common.sh:773`（文件名）、`:589-609`（product/version 校验） |
| 升级入口 | `deploy/scripts/services/openbkn.sh:202-225`、`:1686`（不传版本会取最新 manifest） |
| 两个数据库的分工 | `bkn-safe/charts/bkn-safe/templates/deps.yaml`、`bkn-safe/charts/hydra/values.yaml:31-33` |
| 角色差异 | `bkn-safe/server/internal/seed/data/roles.json`（v0.1.4 vs v0.1.5） |
| 种子授权收窄 | `bkn-safe/server/internal/seed/data/grants.json`（v0.1.5: catalog/knowledge_network 只剩 `create`） |
| 拓扑与既有坑 | `help/zh/manual/hybrid-deploy.md` |

**§2.5 顺序修正的证据来源**（2026-10-16 补）：

| 结论 | 依据 |
| --- | --- |
| dry-run 也要求 0.1.5 schema | `deploy/scripts/upgrades/0.1.5/permission_model_transition/bkn_data.py:2252`（plan 先于 mode 分支）、`:2261`、`:911`、`:778-795`、`:913-923` |
| `safe` 侧表由 bkn-safe 启动时建 | `bkn-safe/server/internal/database/database.go:65`、`bkn-safe/server/internal/model/model.go:474-482` |
| `openbkn` 侧表由 pre-stage migrator hook 建 | `data-migrator/helm/core-data-migrator/templates/job.yaml`（`helm.sh/hook: pre-install,pre-upgrade`）、`data-migrator/helm/core-data-migrator/values.yaml`、`data-migrator/config.monorepo.yaml`（`services: bkn-backend`）、`migrations/bkn-backend/mariadb/0.1.5/{03,04,05}-*.sql`、`deploy/scripts/services/openbkn.sh:262-274` |
| release 顺序 = 锁文件 YAML 顺序 | `deploy/scripts/lib/common.sh:2021-2034`（`_manifest_list_release_names` 按行序 awk），`openbkn.sh:1511-1517`（照序安装）；锁文件里 `core-data-migrator` 排第一 |
| 不会误判为全新安装 | `bkn-safe/server/internal/authzgate/gate.go:50-54`（唯一信号是 `casbin_rule` 不存在）、`:87-89`、`bkn-safe/server/app/app.go:69-72,97-100` |
| **bkn-safe 在写标记前起不来**（CrashLoop） | `bkn-safe/server/app/app.go:207-214`（`Run()` 里 `ensureAuthorizationMigrationReady` 失败即返回）、`:236-241`、`gate.go:56-60`；标记表**不在** `AllModels()`（`model.go:474-482`），只由 `gate.go:254` 或 authz-migrate 创建 |
| 单个 release 失败不中断部署 | `deploy/scripts/services/openbkn.sh:1511-1519`（循环不检查返回码）、`:648-653`（返回 1） |
| 重跑不会被跳过 | `deploy/scripts/lib/common.sh:987-996`（`FORCE_UPGRADE=true` 永不跳过） |
| 部署不可逆 | `migrations/bkn-backend/mariadb/0.1.5/01-remove-business-domain.sql`（DROP COLUMN，无 rollback 段）vs `adp/bkn/bkn-backend/server/drivenadapters/knowledge_network/knowledge_network_access.go:160,223,362`（v0.1.4 显式引用） |
| `normal_user` 由 bkn-safe 自动删除 | `bkn-safe/server/app/app.go:104-111`（Boot 里无条件调用）、`bkn-safe/server/internal/seed/seed.go:78`（角色 ID）、`:302-330`（删除实现）、`bkn-safe/server/internal/authz/authz.go:743-753`（`RemoveRoleCompletely` 删 g+p） |
| 该角色能力面内容 | `bkn-safe/server/internal/seed/data/grants.json` v0.1.4 vs v0.1.5 逐条对比（v0.1.5 无 `normal_user` 行，且 5 个角色均不含 `execute`/`use`/`display` 于 skill/mcp/tool_box/operator/agent/模型） |
| migrator 拿到外置库的方式 | `deploy/scripts/services/openbkn.sh:1137,1194`（`-f "${CONFIG_YAML_PATH}"` 传给每个 release）、`deploy/scripts/lib/common.sh:1140-1146`（`is_rds_internal`） |

---

*编制于 2026-10-12 · 基于 P0 只读勘察（master1，17:22 CST）· 未执行任何写操作*
*2026-10-16 修正窗口顺序（部署提前至迁移之前），基于 master1 表清单实测 + v0.1.5 源码复核*
