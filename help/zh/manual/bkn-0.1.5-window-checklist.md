# BKN Foundry 0.1.4 → 0.1.5 维护窗口执行清单

> **配套文档**：`bkn-0.1.4-to-0.1.5-upgrade.md`（本文只给窗口内动作与判定，细节和依据都在那边）
> **编制**：2026-10-16 · 基于 master1 实测 + v0.1.5 源码复核
> **预计时长**：2–4 小时（其中 P2.3 里 `bkn-safe` 白等 600s 是硬性的）
>
> **编号对照**：本文的 `P3.1`~`P3.7` 就是 runbook 的 `§5.1`~`§5.7`；回滚对应 runbook `§6`。

---

## 0. 进窗口前

```bash
export W=/var/lib/docker/bkn-upgrade-0.1.5     # 每开新终端都要重设
cd "$W"
```

| 前置项 | 状态 |
| --- | --- |
| P1.1 工作区 + `deploy/` 整包备份 | ☐ |
| P1.2 0.1.5 锁文件 | ☐ |
| P1.3 迁移容器五项自检全绿 | ☐ |
| P1.4 勘察（`no_creator=0`、无迁移标记） | ☐ |
| P1.5 四库备份（退出码 0） | ☐ |
| P1.6 十五个 chart | ☐ |
| P1.7 `authz-migration.json` | ☐ |
| P1.10 基线复核（含 `depServices.rds`、镜像逐节点） | ☐ |
| P1.11 `normal_user` 名单（12 人，无需提前调整） | ☐ |

> ⛔ **全程绝对不能跑 `deploy.sh k8s reset`** —— 集群上还有你其他业务。

---

## 1. 窗口固定顺序

```
P2.1 挂 CronJob ─ P2.2 封入口 ─ P2.3 部署 0.1.5 ─ P2.4 ★验表
  ─ P2.5 停业务 ─ P2.6 ★dry-run ─ P2.7 ★apply ─ P2.8 回填 ─ P2.9 start
  ─ P3.1 冒烟 ─ P3.3 开入口 ─ P3.5 收尾
```

**三个 ★ 硬闸（P2.4 / P2.6 / P2.7）不通过就不往下走。任何失败按 runbook §6 处置。**

---

## P2.1 挂起 CronJob ☐

```bash
kubectl -n openbkn get cronjob
kubectl -n openbkn patch cronjob bkn-backend-trace-outbox-cleanup    -p '{"spec":{"suspend":true}}'
kubectl -n openbkn patch cronjob ontology-query-trace-outbox-cleanup -p '{"spec":{"suspend":true}}'
kubectl -n openbkn get cronjob     # SUSPEND 应为 True
```

✅ 两个 `SUSPEND=True`

---

## P2.2 封住对外入口 ☐ **【本次未执行 —— 见 runbook §7 第 3 条】**

> **⚠️ 2026-10-16 事后确认：这一步实际没做**，入口全程开放（P2.3→P2.9 都可达）。
> 没观测到问题，但那是 bkn-safe 起不来顺带挡住的，**不是这一步挡住的**。
> 下面保留为推荐做法。

```bash
kubectl -n openbkn get ingress hw-public-openbkn.changhong.com-443        -o yaml > "$W/backup/ing-443.yaml"
kubectl -n openbkn get ingress hw-public-openbkn.changhong.com-443-studio -o yaml > "$W/backup/ing-443-studio.yaml"

BLOCK='[{"op":"replace","path":"/spec/rules/0/http/paths","value":[{"path":"/","pathType":"Prefix","backend":{"service":{"name":"bkn-maintenance-block","port":{"number":1}}}}]}]'
kubectl -n openbkn patch ingress hw-public-openbkn.changhong.com-443        --type=json -p "$BLOCK"
kubectl -n openbkn patch ingress hw-public-openbkn.changhong.com-443-studio --type=json -p "$BLOCK"

curl -sk -o /dev/null -w 'studio:%{http_code}\n' https://openbkn.changhong.com/studio
curl -sk -o /dev/null -w 'api:%{http_code}\n'    https://openbkn.changhong.com/api/safe/v1/capabilities
```

✅ 两条都是 **503**　❌ 出现 200/301/302/401 = **没封住，停下**

> ⚠️ 不要删这两份 Ingress（会回落到平台 11 份无 host 的 catch-all，等于没封）
> ⚠️ 不要动 `nginx-hw-public` 控制器（matrix 平台的 DaemonSet，全集群公共入口）

---

## P2.3 部署 0.1.5 ☐

> **★ 跑下去就回不了头**：pre-stage migrator 会 `DROP COLUMN f_business_domain`，
> 而 0.1.4 的 bkn-backend 显式 SELECT 它 → 回 0.1.4 必须连 `openbkn` 库一起恢复。
> 确认 P1.5 四份备份可用后再按回车。

```bash
cd /opt/bkn-foundry/deploy

OPENBKN_SKIP_PLATFORM_BOOTSTRAP=true \
OPENBKN_SKIP_DATA_SERVICES_BUNDLE=true \
  bash ./deploy.sh \
    --config=/opt/bkn-foundry/my-config.yaml \
    --force-upgrade \
    openbkn install \
    --version=0.1.5 \
    --version_file=/opt/bkn-foundry/deploy/release-manifests/0.1.5/bkn-foundry.yaml \
    --charts_dir=/opt/bkn-charts \
    --access_address=https://openbkn.changhong.com
```

**观测点（按顺序）**：
1. `core-data-migrator` → Job `Completed`（建 `openbkn` 侧三张表）
2. `bkn-safe` → **`✗ Failed to install bkn-safe`，等约 600s** ← **预期，别修**
3. 其余 13 个 release 正常

> **期望看到的警告**：`⚠️ WARNING: EXTERNAL DATABASE - MANUAL SQL INITIALIZATION REQUIRED`
> —— **正常**。0.1.5 锁文件声明了 `stage: pre` 的 data-migrator，建表由 chart hook 负责。

```bash
kubectl -n openbkn get pods
helm list -n openbkn
```

| 现象 | 判定 |
| --- | --- |
| `bkn-safe` Pod `CrashLoopBackOff` | ✅ **预期**（helm 状态仍是 `deployed` —— 你的脚本没有 `--wait`，见 runbook §2.2） |
| 日志有 `authorization migration gate: current authorization migration marker required` | ✅ **预期**（fail-closed） |
| `core-data-migrator-job-*` 到 `Completed` | ✅ 必须 |
| 除 `bkn-safe` 外还有 release `failed` | ❌ 停下，贴日志 |
| `bkn-safe` 日志停在更早的错 | ❌ 停下，贴日志 |

❌ 不要手工补 SQL、不要改标记、不要手工把 release 标成 deployed。

---

## P2.4 ★ 硬闸：确认新表已就位 ☐

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

✅ **11 行全 `✅`，且 marker 显示「尚不存在」**　❌ 任何 `❌` → 停下（runbook **§6.1**：P2.4 硬闸没过）

> `safe` 缺 → 查 `kubectl -n openbkn logs deploy/bkn-safe --previous`
> `openbkn` 缺 → 查 `kubectl -n openbkn get jobs` / `logs job/core-data-migrator-job`

---

## P2.5 停业务 ☐

```bash
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

kubectl -n openbkn get deploy vega-backend ontology-query agent-operator-integration bkn-backend bkn-safe
```

✅ 五个 READY 都是 `0/0`，`$W/workloads.tsv` 已生成

> 这一步之后，「新版本跑在旧数据上」的暴露窗口结束。

---

## P2.6 ★ 硬闸：权限迁移 dry-run ☐

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

**审核四份报告（贴回来一起看）**：

> `summary.json` 只有 `completed`，**没有** `anomalies` 字段 —— 别拿它当结论。
> `03` 的 anomaly 在 dry-run 下**不会**让命令失败（`main.go` 直接 `return report, nil`），必须人读。

1. `01-bkn-data.json`：`skipped_skill_grants` 为 `0`；`archived_tombstones` 为空
2. `02-vega-data.json`：`failure_summary` 为 `{}`；创建者权限包数与 P1.4 的非内置目录数吻合
3. `03-authorization.json`：**`core.anomalies` 为空**、`ee_table_state=absent`、`ee.summary.rows=0`

✅ 四份都无 block / 无 anomaly　❌ 报 `schema is unavailable` → **退回 P2.4**，不要绕过

---

## P2.7 ★ 硬闸：权限模型迁移（写标记）☐

> **本步在 P2.8 回填之前**：官方 README 把 `dry-run → stop → apply` 定义为中间不插写入的序列，
> 而回填写的是本迁移要 plan 的 `authorization_grant` + `casbin_rule`。插在中间会让 P2.6 批准的
> dry-run 不再等于 apply 的状态。

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

✅ `apply` 先复核五个 Deployment 仍在停止；BKN 步骤先建并校验备份；三步依次通过；最后写入带校验和的标记
❌ 任一步失败 → 后续不再运行、业务保持停止 → **按回滚速查处理，不要硬上**

> ⚠️ `--report-dir /reports/p2-apply` 必须是**空目录**。重跑前先
> `mv "$W/reports/p2-apply" "$W/reports/p2-apply.failed-$(date +%Y%m%d-%H%M%S)"`

**验证标记**：

```bash
read -rsp 'MariaDB 口令: ' DB_PW; echo; export DB_PW
docker run --rm --network host -e DB_PW bkn-migrate:0.1.5 bash -lc \
  'export MYSQL_PWD="$DB_PW"; mariadb -h 10.67.51.9 -u openbkn --batch --raw \
   -e "SELECT version, ee_table_state, core_policy_count, core_grant_count, checksum, applied_at FROM safe.authorization_migration_marker;"'
unset DB_PW
```

✅ 一行，`checksum` 非空

---

## P2.8 网络构建者范围回填 ☐

> **★ 必须先打一行补丁**：`backfill_creator_grants.py:128` 读的 `t_catalog.f_internal`
> 已被 P2.3 的 vega 迁移 `RENAME COLUMN f_internal TO f_builtin` 改掉（上游 `#1656` 漏改了这个包）。
> 不打补丁直接跑会 `Unknown column 'f_internal' in 'field list'`。**纯改名，语义一致。**
>
> **别想着「按包内 README 的顺序先跑」绕开** —— 那条路也不通：脚本还会查
> `authorization_grant`，而这张表在 0.1.4 的库里**不存在**（只由 0.1.5 bkn-safe 启动时的
> GORM `AutoMigrate` 创建）。**两种顺序都失败，只有「部署后 + 本补丁」能通。**

**打补丁**：

```bash
cd /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5/network_builder_scope
/bin/cp -a backfill_creator_grants.py backfill_creator_grants.py.orig
sed -i 's/f_internal FROM t_catalog/f_builtin FROM t_catalog/' backfill_creator_grants.py
diff backfill_creator_grants.py.orig backfill_creator_grants.py
```

✅ diff 只应有一处 `128c128` `f_internal` → `f_builtin`

**先 dry-run**：

```bash
read -rsp 'MariaDB 口令（用户 openbkn）: ' DB_PW; echo

DB_PW_ENC=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$DB_PW")
export BKN_DSN="mysql://openbkn:${DB_PW_ENC}@10.67.51.9:3306/openbkn"
export SAFE_DSN="mysql://openbkn:${DB_PW_ENC}@10.67.51.9:3306/safe"

docker run --rm --network host \
  -v /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5/network_builder_scope:/nb:ro \
  -v "$W/reports":/reports -e BKN_DSN -e SAFE_DSN \
  bkn-migrate:0.1.5 \
  python3 /nb/backfill_creator_grants.py --mode dry-run \
    --bkn-dsn "$BKN_DSN" --safe-dsn "$SAFE_DSN" 2>&1 | tee "$W/reports/p2-backfill-dryrun.txt" | tail -40
unset DB_PW DB_PW_ENC BKN_DSN SAFE_DSN
```

✅ `summary` = `{"block": 2, "keep": 2, "skip": 2}`
（2 个内置 Catalog `skip`；2 个非内置已被 P2.7 建过同样授权 → `keep`；
2 个知识网络 → `block`，**只缺 `execute`**）

> **本次到此为止，不执行 apply**（2026-10-16 决策）
>
> - 缺的只有 `execute`，而它在 0.1.4 里**从未授予过任何人**（连 `network_builder` 角色都没有，
>   它当时是 `view_detail/create/modify/delete/query_data/task_manage`）。0.1.5 是把
>   `task_manage` 换成 `execute`、把 `create` 挪到类型级 —— **模型变了，不是权限被削**。
> - 两个创建者各保留 6 条历史直接授权。回填要覆盖的「创建者**无**直接授权」场景**一个都不存在**。
> - 补 `execute` = 凭空授权，正是脚本那句 `blocks rather than broadening access` 要防的。
> - 当前部署 0 个 `action_type`，KN 级 `execute` 暂无回退对象，无实际影响。
>
> 证据：`$W/reports/p2-backfill-dryrun.txt`

> ⚠️ DSN 必须带 `mysql://` 前缀，且口令要 URL 编码（脚本用 `urlparse` 解析）

**只有 dry-run 报 `insert`（创建者完全没有直接授权）时才执行下面这段**：

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

✅ 一个事务内写入 `authorization_grant` + `casbin_rule` 投影；每个 `insert` 项 2 条
（`full_business_access`/`community_bundle` + `authorize`/`system_derived`）

---

## P2.9 恢复业务（`migrate.py start`）☐

> **必须在 apply 之后**，早一步就是让 0.1.5 服务读没迁移完的权限数据。

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

kubectl -n openbkn get deploy vega-backend ontology-query agent-operator-integration bkn-backend bkn-safe
kubectl -n openbkn get pod -l app=bkn-safe
```

✅ 五个 READY 回到 `1/1`，**`bkn-safe` 的 `CrashLoopBackOff` 消失**（标记已写入，`Run()` 通过）
❌ 仍 CrashLoop → 查日志（仍是 `marker required` → 回 P2.7；别的错 → 贴回来）

> `start` 每 Deployment 超时 300s，`bkn-safe` 排第一。若超时中止，状态文件**不会删**，
> 可修好后直接重跑；需要放宽就加 `-e OPENBKN_MIGRATION_TIMEOUT_SECONDS=600`。
> `start` 成功后会**删掉** `workloads.tsv`，属正常。

---

## P3.1 收尾确认（~~入口仍封闭~~ **本次入口是开的**）☐

```bash
kubectl -n openbkn get pods
helm list -n openbkn
```

✅ 约 17 个 Pod Running，`core-data-migrator-job-*` Completed
✅ **`bkn-safe` 的 release 状态本来就是 `deployed`** —— 你的脚本没有 `--wait`，helm 不会因
CrashLoop 标 `failed`（2026-10-16 实测）。**所以 P3.5 没有「刷正状态」这件事要做**，见该节。

## P3.2 授权冒烟（走集群内）☐

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

✅ `change-password: 400`、`capabilities: 401`
❌ `change-password` 是 **404** → **不要开入口**（路由/版本不对）

```bash
openbkn --version      # 升级后 CLI 可以放开了
openbkn auth login     # CLI 需与平台同为 0.1.5
openbkn bkn list       # 应能列出知识网络
```

> 可以撤掉 `ONBOARD_SKIP_OPENBKN_INSTALL=true`（见 `hybrid-deploy.md` §6.2）。
> 但**先别跑 `onboard.sh`** —— 它会做业务初始化，等入口开了、验证完再说。

## P3.3 开放入口 ☐

```bash
kubectl apply -f /root/openbkn-entry-tls.yaml

openssl s_client -connect openbkn.changhong.com:443 -servername openbkn.changhong.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
for u in http://openbkn.changhong.com/studio https://openbkn.changhong.com/studio \
         http://openbkn.changhong.com/api/safe/v1/capabilities https://openbkn.changhong.com/api/safe/v1/capabilities; do
  printf '%s\t' "$u"; curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' "$u"
done
```

✅ 证书是 GlobalSign `*.changhong.com`（2026-12-12 到期）；四条路径回到 `308` / `301 → /studio/` / `401` / `401`

## P3.4 恢复 CronJob ☐

```bash
kubectl -n openbkn patch cronjob bkn-backend-trace-outbox-cleanup    -p '{"spec":{"suspend":false}}'
kubectl -n openbkn patch cronjob ontology-query-trace-outbox-cleanup -p '{"spec":{"suspend":false}}'
kubectl -n openbkn get cronjob     # SUSPEND 应回到 False
```

## P3.5 收尾检查 ☐

**① 先看 helm 状态 —— 多半什么都不用做**

```bash
helm list -n openbkn
```

✅ **15 个 release 全部 `deployed`** → **直接跳到 ②，不要重跑部署。** 你的脚本没有 `--wait`，
helm 不等 rollout，`bkn-safe` 的 CrashLoop 从来不会把它标成 `failed`（2026-10-16 实测）。

**仅当真出现 `failed` / `pending` 时**，才用下面这条重跑：

```bash
cd /opt/bkn-foundry/deploy

OPENBKN_SKIP_PLATFORM_BOOTSTRAP=true \
OPENBKN_SKIP_DATA_SERVICES_BUNDLE=true \
  bash ./deploy.sh \
    --config=/opt/bkn-foundry/my-config.yaml --force-upgrade \
    openbkn install --version=0.1.5 \
    --version_file=/opt/bkn-foundry/deploy/release-manifests/0.1.5/bkn-foundry.yaml \
    --charts_dir=/opt/bkn-charts \
    --access_address=https://openbkn.changhong.com
```

> **重跑的代价**（这正是「状态正常就别跑」的理由）：hydra 的 OAuth client 会被
> `client-seed-job` 重新登记（client_id 不变）—— **走 SSO 的外部系统需重新取 token，提前知会**。

**② 收尾判定**

```bash
bash ./deploy.sh --config=/opt/bkn-foundry/my-config.yaml openbkn status
helm list -n openbkn
kubectl -n openbkn get pods | grep -v Running
```

✅ 无 drift；**15 个 release 全部 `deployed`**；Pod 全 Running 且重启数不再增长

## P3.6 浏览器走一遍 ☐

工作台 → 登录（`/login` → hydra 回调）→ 改密码页 → 进一个知识网络看**创建者是否还有管理权限**（本次回填的直接验证点）

## P3.7 升级后必做 ☐

**① ingress 路径 diff**（你的 host 一旦声明，catch-all 就不再兜底该域名，漏的路径直接 404）：

```bash
kubectl -n openbkn get ingress -o jsonpath='{range .items[*]}{range .spec.rules[*].http.paths[*]}{.path}{" -> "}{.backend.service.name}{":"}{.backend.service.port.number}{"\n"}{end}{end}' | sort -u > /tmp/live-after.txt
diff /tmp/bkn-paths-live.txt /tmp/live-after.txt
```

只出现在右边的新路径要补进 `hw-public-openbkn.changhong.com-443` 并同步 `/root/openbkn-entry-tls.yaml`。

> **本次实测（2026-10-16）：diff 是 `21a22,25` —— 纯新增，没有任何业务路径消失**，
> 所以不存在「原本能走、升级后 404」的业务回归。
>
> 新增的 4 条全是 `/install-status*`，来自**部署脚本自己**的组件
> （`deploy/conf/install-status/endpoint.yaml`，由 `status.sh` 创建；`install-status` **不在
> 0.1.5 的 15 个 chart 里**）。它的 Ingress **有意不带 host**，靠 catch-all 兜底。
>
> **★ 这 4 条要补，不是「不要补」**（2026-10-16 修正，我先前判错过一次）：
> `openbkn.sh:1899-1907` 在安装结束时会把 `https://<access_address>/install-status` 当作
> **「Verify your installation」的链接打印给操作者**。而 host 专属 Ingress 一声明，
> catch-all 就不再兜底该域名 —— **那个链接在你这里是坏的**。补上（`Exact` 类型，与现有 Prefix 路径不冲突）：
>
> ```bash
> kubectl -n openbkn patch ingress hw-public-openbkn.changhong.com-443 --type=json -p "$(cat /tmp/install-status-paths.json)"
> ```
>
> 其中 `/tmp/install-status-paths.json` 见 runbook §5.7（同一个文件，两处共用）。
> 补完同步进 `/root/openbkn-entry-tls.yaml`，并验证：
> `curl -s -o /dev/null -w '%{http_code}\n' https://openbkn.changhong.com/install-status` → `200`
>
> ⚠️ **知情后再决定**：`.pods.json` / `.workloads.json` 就是 `kubectl get pods -o json` 与
> `kubectl get deploy,sts -o json` 的原样输出（Pod 名、镜像 tag、节点名、Pod IP、就绪状态）。
> 脚本的 ServiceAccount 只对这三类资源有只读权（**无 secrets、无 helm**），上游注释称其
> "non-sensitive"。**但这是要放到对外域名下的东西 —— 先确认这个域名是内网还是公网。**
> 另外这层暴露**已经存在**：该 Ingress 无 host，任何未被其他 Ingress 声明的域名下这些端点都可达。

**② `normal_user` 补偿验证**（12 人，见 `$W/reports/normal-user-impact.txt`）：

```bash
read -rsp 'MariaDB 口令: ' DB_PW; echo; export DB_PW
docker run --rm --network host -e DB_PW bkn-migrate:0.1.5 bash -lc '
export MYSQL_PWD="$DB_PW"
mariadb -h 10.67.51.9 -u openbkn --batch --raw -e "
SELECT (SELECT COUNT(*) FROM safe.roles WHERE id=\"b5f9ac3e-992c-4bbd-8126-95e87e51c46e\") AS role_rows,
       (SELECT COUNT(*) FROM safe.casbin_rule WHERE ptype=\"g\" AND v1=\"b5f9ac3e-992c-4bbd-8126-95e87e51c46e\") AS g_rows,
       (SELECT COUNT(*) FROM safe.casbin_rule WHERE ptype=\"p\" AND v0=\"b5f9ac3e-992c-4bbd-8126-95e87e51c46e\") AS p_rows;"'
unset DB_PW
```

✅ 三行都是 `0`（已删干净）

| 用受影响账号测 | 预期 |
| --- | --- |
| 跑一次**内置**技能 / 工具箱 | ✅ 正常（内置组件有全员公共授权） |
| 访问**别人自建**的技能 | ⚠️ **被拒是预期**（0.1.5 取消了类型级允许） |
| 访问**自己建的**技能 | ✅ 正常（创建者授权） |

**只有当内置资源也不可用时才算真问题**。那时才按资源逐个补授，补完通知这 12 个人。
**不要手工往 `casbin_rule` 插回那 7 条策略**（会绕过 `authorization_grant` 台账）。

---

**③ ★ sandbox 的 DNS egress（不做就等着 ~10 分钟一轮 crashloop）**

0.1.5 给 sandbox 新增的 egress NetworkPolicy 只放通 `kube-system/k8s-app=kube-dns` 的 DNS，
本集群用 **NodeLocal DNSCache（`169.254.25.10`）** → 新建 agent 会话解析不了域名 →
s3fs 等满 300s `connect_timeout` → `ECONNABORTED` → 约 **10 分钟**一轮重启。
**根因/证据链见 runbook §7 第 9 条。**

```bash
# 贴一次修复（幂等，文件不属于任何 helm release）
kubectl apply -f /tmp/sandbox-executor-egress-site.yaml

# 新建一个 agent 会话，然后看重启计数是否停住
kubectl -n openbkn get pod -l app=sandbox-executor \
  -o custom-columns='RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.containerStatuses[0].state.running.startedAt,LASTCRASH:.status.containerStatuses[0].lastState.terminated.finishedAt'
kubectl -n openbkn logs -l app=sandbox-executor -c executor --tail=20 | grep container_ready
```

**判定**：`STARTED` 是**当前容器**的启动时间 = 这一轮跑了多久。崩溃周期 ~10.5 分钟，
所以「`STARTED` 距现在 **> 15 分钟** 且 `RESTARTS` 没涨」才算停住。`LASTCRASH` 为
`<none>` 说明这个容器一次都没崩过，是最强证据。**只看 `RESTARTS` 数值会被修复前的旧计数骗到。**

✅ 本集群实测：`RESTARTS 0` / `LASTCRASH <none>` / 连续存活 **17.8 分钟**（修复前是 21 分钟 2 次），
日志出现 `container_ready sent successfully`
✅ 最终验收：**新开一个全新会话（新 session id）走控制面正常起来**（2026-10-16）
❌ 仍在涨 → 贴回 `describe pod` + `get networkpolicy -o yaml`

> **为什么必须主动做、不能等报障**：升级窗口里跑的都是**升级前建的**会话 Pod，不受新策略影响；
> 这个问题只在**升级后第一次有人新建会话**时才暴露。日志只有一句
> `Software caused connection abort`，极容易被当成业务侧问题排查半天。

---

## 回滚速查（对应 runbook §6）

> **★ P2.3 一跑，回 0.1.4 就必须恢复数据库。**
> `01-remove-business-domain.sql` 删了 `t_knowledge_network.f_business_domain`，
> 而 0.1.4 的 bkn-backend 显式 SELECT 它 → 只退版本不恢复库会报 `Unknown column`。

| 卡在哪 | 处置 |
| --- | --- |
| P2.4 硬闸没过 | 业务还没停，最便宜的中止点。修原因后**重跑 P2.3**（幂等）。marker 非 0 → **立刻停下贴回来** |
| P2.6 / P2.8 有 block | 数据未改。修原因重跑，业务保持停止 |
| P2.7 apply 失败 | 用 `$W/reports/p2-apply/01-bkn-data.json` 里记录的恢复命令恢复 BKN+Safe。业务保持停止 |
| P2.3 卡在 `core-data-migrator` | **先查库**（`§6.4` 的 `f_business_domain` / `tenant_id` 查询），再决定 |

**回到 0.1.4 完整步骤**：

```bash
# ① 保持五个 Deployment 停止、入口封闭
# ② 恢复两个库（来自 P1.5，不是 migrate.py 自建的那份）
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

**入口回退**：

```bash
kubectl apply -f /root/openbkn-entry-tls.yaml
# 或恢复封堵前快照
kubectl apply -f "$W/backup/ing-443.yaml"
kubectl apply -f "$W/backup/ing-443-studio.yaml"
```

> **回退最可能卡住的地方**：0.1.4 的三个 hotfix 镜像
> （`agent-operator-integration` / `sandbox` / `agent-retrieval`）**只在 GHCR 有**。
> 进窗口前确认节点上还留着 0.1.4 的镜像。

---

## 附：三条最容易踩的坑

1. **`read -rsp ... DB_PW` 之后必须 `export DB_PW`** —— 少了它 `-e DB_PW` 会传空串，
   报 `Access denied ... (using password: NO)`。**`using password: NO` 是口令为空，不是口令错。**
2. **`bkn-safe` 显示 `failed` + `CrashLoopBackOff` 是预期的**，等 P2.7 写完标记会自愈。
   不要为了让它变绿去改标记或补数据。
3. **sandbox 会话在升级后第一次新建时才会炸**（DNS egress，见 P3.7③）。
   窗口内所有验证都是绿的也不代表它没问题 —— **必须专门新建一个会话去验**。
3. **`migrate.py apply` 会复核五个 Deployment 是否仍在停止** —— 提前 `start` 会让它拒绝执行。