#!/usr/bin/env bash
# BKN Foundry 0.1.4 -> 0.1.5 升级 · P0 只读勘察
#
# 全部是读操作：ls / cat / kubectl get / SELECT。不写任何东西，不改任何配置。
# 不会打印任何口令（数据库口令用不回显的 read 输入，只存活在环境变量里）。
#
# 用法（在 master1 上）：
#   scp upgrade-0.1.5-p0-survey.sh master1:/root/
#   ssh master1 'bash /root/upgrade-0.1.5-p0-survey.sh 2>&1 | tee /tmp/bkn-p0.txt'
#   # 把 /tmp/bkn-p0.txt 的内容贴回来

set -u

CFG="/opt/bkn-foundry/my-config.yaml"

hr()  { printf '\n========== %s ==========\n' "$1"; }
have(){ if command -v "$1" >/dev/null 2>&1; then echo "  $1 -> $(command -v "$1")"; else echo "  $1 -> MISSING"; fi; }

# ---------------------------------------------------------------- 1 主机
hr "1. 主机"
date
hostname -f 2>/dev/null || hostname
uname -r
echo "cpu cores: $(nproc)"
free -h | head -2
cat /etc/redhat-release 2>/dev/null || (head -2 /etc/os-release 2>/dev/null)
echo "-- 磁盘 --"
df -h | grep -vE 'tmpfs|devtmpfs|overlay'

# ---------------------------------------------------------------- 2 工具链
hr "2. 工具链"
for t in kubectl helm docker crictl ctr git curl python3 python3.8 python3.9 python3.10 python3.11 python3.12 mysql mariadb mariadb-dump mysqldump; do
  have "$t"
done
echo "-- 版本 --"
kubectl version --client 2>/dev/null | head -3
helm version --short 2>/dev/null
docker --version 2>/dev/null
python3 --version 2>/dev/null
echo "-- python3.x 二进制 --"
ls -1 /usr/bin/python3.* 2>/dev/null
echo "-- PyMySQL（迁移脚本必需）--"
python3 -c "import pymysql;print('  pymysql', pymysql.__version__)" 2>&1 | head -2

# ---------------------------------------------------------------- 3 部署根
hr "3. 部署根 /opt/bkn-foundry"
ls -la /opt/bkn-foundry 2>/dev/null
echo "-- VERSION --"
cat /opt/bkn-foundry/VERSION 2>/dev/null
echo "-- git 状态 --"
git -C /opt/bkn-foundry describe --tags --always --dirty 2>&1 | head -2
git -C /opt/bkn-foundry log -1 --format='%H %ad %s' 2>&1 | head -2
git -C /opt/bkn-foundry remote -v 2>&1 | head -4
echo "-- 未提交改动 --"
git -C /opt/bkn-foundry status --porcelain 2>&1 | head -20
echo "-- release-manifests（找 0.1.5）--"
ls -1 /opt/bkn-foundry/deploy/release-manifests/ 2>/dev/null
echo "-- upgrades 目录（关键：0.1.5 迁移包在不在）--"
ls -1 /opt/bkn-foundry/deploy/scripts/upgrades/ 2>/dev/null
ls -1 /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5/ 2>/dev/null
echo "-- charts 缓存 --"
ls -1 /opt/bkn-charts 2>/dev/null | head -30
ls -1 /opt/bkn-foundry/deploy/.tmp/charts 2>/dev/null | head -30
echo "-- 配置文件 --"
ls -l "$CFG" 2>/dev/null
echo "-- 配置内容（口令已脱敏）--"
if [[ -f "$CFG" ]]; then
  sed -E 's/(^[[:space:]]*[A-Za-z0-9_.-]*([Pp]assword|[Ss]ecret|[Tt]oken)[A-Za-z0-9_.-]*[[:space:]]*:).*/\1 <REDACTED>/' "$CFG"
else
  echo "(未找到 $CFG)"
fi

# ---------------------------------------------------------------- 4 集群
hr "4. K8s 集群"
echo "-- context --"; kubectl config current-context 2>&1
echo "-- 版本 --";     kubectl version 2>&1 | head -6
echo "-- nodes --";    kubectl get nodes -o wide 2>&1
echo "-- openbkn 工作负载 --"; kubectl -n openbkn get deploy,sts,ds 2>&1
echo "-- pods --";     kubectl -n openbkn get pods -o wide 2>&1
echo "-- cronjob --";  kubectl -n openbkn get cronjob 2>&1
echo "-- pvc --";      kubectl -n openbkn get pvc 2>&1
echo "-- ingress --";  kubectl -n openbkn get ingress 2>&1
echo "-- ingressclass --"; kubectl get ingressclass 2>&1
echo "-- helm release --"; helm list -n openbkn 2>&1
echo "-- 全部 helm --";    helm list -A 2>&1 | head -30

# ---------------------------------------------------------------- 5 路径基线
hr "5. Ingress 路径基线（升级后 diff 用）"
kubectl -n openbkn get ingress \
  -o jsonpath='{range .items[*]}{range .spec.rules[*].http.paths[*]}{.path}{" -> "}{.backend.service.name}{":"}{.backend.service.port.number}{"\n"}{end}{end}' \
  2>/dev/null | sort -u > /tmp/bkn-paths-live.txt
echo "共 $(wc -l < /tmp/bkn-paths-live.txt) 条路径："
cat /tmp/bkn-paths-live.txt

# ---------------------------------------------------------------- 6 连通性
hr "6. 出口连通性"
for u in https://ghcr.io/v2/ https://swr.cn-east-3.myhuaweicloud.com/v2/ https://registry.npmmirror.com/; do
  printf '  %-52s ' "$u"
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 "$u" 2>/dev/null || echo TIMEOUT
done

RDS_HOST="$(awk '/^  rds:/{f=1;next} f&&/^  [A-Za-z]/{f=0} f&&/^[[:space:]]*host:/{print $2;exit}' "$CFG" 2>/dev/null | tr -d "'\"")"
RDS_HOST="${RDS_HOST:-10.67.51.9}"
echo "-- 中间件 TCP（rds host 取自配置：$RDS_HOST）--"
for hp in "$RDS_HOST:3306" "$RDS_HOST:9200" "$RDS_HOST:9000" "10.67.51.8:9092"; do
  printf '  %-22s ' "$hp"
  timeout 5 bash -c "</dev/tcp/${hp%:*}/${hp#*:}" 2>/dev/null && echo OK || echo FAIL
done

# ---------------------------------------------------------------- 7 数据库
hr "7. 数据库现状（只读）"
if ! command -v mysql >/dev/null 2>&1 && ! command -v mariadb >/dev/null 2>&1; then
  echo "本机没有 mysql/mariadb 客户端，跳过。"
else
  MYSQL_BIN="$(command -v mysql || command -v mariadb)"
  read -rsp "MariaDB 口令（用户 openbkn，不回显，直接回车跳过）: " DB_PW
  echo
  if [[ -z "${DB_PW:-}" ]]; then
    echo "已跳过数据库检查。"
  else
    export MYSQL_PWD="$DB_PW"
    q() { "$MYSQL_BIN" -h "$RDS_HOST" -P 3306 -u openbkn --batch --raw -e "$1" 2>&1 | head -40; }

    echo "-- 库与表数量 --"
    q "SELECT table_schema, COUNT(*) AS tables_ FROM information_schema.tables WHERE table_schema IN ('openbkn','safe','bkn_trace','deploy') GROUP BY table_schema;"

    echo "-- 库大小（估备份空间，MB）--"
    q "SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,1) AS mb FROM information_schema.tables WHERE table_schema IN ('openbkn','safe') GROUP BY table_schema;"

    echo "-- 迁移标记表是否已存在 --"
    q "SELECT COUNT(*) AS marker_table_exists FROM information_schema.tables WHERE table_schema='safe' AND table_name='authorization_migration_marker';"
    q "SELECT * FROM safe.authorization_migration_marker;"

    echo "-- safe 库授权相关行数 --"
    q "SELECT COUNT(*) AS authorization_grant FROM safe.authorization_grant;"
    q "SELECT ptype, COUNT(*) AS n FROM safe.casbin_rule GROUP BY ptype;"

    echo "-- 内置角色 --"
    q "SELECT * FROM safe.roles;"

    echo "-- 与 normal_user 相关的绑定（0.1.5 会删掉这个角色）--"
    q "SELECT ptype,v0,v1,v2 FROM safe.casbin_rule WHERE v0 LIKE '%normal%' OR v1 LIKE '%normal%' OR v2 LIKE '%normal%' LIMIT 20;"

    echo "-- 目录 t_catalog --"
    q "SELECT COUNT(*) AS catalogs, SUM(f_creator IS NULL OR f_creator='') AS no_creator, SUM(f_creator_type<>'user') AS creator_not_user FROM openbkn.t_catalog;"
    q "SELECT f_internal, COUNT(*) AS n FROM openbkn.t_catalog GROUP BY f_internal;"

    echo "-- 知识网络 t_knowledge_network --"
    q "SELECT COUNT(*) AS kns, SUM(f_creator IS NULL OR f_creator='') AS no_creator FROM openbkn.t_knowledge_network;"

    echo "-- deploy 库管控表（data-migrator 状态）--"
    q "SELECT COUNT(*) AS task FROM deploy.t_schema_migration_task;"
    q "SELECT COUNT(*) AS history FROM deploy.t_schema_migration_history;"

    unset MYSQL_PWD
    echo "(口令已从环境清除)"
  fi
fi

# ---------------------------------------------------------------- 8 备份
hr "8. 备份空间与现有备份"
df -h /opt /var/lib /root /tmp 2>/dev/null
echo "-- 现有备份残留 --"
ls -lh /opt/bkn-foundry/deploy/scripts/upgrades/0.1.5/permission_model_transition/backups/ 2>/dev/null || echo "  (无 backups 目录)"

hr "勘察结束"
echo "把上面全部输出贴回来即可。"
