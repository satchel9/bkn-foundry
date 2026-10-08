# BKN Foundry 混部部署手册

> **平台 0.1.4 · K8s v1.23.14（6 节点，CentOS 7）· 命名空间 `openbkn` · 入口 `openbkn.changhong.com`**

在既有 K8s 集群上只装应用层，把 MariaDB、OpenSearch、Redis、Kafka、MinIO 全部外置，复用集群已有的 nginx ingress。本文记录该拓扑下实际可用的完整步骤与每一个会踩到的坑。

---

## 拓扑

**集群内**——只有应用层，15 个 Helm release，全部无状态可重建：

| 服务 | 职责 |
| --- | --- |
| `bkn-safe` (+ 内置 hydra / postgres) | 认证、授权、目录 |
| `vega-backend` | 数据目录 |
| `bkn-backend` | 知识网络 |
| `ontology-query` | 本体查询 |
| `agent-operator-integration` | 算子运行时 |
| `agent-retrieval` · `bkn-agent` | 检索 / Agent |
| `agent-observability` · `otelcol-contrib` | 可观测 |
| `mf-model-manager` · `mf-model-api` | 模型网关 |
| `oss-gateway-backend` · `sandbox` | 对象存储网关、沙箱 |
| `bkn-studio` | 控制台 |

**集群外**——全部中间件，落在独立主机。这是与标准安装最大的差别，也是绝大多数故障的来源：

| 服务 | 地址 |
| --- | --- |
| MariaDB | `10.67.51.9:3306` |
| OpenSearch | `10.67.51.9:9200`（http，security 插件关闭） |
| Redis | `10.67.51.9:6379`（standalone，密码） |
| Kafka | `10.67.51.8:9092`（SASL PLAIN） |
| MinIO | `10.67.51.9:9000`（bucket `open-bkn`） |
| Ingress | `124.70.84.198`，class `nginx-hw-public` |

> ⚠️ **已知风险**：集群 K8s 为 v1.23.14，低于平台 `preflight_checks.sh` 要求的最低 1.24（推荐 1.26–1.30）。本次全部 chart 渲染与部署成功，但后续升级或用新版 chart 时可能出现 API 版本缺口。

---

## 01 前置准备

### 1.1 升级 Helm

平台脚本要求 Helm ≥ 3.10（`common.sh` 的 `OPENBKN_HELM_MIN_SEMVER`）。3.9 及更早在 bkn-safe 渲染时报 `index of untyped nil`——Go 模板惰性求值在 Go 1.18 才支持。针对 K8s 1.23–1.27 选 **3.12.3**。

### 1.2 初始化外置数据库

平台需要 4 个库。`safe` 由 bkn-safe 的 GORM AutoMigrate 自建表，但**库本身必须预建**；`deploy` 库下两张管控表也必须手工创建，否则 `external` 模式下迁移拒绝启动。

```sql
CREATE DATABASE IF NOT EXISTS openbkn   DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS safe      DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS bkn_trace DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS deploy    DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

CREATE USER IF NOT EXISTS 'openbkn'@'%' IDENTIFIED BY '<MARIADB_PASSWORD>';
GRANT ALL PRIVILEGES ON openbkn.*   TO 'openbkn'@'%';
GRANT ALL PRIVILEGES ON safe.*      TO 'openbkn'@'%';
GRANT ALL PRIVILEGES ON bkn_trace.* TO 'openbkn'@'%';
GRANT ALL PRIVILEGES ON deploy.*    TO 'openbkn'@'%';
FLUSH PRIVILEGES;
```

> `deploy` 库的两张管控表（`t_schema_migration_task`、`t_schema_migration_history`）的建表语句在安装包里**不存在**（`deploy/scripts/sql/` 下没有对应目录），需从 data-migrator 源码里的 DDL 抄。这是平台的一个打包缺口。

### 1.3 为 bkn-safe 的 postgres 建静态 PV

bkn-safe chart 内置 postgres（承载 hydra），其 PVC **不写 `storageClassName`**。集群没有默认 StorageClass 时，必须建一个同样不写该字段的静态 PV 才能绑上。

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: bkn-safe-postgres-pv
spec:
  capacity:
    storage: 10Gi
  accessModes: ["ReadWriteOnce"]
  storageClassName: ""          # 空字符串 = 只与同样为空的 PVC 绑定
  persistentVolumeReclaimPolicy: Retain
  local:
    path: /data/bkn-safe-postgres
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: ["node5"]   # local 卷必须钉在具体节点
```

### 1.4 准备镜像与 chart

所有 chart 的 `pullPolicy` 都是 `IfNotPresent`，节点上本地 tag 过的镜像优先于仓库查询。节点容器运行时是 `docker://20.10.8`，`docker pull` + `docker tag` 即可，不需要 crictl 导入。

> ⚠️ **hotfix 镜像必须从 GHCR 取。** manifest 里三个 release 钉的是 `0.1.4-hotfix-supply-sample-p1`：`agent-operator-integration`、`sandbox`、`agent-retrieval`。该 tag 在 SWR 上不存在（`manifest unknown`），只在 GHCR 有。**不要图省事换成 `0.1.4`**——hotfix 含一个凭据转发的安全修复。

---

## 02 平台配置

配置写成 `/opt/bkn-foundry/my-config.yaml`，`chmod 600`。它既作为 Helm values 注入每个 release，也被 onboard 和状态脚本读取。

### ⚠️ 两条硬规则

**① 不要在顶层写 `mode:`**
平台的 `mode: Community` 会覆盖 otelcol-contrib chart 自己的 `mode: deployment`，导致 `Only mode=deployment is supported`。全平台只有 otelcol 读这个键。

**② 不要写行尾注释**
`install_status.py` 内置的极简 YAML 解析器不剥行尾注释。`mq:   # Kafka` 会被解析成字符串 `"# Kafka"`，随后 `openbkn status` 抛 `'str' object has no attribute 'get'`。注释请单独成行。

### 2.1 关键字段

| 键 | 值 | 为什么 |
| --- | --- | --- |
| `bknSafe.authzProvider` | `bkn-safe` | chart 默认空字符串，语义是「回退到已下线的 ISF」。留空则 vega / bkn-backend 会去请求 `http://authorization-private:30920/…`，DNS 直接失败 |
| `bknSafe.directoryProvider` | `bkn-safe` | 目录查询同样切到 bkn-safe |
| `bknSafe.initialPassword` | `<初始管理员密码>` | 不写则 bkn-safe 随机生成并**只在启动日志打印一次**；onboard 也从这里读默认密码 |
| `ingress.ingressClass` | `nginx-hw-public` | bkn-safe 与 bkn-studio 读这个键，chart 默认 `class-443` |
| `ingress.className` | `nginx-hw-public` | agent-observability 读的是 `className`，键名不同，必须另写一份 |
| `depServices.class-443.ingressClass` | `nginx-hw-public` | 其余 8 个 chart 走这个路径取 ingress class |
| `depServices.mq.auth.mechanism` | `PLAIN` | 客户端只接受 `PLAIN` / `SCRAM-SHA-256` / `SCRAM-SHA-512`，**空值直接报 `unsupported mechanism[]`**。外置 Kafka 必须启用 SASL |
| `depServices.redis.connectInfo.username` | `default` | chart 默认 `root`。若 Redis 只有 `default` 用户，两参数 `AUTH root <pw>` 返回 `WRONGPASS`。**必须显式覆盖** |
| `minio.enabled` | `false` | 用外置 MinIO。关闭后 sandbox 内置 minio 及其 PV/PVC 都不生成 |
| `secret.create` | `false` | 配合上一条，`sandbox-secrets` 改由手工预建 |
| `opensearch.endpoint`<br>`opensearchExporter.http.endpoint` | `http://10.67.51.9:9200` | 配置生成器**只在 protocol 为 https 时**才写这两个顶层键。用 http 时不写，agent-observability 会去连集群内 DNS |

### 2.2 完整文件

```yaml
namespace: openbkn
replicaCount: 1
env:
  language: en_US.UTF-8
  timezone: Asia/Shanghai
image:
  registry: swr.cn-east-3.myhuaweicloud.com/openbkn-ai

bknSafe:
  authzProvider: bkn-safe
  directoryProvider: bkn-safe
  url: http://bkn-safe:3000
  initialPassword: '<初始管理员密码>'

accessAddress:
  host: openbkn.changhong.com
  port: 443
  scheme: https
  path: /

# 复用既有 ingress：三个 chart 用的键名不同，两个都写
ingress:
  ingressClass: nginx-hw-public
  className: nginx-hw-public

# 外置 MinIO：关掉内置 minio，两个 Secret 改为手工预建
minio:
  enabled: false
secret:
  create: false

# trace 相关：配置生成器不会写，手工补
opensearch:
  endpoint: http://10.67.51.9:9200
opensearchExporter:
  http:
    endpoint: http://10.67.51.9:9200

depServices:
  mq:
    mqType: kafka
    mqHost: 10.67.51.8
    mqPort: 9092
    protocol: sasl_plaintext
    tenant: default
    auth:
      mechanism: PLAIN
      username: kafkauser
      password: '<KAFKA_PASSWORD>'

  opensearch:
    distribution: opensearch
    host: 10.67.51.9
    port: 9200
    protocol: http
    user: ''
    password: ''
    version: ""

  rds:
    type: MariaDB
    host: 10.67.51.9
    hostRead: 10.67.51.9
    port: 3306
    portRead: 3306
    user: openbkn
    password: '<MARIADB_PASSWORD>'
    database: openbkn
    source_type: external

  redis:
    connectType: standalone
    sourceType: external
    connectInfo:
      username: default
      password: '<REDIS_PASSWORD>'
      host: 10.67.51.9
      port: 6379

  class-443:
    ingressClass: nginx-hw-public
```

---

## 03 安装

两个 `OPENBKN_SKIP_*` 必须**同时**给。只给第一个时，脚本仍会补装整个数据服务捆绑包（MariaDB / Redis / Kafka / OpenSearch），把外置方案覆盖掉。

```bash
cd /opt/bkn-foundry/deploy

OPENBKN_SKIP_PLATFORM_BOOTSTRAP=true \
OPENBKN_SKIP_DATA_SERVICES_BUNDLE=true \
  bash ./deploy.sh openbkn install \
  --config=/opt/bkn-foundry/my-config.yaml \
  --charts_dir=/opt/bkn-charts \
  --access_address=https://openbkn.changhong.com
```

- 命令行 `--access_address` 会覆盖配置里的 `accessAddress`。两个都写，保证配置文件对 onboard 也自洽。
- 重跑加 `--force-upgrade`，位置在 `openbkn` **之前**：`deploy.sh [flags] <module> <action>`。
- **不要运行 `deploy.sh k8s reset`**——那是给全新节点用的，会清掉集群状态，这台集群上有别的业务。

---

## 04 装后补丁

四处 chart 无法覆盖到，必须手工补。前三处同源：chart 默认值假设了一个全内置的集群；§4.4 是复用既有 ingress 时必做的 TLS 收尾——平台本身不管理任何证书。

### 4.1 s3fs 凭据 Secret

sandbox 的会话 Pod 会挂载 `s3fs-passwd`，但该 Secret 在 chart 里被 `{{- if .Values.minio.enabled }}` 整个包住。关了内置 minio 它就永不生成——而会话 Pod 照样要挂。内容格式 `AK:SK`。

```bash
kubectl -n openbkn create secret generic s3fs-passwd \
  --from-literal=s3fs-passwd='<MINIO_AK>:<MINIO_SK>'
```

### 4.2 sandbox 的 S3 端点

chart 把端点**硬编码**成 `http://minio.<ns>.svc.cluster.local:9000`，不能通过 values 改。用外置 MinIO 只能手工重建这个 Secret。

```bash
kubectl -n openbkn delete secret sandbox-secrets --ignore-not-found
kubectl -n openbkn create secret generic sandbox-secrets \
  --from-literal=S3_ENDPOINT_URL='http://10.67.51.9:9000' \
  --from-literal=S3_ACCESS_KEY_ID='<MINIO_AK>' \
  --from-literal=S3_SECRET_ACCESS_KEY='<MINIO_SK>' \
  --from-literal=S3_BUCKET='open-bkn' \
  --from-literal=S3_REGION='us-east-1'

kubectl -n openbkn rollout restart deploy/sandbox-control-plane
```

> **端口必须是 9000。** MinIO 的 `/minio/health/live` 在 9000 和 9001 上**都**返回 200，不能用它区分。发一个不带凭据的 S3 请求即可判定：返回 `AccessDenied` XML 的是 API，返回 HTML 的是控制台。9001 是 Web 控制台。
>
> ```bash
> for p in 9000 9001; do echo "== $p =="; curl -s --max-time 5 "http://10.67.51.9:$p/open-bkn/?list-type=2" | head -c 200; echo; done
> ```

### 4.3 IngressClass 补齐

若配置里已按 §2.1 写好 `ingress.*`，这一步不需要。若安装时漏了，三个 Ingress 会停在默认的 `class-443`——集群里没有这个 class，等于没有控制器接管，路由全部 404。**症状是 `/api/safe/v1/auth/change-password` 返回 404，CLI 报「platform has no bkn-safe auth stack」。**

```bash
kubectl -n openbkn get ingress -o custom-columns='NAME:.metadata.name,CLASS:.spec.ingressClassName'

for i in $(kubectl -n openbkn get ingress -o jsonpath='{range .items[?(@.spec.ingressClassName=="class-443")]}{.metadata.name}{"\n"}{end}'); do
  kubectl -n openbkn patch ingress "$i" --type=merge -p '{"spec":{"ingressClassName":"nginx-hw-public"}}'
done
```

> `kubectl patch` 不是声明式的：下次 `--force-upgrade` 会被 helm 改回去。务必同时把 `ingress.ingressClass` / `className` 写进配置文件。

### 4.4 TLS 证书（复用既有 ingress 时必做）

**平台不管理任何证书。** 0.1.4 的 11 个 chart 生成的 Ingress 全部没有 `host`、没有 `tls` 段（11 个 chart 里只有 agent-observability 有 `ingress.host` / `ingress.tls` 两个键，默认还是空），配置文件里也没有证书字段——`accessAddress` 只影响回调地址和 hydra issuer 这些字符串，不会让任何 Ingress 去引用证书。

**不挂会怎样**：集群里没有任何 Ingress 认领 `openbkn.changhong.com`，请求落进 ingress-nginx 的 catch-all（default server），HTTPS 由控制器自签的 `Kubernetes Ingress Controller Fake Certificate` 应答。而 `bkn-studio-ingress` 带 `force-ssl-redirect: "true"`，http 访问 `/studio` 会 308 跳到 https——**浏览器卡在证书警告、`curl https://…` 直接失败（`000`）、CLI 不加 `-k` 用不了**。

**集群惯例**（照抄即可）：`design` / `eadp` 里的业务都是「自己的 Ingress 里写 `host: <业务>.changhong.com` + `tls: changhong.com`」，证书 Secret 在每个命名空间各存一份同名副本——`spec.tls.secretName` **不能跨命名空间引用**。

#### ① 证书 Secret 复制进 `openbkn`

```bash
# openbkn 里若已有同名 Secret（或运维有同步机制）则跳过
kubectl -n openbkn get secret changhong.com || {
  kubectl -n rdm get secret changhong.com -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/c.crt
  kubectl -n rdm get secret changhong.com -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/c.key
  kubectl -n openbkn create secret tls changhong.com --cert=/tmp/c.crt --key=/tmp/c.key
  shred -u /tmp/c.key 2>/dev/null || rm -f /tmp/c.key; rm -f /tmp/c.crt
}
```

> 先确认 SAN 覆盖目标域名（`*.changhong.com` 可覆盖 `openbkn.changhong.com`）。CentOS 7 自带的 openssl 1.0.2 没有 `-ext`，用 `-text` 过滤：
>
> ```bash
> kubectl -n rdm get secret changhong.com -o jsonpath='{.data.tls\.crt}' | base64 -d \
>   | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"
> ```
>
> 轮换：与 `design` / `eadp` 用的是同一张证书，记得同步 `openbkn`；或让运维把 `openbkn` 加进分发名单。

#### ② 两份 Ingress

同 host 的多份 Ingress 会被控制器合并成一个 server block（集群里 `aidc.changhong.com` 下就挂着 11 份）。**注解必须照下面写**：平台 11 个 Ingress 里只有 `bkn-studio-ingress` 开跳转（`ssl-redirect` / `force-ssl-redirect: "true"`），其余 9 个显式 `ssl-redirect: "false"`，agent-observability 没有任何 nginx 注解。照此对齐后 http 行为与安装完成时逐条一致——**唯一的差别就是证书**。

> 拆成两份（而不是一份全收）是因为 `ssl-redirect` / `force-ssl-redirect` 在 ingress-nginx v1.4.0 里是**按 location 生效**的：注解被解析进每个 location 的 `rewrite` 配置，由模板里的 `rewrite_by_lua_block { lua_ingress.rewrite(...) }` 执行，location 只认自己所归属 Ingress 的注解值（已对 v1.4.0 源码与控制器实际行为双重确认）。所以「`/studio`、`/` 跳 https，25 条 API 路径不跳」才能在同一个 host server block 里共存。同理，`proxy-body-size` 这类 location 级注解也只能按份给——API 那份取平台里的最大值 `2048m`，**只放宽、不收紧**。

`hw-public-openbkn.changhong.com-443-studio.yaml`（与 bkn-studio 注解一致，http → https 跳转）：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hw-public-openbkn.changhong.com-443-studio
  namespace: openbkn
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx-hw-public
  tls:
    - hosts:
        - openbkn.changhong.com
      secretName: changhong.com
  rules:
    - host: openbkn.changhong.com
      http:
        paths:
          - path: /studio
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-studio, port: { number: 80 } } }
          - path: /
            pathType: Exact
            backend: { service: { name: bkn-studio, port: { number: 80 } } }
```

`hw-public-openbkn.changhong.com-443.yaml`（API 主入口，与其余 10 个注解一致，不跳转；body-size 取平台最大值 2048m，只放宽不收紧）：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hw-public-openbkn.changhong.com-443
  namespace: openbkn
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/proxy-body-size: "2048m"
spec:
  ingressClassName: nginx-hw-public
  tls:
    - hosts:
        - openbkn.changhong.com
      secretName: changhong.com
  rules:
    - host: openbkn.changhong.com
      http:
        paths:
          # bkn-safe（登录 / 网关）
          - path: /login
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-safe, port: { number: 3000 } } }
          - path: /consent
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-safe, port: { number: 3000 } } }
          - path: /device
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-safe, port: { number: 3000 } } }
          - path: /device/success
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-safe, port: { number: 3000 } } }
          - path: /change-password
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-safe, port: { number: 3000 } } }
          - path: /api/safe/v1/auth/change-password
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-safe, port: { number: 3000 } } }
          - path: /api/safe/v1/admin
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-safe, port: { number: 3000 } } }
          - path: /api/safe/v1/me
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-safe, port: { number: 3000 } } }
          - path: /api/safe/v1/capabilities
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-safe, port: { number: 3000 } } }
          # hydra 公共 OAuth2 / OIDC 端点
          - path: /oauth2
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-safe-hydra-public, port: { number: 4444 } } }
          - path: /.well-known/openid-configuration
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-safe-hydra-public, port: { number: 4444 } } }
          - path: /.well-known/jwks.json
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-safe-hydra-public, port: { number: 4444 } } }
          - path: /userinfo
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-safe-hydra-public, port: { number: 4444 } } }
          # 后端 API
          - path: /api/bkn-backend/v1
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-backend-svc, port: { number: 13014 } } }
          - path: /api/ontology-manager/v1
            pathType: ImplementationSpecific
            backend: { service: { name: bkn-backend-svc, port: { number: 13014 } } }
          - path: /api/ontology-query/v1
            pathType: ImplementationSpecific
            backend: { service: { name: ontology-query-svc, port: { number: 13018 } } }
          - path: /api/vega-backend/v1
            pathType: ImplementationSpecific
            backend: { service: { name: vega-backend-svc, port: { number: 13014 } } }
          - path: /api/agent-observability/v1
            pathType: ImplementationSpecific
            backend: { service: { name: agent-observability, port: { number: 8080 } } }
          - path: /api/observability/v1
            pathType: ImplementationSpecific
            backend: { service: { name: agent-observability, port: { number: 8080 } } }
          - path: /api/agent-operator-integration/v1
            pathType: Prefix
            backend: { service: { name: agent-operator-integration, port: { number: 9000 } } }
          - path: /api/capabilities-lab/v1
            pathType: Prefix
            backend: { service: { name: agent-operator-integration, port: { number: 9000 } } }
          - path: /api/agent-retrieval/v1
            pathType: Prefix
            backend: { service: { name: agent-retrieval, port: { number: 30779 } } }
          - path: /api/mf-model-api
            pathType: ImplementationSpecific
            backend: { service: { name: mf-model-api, port: { number: 9898 } } }
          - path: /api/mf-model-manager
            pathType: ImplementationSpecific
            backend: { service: { name: mf-model-manager, port: { number: 9898 } } }
          - path: /api/oss-gateway
            pathType: ImplementationSpecific
            backend: { service: { name: oss-gateway-backend, port: { number: 8080 } } }
```

#### ③ 验证

```bash
# 证书：不应再是 Fake Certificate
openssl s_client -connect openbkn.changhong.com:443 -servername openbkn.changhong.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

# 路径矩阵：修复前 https 两行都是 000（证书校验失败）
for u in http://openbkn.changhong.com/studio https://openbkn.changhong.com/studio \
         http://openbkn.changhong.com/api/safe/v1/capabilities https://openbkn.changhong.com/api/safe/v1/capabilities; do
  printf '%s\t' "$u"; curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' "$u"
done
```

| URL | 未挂证书 | 挂载后 |
| --- | --- | --- |
| `http://…/studio` | 308 | 308（不变） |
| `https://…/studio` | `000`（证书校验失败） | 200 / 301 / 302 |
| `http://…/api/safe/v1/capabilities` | 401 | 401（不变） |
| `https://…/api/safe/v1/capabilities` | `000`（证书校验失败） | 401 |

> **2026-10-08 已实施并实测**（本部署）：证书为 `C=CN, ST=四川, L=成都, O=四川长虹虹微科技有限公司, CN=*.changhong.com`，GlobalSign RSA OV SSL CA 2018 签发，**2026-12-12 到期**（轮换时记得同步 `openbkn` 这份副本）；路径矩阵四条全部命中上表（`308` / `301 → /studio/` / `401` / `401`）。两份 Ingress 的落盘副本在 master1 `/root/openbkn-entry-tls.yaml`，回退即 `kubectl delete -f /root/openbkn-entry-tls.yaml`（只新增、未改动任何既有对象，删除即完全恢复；两份必须一起删，只删一份会让另一份的路径整片 404）。

最后浏览器走一遍完整链路：工作台 → 登录（`/login` → hydra 回调）→ 改密码页。

**三条维护约束**

1. 这两份 Ingress **不是 helm 管的**，`--force-upgrade` 不会碰它们（反过来 helm 也不会帮你维护）。
2. **该域名下的路径必须抄全**：host 一旦被声明，catch-all 就不再兜底这个域名，漏掉的路径直接 404。平台升级后跑一次 diff：
   ```bash
   kubectl -n openbkn get ingress -o jsonpath='{range .items[*]}{range .spec.rules[*].http.paths[*]}{.path}{" -> "}{.backend.service.name}{":"}{.backend.service.port.number}{"\n"}{end}{end}' | sort -u > /tmp/live.txt
   kubectl -n openbkn get ingress hw-public-openbkn.changhong.com-443 -o jsonpath='{range .spec.rules[*].http.paths[*]}{.path}{" -> "}{.backend.service.name}{":"}{.backend.service.port.number}{"\n"}{end}' | sort -u > /tmp/mine.txt
   diff /tmp/live.txt /tmp/mine.txt   # 只出现在 live 里的 = 还没同步的新路径
   ```
3. 证书轮换见 §① 的提示。

> **为什么不改控制器**：给 `nginx-hw-public` 的 DaemonSet 加 `--default-ssl-certificate=rdm/changhong.com` 也能让 catch-all 用上真证书（零改平台资源、升级无感），但该 DaemonSet 由 matrix 平台管理、是全集群公共入口（`nodeSelector: matrix.ingress=hw-public`），影响面覆盖所有「未声明 host」的 HTTPS 请求。除非 matrix 侧有官方入口，否则用上面的命名空间内做法。

---

## 05 验证

```bash
# 全部 Pod 应 Running 且 RESTARTS 为 0
kubectl -n openbkn get pods | grep -v Running

# 逐 release 的版本 / 健康 / drift
cd /opt/bkn-foundry/deploy
bash ./deploy.sh --config=/opt/bkn-foundry/my-config.yaml openbkn status

# 认证接口应返回 400（缺参数字段），而不是 404
curl -sk -o /dev/null -w '%{http_code}\n' -X POST \
  https://openbkn.changhong.com/api/safe/v1/auth/change-password \
  -H 'Content-Type: application/json' -d '{}'
```

**全绿判定**：18 个 Pod Running、0 重启，`core-data-migrator-job` 为 Completed，认证接口 400，11 个 Ingress 的 CLASS 全部是 `nginx-hw-public`；§4.4 已完成，HTTPS 拿到的是覆盖 `*.changhong.com` 的业务证书（GlobalSign 签发，2026-12-12 到期），不再是 `Fake Certificate`。

---

## 06 Onboard

onboard 做四件事：准备 `openbkn` CLI、注册模型、建业务测试用户、出完成报告。它**不往集群里装任何东西**——Node 是装在跑脚本这台机器上的客户端工具。

### 6.1 CentOS 7 上装 Node 22

CentOS 7 的 glibc 是 2.17，而 Node 18+ 的官方二进制要求 ≥ 2.28。`onboard.sh` 默认走 nvm 从 GitHub 拉安装脚本，在这里会因网络和 glibc 双重原因失败。

改用 Node.js 官方为老 glibc 出的 `glibc-217` 变体，装到 `/usr/local` 即可——`onboard.sh` 检测到该路径下有可执行的 `node` 会自动加进 PATH，完全绕开 nvm。

```bash
BASE=https://unofficial-builds.nodejs.org/download/release
VER=$(curl -s --max-time 20 "$BASE/" | grep -oE 'v22\.[0-9]+\.[0-9]+/' | sort -V | tail -1 | tr -d '/')

curl -fsSL -o /tmp/node.tar.gz "$BASE/$VER/node-$VER-linux-x64-glibc-217.tar.gz"
curl -fsSL "$BASE/$VER/SHASUMS256.txt" | grep "linux-x64-glibc-217"   # 比对 sha256sum 后再解压
tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1

node -v && npm -v
npm config set registry https://registry.npmmirror.com
```

### 6.2 锁定 CLI 版本

> ⚠️ npm 上 `@openbkn/bkn-sdk` 的 `latest` 是 **0.1.5**，而平台是 **0.1.4**。两者的健康检查路由不同——0.1.5 把 `/health` 挪进了 `/api/bkn-backend/v1` 组，0.1.4 还在根路径。用新 CLI 连旧平台，前置版本探测会 404 并且**请求根本不发出**，报 `Cannot verify platform version`。

```bash
npm i -g @openbkn/bkn-sdk@0.1.4
openbkn --version      # 应输出 0.1.4
```

`onboard.sh` 每次运行都会执行一次不锁版本的 `npm i -g @openbkn/bkn-sdk`，会把 CLI 升回 0.1.5。必须用 `ONBOARD_SKIP_OPENBKN_INSTALL=true` 挡住。

### 6.3 运行

> **平台配置走 `CONFIG_YAML_PATH`，不是 `--config`。** onboard 的 `--config` 指的是**模型清单**（`deploy/conf/models.yaml.example`），和 `deploy.sh` 的同名参数不是一个东西。传错了它只会静默地把交互提示关掉，`accessAddress` / `initialPassword` / `namespace` 全都读不到，然后退化成「本机主 IPv4」。

```bash
cd /opt/bkn-foundry/deploy

# 先建业务测试用户 + 登录（无模型清单，交互式）
ONBOARD_SKIP_OPENBKN_INSTALL=true \
CONFIG_YAML_PATH=/opt/bkn-foundry/my-config.yaml \
  bash ./onboard.sh

# 备好模型清单后，再跑一次注册 LLM / embedding（幂等）
cp conf/models.yaml.example /opt/bkn-foundry/models.yaml
vi /opt/bkn-foundry/models.yaml

ONBOARD_SKIP_OPENBKN_INSTALL=true \
CONFIG_YAML_PATH=/opt/bkn-foundry/my-config.yaml \
  bash ./onboard.sh --config=/opt/bkn-foundry/models.yaml
```

**进度标志**：`Logged in … as admin` → `User [test] … business roles assigned` → 模型注册 → 完成报告。

模型没注册时 `openbkn bkn list` 返回 `(no results)` 是正常的——新建平台还没有知识网络。

> 等平台升级到 0.1.5 后，撤掉 `ONBOARD_SKIP_OPENBKN_INSTALL` 并让 CLI 回到 latest。

---

## 故障速查

本次部署实际遇到的全部故障，按「症状 → 根因 → 修法」记录。

### 授权 / 认证

**`lookup authorization-private on 169.254.25.10:53: no such host`** — vega-backend
- **根因**：chart 的 `bknSafe.authzProvider` 默认空字符串，语义为「回退 ISF」。配置里没写这一行，授权还在找已下线的 `authorization-private:30920`。
- **修法**：配置补 `bknSafe.authzProvider: bkn-safe`。同一开关也作用于 bkn-backend、mf-model-manager、mf-model-api。

**`POST /api/safe/v1/auth/change-password → 404`** — ingress
- **根因**：bkn-safe、bkn-studio 读 `ingress.ingressClass`，agent-observability 读 `ingress.className`，默认都是 `class-443`。复用既有 ingress 时集群里没有这个 class。其余 8 个 chart 走 `depServices.class-443.ingressClass`，所以只有这三张坏。
- **修法**：配置顶层补 `ingress.ingressClass` 与 `ingress.className`；已装好的用 `kubectl patch` 立即修。

**`Cannot verify platform version: GET /api/bkn-backend/v1/health returned HTTP 404`** — openbkn CLI
- **根因**：CLI 与平台版本错配。npm `latest` 是 0.1.5，它探的路由在 0.1.4 上不存在（0.1.4 的 `/health` 注册在根路径，而根路径不在 ingress 暴露范围内）。探测失败后 CLI 直接不发登录请求。
- **修法**：`npm i -g @openbkn/bkn-sdk@0.1.4`，并用 `ONBOARD_SKIP_OPENBKN_INSTALL=true` 阻止被升回去。

**`openbkn auth login` 打到 `https://<节点IP>` 而不是域名** — onboard
- **根因**：把平台配置当成 `--config` 传了。onboard 的 `--config` 是模型清单，只用来关闭交互提示；平台配置必须走 `CONFIG_YAML_PATH`。
- **修法**：`CONFIG_YAML_PATH=/opt/bkn-foundry/my-config.yaml bash ./onboard.sh`。

**`1045 Access denied for user 'openbkn'@'<节点IP>'`** — 数据迁移
- **根因**：初始化 SQL 里密码写成了占位符字面量，用户实际不存在或密码不符。
- **修法**：重写初始化 SQL 并重建数据卷。用户需授权 `@'%'`，因为 Pod 源 IP 是节点 IP。

### 入口 / TLS

**`openssl s_client` 返回 `CN=Kubernetes Ingress Controller Fake Certificate`** — 入口 · TLS
- **症状**：`openssl s_client -connect openbkn.changhong.com:443 -servername openbkn.changhong.com` 拿到自签的 fake 证书；`curl https://…` 一律 `000`（证书校验失败，不是网络问题）、CLI 必须带 `-k`；而 `http://…/studio` 又是 308 跳 https——**网页控制台在正常浏览器里根本进不去**。
- **根因**：平台 0.1.4 的 11 个 Ingress 全部无 `host`、无 `tls`（配置里也没有证书字段），集群里没有任何 Ingress 认领该域名 → 请求落进 ingress-nginx 的 catch-all（default server），HTTPS 由控制器自签证书应答。**平台不管理证书，这是设计如此，不是漏了步骤。**
- **修法**：按集群惯例（`design` / `eadp` 的业务都是）在 `openbkn` 补两份带 `host` + `tls` 的 Ingress，并把证书 Secret 复制一份进来。步骤与完整 YAML 见 §4.4。**本部署 2026-10-08 已按此修复并验证**（回退：`kubectl delete -f /root/openbkn-entry-tls.yaml`）。

### 外置中间件

**`WRONGPASS invalid username-password pair or user is disabled`** — oss-gateway-backend · agent-operator-integration
- **根因**：chart 的 `redis.connectInfo.username` 默认值是 `root`，而 Redis 里只存在 `default` 用户。客户端发出两参数 `AUTH root <pw>`。**密码本身是对的**——用 `redis-cli -a` 单参数认证能 PONG。
- **修法**：显式写 `connectInfo.username: default`。用 `redis-cli ACL LIST` 确认实际存在哪些用户。

**`unsupported mechanism[] for kafka client`** — vega-backend
- **根因**：客户端库只接受 `PLAIN` / `SCRAM-SHA-256` / `SCRAM-SHA-512`，空值直接判为不支持。
- **修法**：Kafka 侧启用 SASL PLAIN 并建用户，配置写 `mechanism: PLAIN` + 用户名密码。**不能留空。**

**`lookup opensearch-cluster-master.resource.svc.cluster.local: no such host`** — agent-observability
- **根因**：配置生成器**只在协议为 https 时**才写顶层 `opensearch.endpoint`；这里 OpenSearch 是 http，于是 chart 默认值（集群内 DNS）生效。
- **修法**：顶层手工补 `opensearch.endpoint` 与 `opensearchExporter.http.endpoint`。

**`MountVolume.SetUp failed: secret "s3fs-passwd" not found`** — sandbox 会话 Pod
- **根因**：该 Secret 被 `{{- if .Values.minio.enabled }}` 整个包住。用外置 MinIO 关了内置 minio，它就永不生成——但会话 Pod 照样挂载它。
- **修法**：手工建，key 必须叫 `s3fs-passwd`，值为 `AK:SK`。

**`manifest unknown: Not Found tag …0.1.4-hotfix-supply-sample-p1`** — 镜像拉取
- **根因**：manifest 钉的三个 hotfix tag 只在 GHCR 发布，SWR 上没有。
- **修法**：从 GHCR 取 `agent-operator-integration` / `sandbox` / `agent-retrieval` 的该 tag。不要退回 `0.1.4`。

**`nvm install.sh failed — curl: (35) I/O operation timed out`** — onboard
- **根因**：从 raw.githubusercontent.com 拉 nvm 安装脚本；且 CentOS 7 的 glibc 2.17 也不满足 Node 18+ 官方二进制。
- **修法**：改用 `unofficial-builds.nodejs.org` 的 `glibc-217` 变体装到 `/usr/local`，绕开 nvm。

### 配置 / 平台

**`install_status.py: 'str' object has no attribute 'get'`** — `openbkn status`
- **根因**：该脚本内置的极简 YAML 解析器只跳过**行首**注释，不剥行尾注释。`mq:   # Kafka` 被解析成字符串 `"# Kafka"`。
- **修法**：把配置文件里的行尾注释移到独立行。不影响 Helm——真 YAML 解析器本来就正确处理。

**`Only mode=deployment is supported in this initial release`** — otelcol-contrib
- **根因**：平台配置顶层的 `mode: Community` 覆盖了 otelcol chart 自己的 `mode: deployment`。全平台只有 otelcol 读这个键。
- **修法**：删掉配置顶层的 `mode:`。

**PVC 永远 Pending，Pod 卡在 ContainerCreating** — bkn-safe postgres
- **根因**：集群没有默认 StorageClass，而 chart 的 PVC 不写 `storageClassName`。
- **修法**：建一个 `storageClassName: ""` 的静态 PV。用 `local` 卷时必须配 `nodeAffinity` 钉住节点。

**`Error: template: bkn-safe/templates/…: index of untyped nil`** — Helm
- **根因**：Helm 3.9 及更早不支持 Go 模板惰性求值（Go 1.18 才引入）。平台脚本自身要求 Helm ≥ 3.10。
- **修法**：升级 Helm。针对 K8s 1.23–1.27 选 3.12.3。

**`namespaces "resource" not found`** — kafka install
- **根因**：`kafka.sh` 是四个数据服务脚本里唯一不创建命名空间的那个。
- **修法**：`kubectl create namespace resource`。本方案外置 Kafka，实际用不到。

**`pthread_create failed (EPERM)` · JVM 无法启动** — 集群内 Kafka
- **根因**：Docker 20.10.8 的默认 seccomp profile 缺 `clone3`（20.10.10 才修）。Kafka chart 设了 `seccompProfile: RuntimeDefault`，现代 glibc 的 JVM 因此起不来。
- **修法**：改用外置 Kafka。其余 6 个 chart 都不设 seccompProfile，不受影响。

---

## 附：本文涉及的关键源码位置

排查过程依赖的、值得记住的代码点：

| 位置 | 说明 |
| --- | --- |
| `deploy/scripts/lib/common.sh:1407` | `INGRESS_NGINX_CLASS` 默认 `class-443`——标准安装自建控制器时才存在 |
| `deploy/scripts/services/config.sh:510` | 配置生成器会写 `authzProvider: bkn-safe`；手写配置时容易漏 |
| `deploy/scripts/services/openbkn.sh:1455` | 需要两个 `OPENBKN_SKIP_*` 的原因 |
| `deploy/onboard.sh:273` | `--config=` 只设 `INTERACTIVE=false`，不设 `CONFIG_YAML_PATH` |
| `deploy/onboard.sh:469` | 每次运行都 `npm i -g @openbkn/bkn-sdk`（不锁版本） |
| `bkn-safe/server/internal/seed/seed.go:218` | 初始管理员密码只在 `BKN_SAFE_INITIAL_PASSWORD` 为空时打印一次 |
| `adp/bkn/bkn-backend/.../routers.go:95` (0.1.4) | `/health` 在根路径；0.1.5 才挪进 `/api/bkn-backend/v1` |
| 各 chart 的 `templates/ingress.yaml` (0.1.4)（`bkn-safe` 内联在 `templates/service.yaml`） | 规则只有 `- http:`，**无 `host`、无 `tls`** → 平台不管理证书，TLS 必须由使用方在既有 ingress 上挂（§4.4） |
| `bkn-trace/agent-observability/.../templates/ingress.yaml` | 11 个 chart 里**唯一**支持 `ingress.host` / `ingress.tls` 的（默认均为空） |

> 版本差异提醒：仓库 `main` 分支比 `v0.1.4` tag 领先 300+ commit，且做过 monorepo 目录重构（vega 从 `adp/vega/` 移到 `vega/`）。排查时务必用 `git show v0.1.4:<path>` 看**部署版本**的源码，直接读工作区会得到错误结论。

---

*平台 0.1.4 · 集群 v1.23.14（低于支持下限 1.24）· 15 个 Helm release · 记录于 2026-09-24*
*文中所有凭据均以占位符表示，真实值在 `/opt/bkn-foundry/my-config.yaml`（`chmod 600`）*