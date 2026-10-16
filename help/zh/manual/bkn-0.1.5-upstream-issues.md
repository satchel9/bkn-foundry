# 0.1.5 升级中发现的两条上游缺陷 —— issue 草稿（**未提交**）

> **状态：草稿，只在本地。** 按 `AGENTS.md` 的 hard rule，未经请求者批准不得创建 /
> 更新任何 Issue。参考 [`.github/ISSUE_TEMPLATE/bug_report.md`](../../../.github/ISSUE_TEMPLATE/bug_report.md)
> 的章节结构填写，**未删除任何必需章节**。
>
> | # | 目标仓库 | 标题 | 影响面 | 是否已修（2026-10-16 核对） |
> | --- | --- | --- | --- | --- |
> | A | `openbkn-ai/bkn-foundry` | sandbox executor egress NetworkPolicy 不认 NodeLocal DNSCache | **大** —— 任何「启用 nodelocaldns **且** CNI 真的执行 NetworkPolicy」的集群，升级后新建的 agent 会话全部不可用 | ❌ 未修（模板与 0.1.5 发布件逐字节一致） |
> | B | `openbkn-ai/openbkn-deploy` | `backfill_creator_grants.py` **在两种顺序下都跑不通** | **大** —— 从 0.1.4 基线出发，文档要求的顺序和实际可行的顺序**都会失败** | ❌ 未修（`main` / `release/0.1.5` 均已核实） |
>
> ### B 的影响面修正（两轮，**第二次推翻第一次**）
>
> **第一轮**我写的是「每个在部署之后跑回填的升级者都会撞上」，然后读到
> `network_builder_scope/README.md` 第 3 行明确写了顺序而**收回**：
>
> > Run this package **before** deploying a bkn-safe image whose `network_builder` seed grants
> > contain only `catalog:* / create` and `knowledge_network:* / create`.
>
> 当时我判断「照 README 顺序跑就不会触发，只是顺序敏感的哑雷」。
>
> **第二轮（本轮）把这个判断也推翻了 —— 照 README 的顺序根本跑不起来。** 因为
> `backfill_creator_grants.py` 读的第二张表 `authorization_grant` 在 0.1.4 的库里**不存在**：
>
> | 证据 | 结果 |
> | --- | --- |
> | `authorization_grant` 在 **v0.1.4** 全仓库命中 | **0**（对照组 `casbin_rule` 命中 5，证明 grep 有效；`bkn-safe/` 目录在 v0.1.4 存在） |
> | 同串在 **v0.1.5** 命中 | **10** |
> | 有没有 SQL 建这张表 | **没有**（`CREATE TABLE … authorization_grant` 在 v0.1.5 与 HEAD 均 0 命中） |
> | 那它从哪来 | `model.AllModels()` 含 `&AuthorizationGrant{}`（v0.1.5 `model.go:480`）→ bkn-safe 启动时 `database.go:64` 的 `db.AutoMigrate(model.AllModels()...)` |
>
> ⇒ 这张表**只在 0.1.5 的 bkn-safe 启动之后才存在**。而 `creator_grants()` 对每个
> `f_creator` 非空的资源都会查它（`run()` 里 `if resource.creator_id` 无分支绕过）——
> 所以在「部署前」这个 README 要求的时点跑，必然 `Table 'safe.authorization_grant' doesn't exist`。
>
> **合并结论**：
>
> | 顺序 | 结果 |
> | --- | --- |
> | README 要求的：**部署前**跑（0.1.4 的库） | ❌ `authorization_grant` 表不存在 |
> | 实际可行的：**部署后**跑（0.1.5 的库） | ❌ `t_catalog.f_internal` 已被 RENAME |
> | 部署后跑 **+ 打上列名补丁** | ✅ 只有这条能通 —— 也就是我们实际做的 |
>
> 所以 B 不是「顺序敏感的哑雷」，是**这个包从 0.1.4 基线出发、按出厂状态在两种顺序下都跑不通**。
> 顺带解释了为什么用户会落到第二种顺序：同目录的兄弟包
> `permission_model_transition/README.zh.md` 第 5 行自称「本目录是 OpenBKN 0.1.5 **安装后**的
> 权限模型一次性迁移入口」，两个包对「安装前/后」的要求方向相反、且互不引用
> （双向 0 命中），仓库根 `README.md` / `README.zh.md` 对这两个包也是 0 命中，
> `scripts/upgrades/README.md` 是 **404**。照目录惯例走，就会走到坏的那条路上。
>
> **提交前需要你决定的**：
> 1. ~~B 的目标仓库路径~~ —— **已核实**：`openbkn-deploy@main` 上路径是
>    `scripts/upgrades/0.1.5/network_builder_scope/backfill_creator_grants.py`
>    （`deploy/` 前缀已去掉），该文件与移出前**逐字节一致**，第 128 行仍是 `f_internal`；
>    `release/0.1.5` 分支同样。`main` 最新 push 是 2026-10-16T08:15Z。
> 2. ~~C 要不要单开~~ —— **已并入 B**。两个缺陷同包、同「顺序」主题、同修复面，
>    拆成三条只是噪音。顺序文档缺口作为 B 的次级诉求。
> 3. 是否附上你们的站点信息（集群版本、CNI、nodelocaldns 版本）。草稿里**已隐去**内部 IP
>    与域名，只留 `169.254.25.10`（这是上游标准值，不算敏感）。
> 4. 要不要带上 A 的补丁 PR。草稿目前只报缺陷 + 给最小修法建议。

---
---

# Issue A

**Repository**: `openbkn-ai/bkn-foundry`
**Suggested title**: `sandbox chart: executor egress NetworkPolicy denies DNS on clusters using NodeLocal DNSCache`

## Description

The executor egress NetworkPolicy added by the sandbox chart has exactly one DNS rule, and it
matches DNS by **pod identity**:

```yaml
# infra/sandbox/deploy/helm/sandbox/templates/networkpolicy.yaml
# (rendered name: <release>-sandbox-executor-egress)
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: {{ .Values.networkPolicy.dns.namespace | quote }}
        podSelector:
          matchLabels:
            {{- toYaml .Values.networkPolicy.dns.podSelector | nindent 14 }}
    ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
```

with the defaults

```yaml
# infra/sandbox/deploy/helm/sandbox/values.yaml
networkPolicy:
  enabled: true
  dns:
    namespace: kube-system
    podSelector:
      k8s-app: kube-dns
```

That matches the **CoreDNS ClusterIP form only**. Clusters running **NodeLocal DNSCache** have
`/etc/resolv.conf` pointing at a **link-local address** (`169.254.25.10` in the standard
NodeLocal DNSCache manifest) bound by a **host-network DaemonSet**. Such an address is neither
in `kube-system` nor attributable to a pod, so it matches neither the `namespaceSelector` nor the
`podSelector` — and because `policyTypes: [Egress]` with a non-empty `egress` list means
**deny-by-default for everything unmatched**, DNS is silently dropped.

The same address is also excluded from the other candidate rule: `networkPolicy.publicHttps.ipBlocks`
lists `169.254.0.0/16` in its `except` set.

Result: the executor cannot resolve any name, its **s3fs** workspace mount waits out its own
default `connect_timeout=300s`, aborts, and the container exits 1 — producing a **~10 minute
CrashLoop** with no probe failure, no OOM, and a single misleading log line.

## Steps to reproduce

1. Install a cluster with **NodeLocal DNSCache** enabled (pod `/etc/resolv.conf` →
   `nameserver 169.254.25.10`).
2. Deploy the sandbox chart with its default values (`networkPolicy.enabled: true`).
3. Start a new agent session so an `sandbox-executor` pod (labels `app=sandbox-executor`,
   `managed_by=sandbox-control-plane`, `sandbox-type: execution`) is created.
4. Inside the executor container, run `getent hosts <any-name>` → **hangs indefinitely**.

Isolation that confirms DNS specifically, not egress in general: connecting to a destination the
policy *does* allow (the control-plane pod, port 8000) succeeds, while connecting to
`169.254.25.10:53` times out.

## Expected behavior

The executor can resolve cluster and external names on a cluster whose pods are configured to use
NodeLocal DNSCache, exactly as it can on a cluster using the CoreDNS ClusterIP.

## Actual behavior

```text
$ getent hosts <any-name>            # hangs, never returns
$ # from a socket probe, in the executor's network namespace:
169.254.25.10:53   -> TimeoutError
<control-plane> :8000 -> OPEN        # the allowed path works, so egress is fine
```

Executor logs, shortly before each restart:

```text
mkdir: cannot create directory '...': Software caused connection abort
```

`s3fs` reports `ECONNABORTED` after its 300s `connect_timeout`; the ~10 minute restart period is
s3fs's retry loop, not a Kubernetes mechanism.

## Environment

- Kubernetes: v1.23.14 (on-premise, self-managed)
- Deployment: Bring-your-own-Kubernetes; chart `sandbox` version `0.1.0` as shipped in the **0.1.5**
  release bundle
- Chart defaults in effect: `networkPolicy.enabled: true`, `networkPolicy.dns.namespace: kube-system`,
  `networkPolicy.dns.podSelector: {k8s-app: kube-dns}`
- CNI: enforces NetworkPolicy (the deny is observed, so enforcement is active)
- DNS: **NodeLocal DNSCache**, `/etc/resolv.conf` → `nameserver 169.254.25.10`
- `networkPolicy.additionalEgress`: `[]` (empty — the chart's own escape hatch was not used)

## Acceptance Criteria (Definition of Done)

- [ ] On a cluster using NodeLocal DNSCache and **default chart values**, a newly created
      `sandbox-executor` pod resolves names (`getent hosts` returns) and its S3 workspace mount
      succeeds without a restart.
- [ ] A regression test covers it — e.g. a template unit test asserting that the rendered
      NetworkPolicy contains a DNS-allow rule that is satisfied when the cluster's resolver is a
      link-local address, not only when it is a pod in `kube-system`.
- [ ] The correct behaviour is reachable **without** the operator having to know about
      `additionalEgress` in advance (see Boundaries for the acceptable forms).
- [ ] CI green.

## Boundaries / Risk

- **Semantics to preserve**: this policy exists because executor pods run untrusted user/model code.
  Any fix must keep the default-deny posture for cluster, private, and link-local destinations —
  the ask is **one narrowly-scoped DNS exception**, not a broadening of egress. Reviewers should
  reject a fix that widens `publicHttps.ipBlocks` or removes `169.254.0.0/16` from its `except`.
- **Acceptable forms** (any one is sufficient):
  1. a values field for extra DNS endpoints (e.g. `networkPolicy.dns.ipBlocks: []`, rendered as an
     additional 53/UDP+TCP rule) — preferred, since it is discoverable and each site sets its own
     local resolver address;
  2. documenting the NodeLocal DNSCache case in the chart's `values.yaml` comment block and in the
     upgrade notes, pointing at the existing `networkPolicy.additionalEgress`;
  3. auto-detection is *not* required and is probably not worth the complexity.
- **Do not** hardcode `169.254.25.10` as a constant without a way to override it: the address comes
  from the site's NodeLocal DNSCache deployment, so a site using a different local DNS IP would be
  broken by the fix.
- No data, schema, or permission changes are involved. This is a manifest/template change.
- Rollout risk: adding a DNS-allow rule is additive; **no existing installation loses reachability**
  from it. Existing executor pods are unaffected either way — NetworkPolicy is evaluated at
  connection time, so the fix takes effect for the next connection, but pods that never resolve a
  name never notice the change.

## Additional context

### Workaround we are running in production, and its verification

A second, additive NetworkPolicy (NetworkPolicy is additive: if any policy selecting the pod
allows a connection, it is allowed). The name is deliberately different so it is owned by no Helm
release and survives chart upgrades:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: sandbox-executor-egress-site
  namespace: <sandbox-namespace>
spec:
  podSelector:
    matchLabels:
      app: sandbox-executor
      managed_by: sandbox-control-plane
      sandbox-type: execution
  policyTypes: [Egress]
  egress:
    - to: [{ipBlock: {cidr: 169.254.25.10/32}}]   # NodeLocal DNSCache
      ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
```

Applying the DNS rule fixes it. Note: we applied it **together with** the external-MinIO rules below
in a single patch, so the table is not a controlled experiment isolating one rule from the other.
The DNS fault is established by the direct evidence in "Steps to reproduce" instead — `resolv.conf`
points at `169.254.25.10`, a policy-allowed destination on port 8000 is **OPEN** while
`169.254.25.10:53` **times out**, and the executor resolves nothing. DNS is what the patch had to
fix to get the pod to stop hanging; the MinIO rules are there because that endpoint is genuinely
unreachable under the same deny-by-default policy:

| | before | after |
| --- | --- | --- |
| `getent hosts <name>` in the executor | hangs indefinitely | resolves (cluster DNS ClusterIP) |
| executor restarts | **2 restarts in 21 min** (≈10.5 min per cycle) | **`restartCount 0`, `lastState.terminated` empty, 17.8 min continuous uptime** |
| executor log | `mkdir ... Software caused connection abort` | `container_ready sent successfully` |

### Why it is easy to miss

It does **not** surface during an upgrade window. Executor pods created *before* the upgrade keep
running; the failure only appears the first time someone creates a **new** agent session after the
upgrade. Upstream release notes for 0.1.5 do not mention the new NetworkPolicy as a breaking
change for BYOK clusters.

### Related, but arguably by design (not part of this ask)

With an **external** MinIO (`minio.enabled: false`, endpoint outside the cluster), no rule matches
the S3 endpoint either, so the workspace mount is unreachable even once DNS is fixed. The
`values.yaml` comment block states the intended workflow ("add only legitimate destinations through
`additionalEgress`"), so we treat this as a documentation gap rather than a defect. We mention it
only because it is the *second* rule an external-dependency BYOK operator will need, and it would
be worth one sentence next to the NodeLocal DNSCache note.

### Evidence that the address cannot be matched by pod identity

The NodeLocal DNSCache DaemonSet runs with `hostNetwork: true` and binds the link-local address on
each node; traffic to `169.254.25.10:53` is not attributable to a pod in `kube-system`, so no
`namespaceSelector`/`podSelector` combination can ever match it. An `ipBlock` rule is the only
NetworkPolicy construct that can express it.

---
---

# Issue B

**Repository**: `openbkn-ai/openbkn-deploy`
**Path (verified on `main` and `release/0.1.5`)**: `scripts/upgrades/0.1.5/network_builder_scope/backfill_creator_grants.py`
**Suggested title**: `0.1.5 network_builder_scope backfill cannot run in either documented order (f_internal renamed; authorization_grant missing before install)`

## Description

`backfill_creator_grants.py` has two defects that between them leave no working order from a 0.1.4
baseline:

1. It reads `t_catalog.f_internal`, which `09-add-resource-internal.sql` renames to `f_builtin`
   during the 0.1.5 install. **Run after the install → `Unknown column`.** This one is
   straightforwardly a missed rename (`#1534` added the package 2026-09-13; `#1656` renamed the
   column 2026-09-18 and updated the rest of the tree but not this package).
2. It reads `authorization_grant`, which is created by 0.1.5 bkn-safe's startup `AutoMigrate` and
   is absent in 0.1.4. **Run before the install, the order its own README asks for → table doesn't
   exist.** We found this second one only after reading the README's ordering rule and checking
   whether that order was reachable.

Together: the documented order fails on (2), the natural order fails on (1), and the only way
through is to deploy first and then patch the package locally. That is worth fixing as one issue
because both are the same question — *which side of the install does this package run on?* — and the
answer is currently "neither".

History for defect 1: `#1534` (`fix(authz): scope network builder resource access`, 2026-09-13)
added the package; `#1656` (`refactor(vega): rename built-in catalog and resource marker`,
2026-09-18) renamed the column five days later.

## Steps to reproduce

Start from a 0.1.4 installation. There are two orders, and **both fail as shipped**.

### Order 1 — the one `README.md` asks for (run before deploying)

> `scripts/upgrades/0.1.5/network_builder_scope/README.md`, line 3:
> *Run this package **before** deploying a bkn-safe image whose `network_builder` seed grants
> contain only `catalog:* / create` and `knowledge_network:* / create`.*

```bash
python3 backfill_creator_grants.py --mode dry-run \
  --bkn-dsn 'mysql://…/openbkn' --safe-dsn 'mysql://…/safe'
```

→ `authorization_grant` does not exist yet (see "Why the documented order cannot run" below).

```text
pymysql.err.ProgrammingError: (1146, "Table 'safe.authorization_grant' doesn't exist")
```

### Order 2 — deploy first, then run the package

1. `deploy.sh openbkn install --version=0.1.5 …`. The pre-stage migrator applies
   `migrations/vega-backend/mariadb/0.1.5/09-add-resource-internal.sql`:

   ```sql
   USE openbkn;
   ALTER TABLE t_catalog
       RENAME COLUMN f_internal TO f_builtin;
   ```

2. Run the same command as above.

→ `t_catalog.f_internal` is gone.

```text
pymysql.err.OperationalError: (1054, "Unknown column 'f_internal' in 'field list'")
```

### The only order that works today

Order 2 **plus** the one-word column patch below. That is what we ran, and it is the reason this
report exists: an operator has to discover and apply a local patch before this package will run at
all from a 0.1.4 baseline.

## Why the documented order cannot run

`run()` calls `creator_grants()` for every resource whose `f_creator` is non-empty:

```python
exists = creator_exists(safe_cursor, resource.creator_id) if resource.creator_id else False
grants = creator_grants(safe_cursor, resource) if resource.creator_id else []
```

and `creator_grants()` queries `authorization_grant`:

```python
cursor.execute(
    "SELECT operation, policy_source FROM authorization_grant "
    "WHERE accessor_id = %s AND object = %s AND effect = %s", ...)
```

That table does not exist until a **0.1.5** bkn-safe process has started:

| Check | Result |
| --- | --- |
| `authorization_grant` anywhere in the **v0.1.4** tree | **0 hits** (control: `casbin_rule` → 5 hits, so the search is valid; `bkn-safe/` exists at v0.1.4) |
| Same string in **v0.1.5** | **10 hits** |
| Any SQL that creates it (`CREATE TABLE … authorization_grant`) | **0 hits** at v0.1.5 and at HEAD |
| What creates it instead | `model.AllModels()` includes `&AuthorizationGrant{}` (v0.1.5 `bkn-safe/server/internal/model/model.go:480`) → `bkn-safe/server/internal/database/database.go:64` runs `db.AutoMigrate(model.AllModels()...)` at startup |

So the table appears only once the 0.1.5 bkn-safe has been deployed — which is exactly what the
README's ordering excludes. **We have not reproduced Order 1 on a live cluster** (we only had one
0.1.4 installation to upgrade, and we had already deployed); this section is a code-level deduction.
It is worth confirming against a staging 0.1.4 install before the fix is written, because if it
holds, the README's ordering instruction is unsatisfiable and should change along with the code.

## Expected behavior

`--mode dry-run` produces the plan report (`summary` / `items`) from a 0.1.4 installation, without
the operator needing to patch the package or to know which of two orders is intended.

## Actual behavior

Both orders fail, with the two different errors above. `backfill_creator_grants.py:128`:

```python
cursor.execute("SELECT f_id, f_creator, f_creator_type, f_internal FROM t_catalog")
```

The column is `f_builtin` by the time this package can run.

## Environment

- Kubernetes: v1.23.14 (on-premise)
- Upgrade path: 0.1.4 → 0.1.5
- Database: **external** MariaDB (BYOK), so the 0.1.5 migrations and this backfill run as separate
  manual steps rather than in one scripted pass
- Package revision: `scripts/upgrades/0.1.5/network_builder_scope/backfill_creator_grants.py`
  on `openbkn-deploy@main` (verified 2026-10-16) — line 128 still selects `f_internal`
- Order actually run: 0.1.5 deployment (**and** its migrations) first, then this package — i.e. the
  order the README's rule excludes, because we could not tell that the rule was load-bearing
- Sibling package `scripts/upgrades/0.1.5/permission_model_transition/README.zh.md` line 5 calls
  itself *"本目录是 OpenBKN 0.1.5 **安装后**的权限模型一次性迁移入口"* — i.e. the sibling in the
  same directory asks for the opposite placement, and the two READMEs do not reference each other

## Acceptance Criteria (Definition of Done)

- [ ] `backfill_creator_grants.py` runs successfully from a 0.1.4 baseline **without a local patch**,
      under whichever order the maintainers intend.
- [ ] If the intended order is "after install", `f_builtin` replaces `f_internal` so that order works.
- [ ] If the intended order is genuinely "before install", the package must not depend on
      `authorization_grant` existing — decide and state which, because today it is neither.
- [ ] A regression test covers it. `test_backfill_creator_grants.py` already has the right hook:
      `test_knowledge_network_backfill_reads_only_the_main_branch` calls
      `migration.fetch_resources(cursor)` against a stub cursor and asserts on the emitted SQL
      (`COALESCE(NULLIF(f_branch, ''), %s) = %s`). That test exercises **the exact function that
      contains this bug** and still passes, because the stub records SQL as an opaque string and
      never parses it. Extend it in style — assert the first recorded statement names `f_builtin`
      and does not name `f_internal`. (A test that actually runs the query would be stronger, but
      the stub is the established pattern here and it would have caught this.)
- [ ] The ordering requirement is stated somewhere an operator will actually read it — see Boundaries.
- [ ] CI green.

## Boundaries / Risk

- **Value semantics are identical** — this is the same `RENAME COLUMN`, so the fix is a one-word
  change. `plan_resource()`'s `if resource.internal:` early-return is unchanged.
- **Ordering: this needs a decision, not a doc tweak.** Nothing in the repository says which side of
  the install this package belongs on, and the two available signals point opposite ways:
  - `network_builder_scope/README.md` says run **before** deploying the narrowed-seed bkn-safe image;
  - its sibling `permission_model_transition/README.zh.md` line 5 calls itself
    *"本目录是 OpenBKN 0.1.5 **安装后**的权限模型一次性迁移入口"* — run **after** install;
  - the two READMEs do not reference each other (0 hits each way);
  - root `README.md` and `README.zh.md` never mention either package (0 hits);
  - `scripts/upgrades/README.md` does not exist (HTTP 404).

  An operator who treats "upgrade to 0.1.5" as one step, matching the sibling package's wording,
  lands on the broken path. We would like one of these to be deliberate:
  1. **Move the package after the install** (fix defect 1) — then its `authorization_grant`
     dependency is satisfied and the order is consistent with its sibling. This is the smaller
     change and the one we would suggest, since we do not see how defect 2 can be satisfied before
     the install without giving the package its own schema bootstrap; or
  2. **Keep it before the install** — then the package needs to create or tolerate a missing
     `authorization_grant`, and both READMEs should state the order and that the two orders produce
     different plan output, since the backfill writes `authorization_grant` rows that
     `permission_model_transition` also plans.
- **Do not** "fix" defect 1 with a compatibility shim that accepts either column name. The rename is
  deliberate and already applied to the rest of the tree; probing `information_schema` for the old
  name would keep a dead column name alive and would silently mis-handle a database where neither
  name exists.
- No data is written by `--mode dry-run`. `--mode apply` writes `authorization_grant` +
  `casbin_rule` rows; nothing here deletes or rewrites existing grants.

## Additional context

### Fix

Defect 1 (one word):

```diff
-    cursor.execute("SELECT f_id, f_creator, f_creator_type, f_internal FROM t_catalog")
+    cursor.execute("SELECT f_id, f_creator, f_creator_type, f_builtin FROM t_catalog")
```

Defect 2 needs a decision rather than a diff — either move the package's documented position to
after the install (which makes the `authorization_grant` dependency valid and matches the sibling
package), or give it an explicit dependency/bootstrap for that table. We have not proposed a patch
for it because we do not know which order was intended, and the two answers lead to different code.

### Value-identity check

`09-add-resource-internal.sql` only renames; it does not change the boolean's meaning. It then sets
`f_builtin = TRUE` for the fixed system Datasets, matching what `f_internal` already held for
`t_catalog` rows. Our `dry-run` after the one-word patch classified the two built-in catalogs as
`skip` with reason `internal catalog` — the intended behaviour — which confirms the value semantics
survived the rename.

### Local workaround

```bash
cd <package-dir>
cp -a backfill_creator_grants.py backfill_creator_grants.py.orig
sed -i 's/f_internal FROM t_catalog/f_builtin FROM t_catalog/' backfill_creator_grants.py
diff backfill_creator_grants.py.orig backfill_creator_grants.py   # expect exactly one hunk
```

### Cross-check performed

Verified on `openbkn-ai/openbkn-deploy` (GitHub API / raw, 2026-10-16; `main` last pushed
2026-10-16T08:15Z), and against the tags in `openbkn-ai/bkn-foundry`:

- path is `scripts/upgrades/0.1.5/network_builder_scope/backfill_creator_grants.py` — the `deploy/`
  prefix was dropped in the split; `release/0.1.5` has the same layout;
- the file on `main` is **byte-identical** to the revision that left `bkn-foundry` at `c3ea77407^`,
  and line 128 still reads `... f_internal FROM t_catalog` — so nothing has changed since the move;
- `test_backfill_creator_grants.py` exists on `main` and contains no reference to `t_catalog`,
  `f_internal`, or `f_builtin`;
- `authorization_grant`: 0 hits at tag `v0.1.4`, 10 hits at tag `v0.1.5`; no `CREATE TABLE` for it
  in either tag or at HEAD;
- `bkn-safe/server/internal/model/model.go` line 480 (at `v0.1.5`) lists `&AuthorizationGrant{}` in
  `AllModels()`, and `bkn-safe/server/internal/database/database.go:64` auto-migrates it at startup;
- cross-reference counts quoted in Boundaries were checked by fetching both root READMEs and both
  package READMEs and counting matches; `scripts/upgrades/README.md` returns HTTP 404.

### Not reproduced

Defect 2 (the missing `authorization_grant` before install) is a **code-level deduction**, not an
observed failure — we had a single 0.1.4 installation and had already deployed before we read the
README's ordering rule, so we could not go back and run it early. Everything in the table above was
verified directly; the inference from it is the claim that the query errors out. Please confirm on a
staging 0.1.4 install, since the fix for defect 1 alone would leave the package unusable in the
order its own README specifies.