#!/usr/bin/env bash
# =============================================================================
# deploy-vps.sh — 标准部署：REALITY(公网 443) + XHTTP 经 Cloudflare + HY2(UDP 443)
#
# 架构（与现有 107 / 192 / .110 / .11 一致）：
#   TCP 443 普通客户端          → Xray REALITY（监听公网 IP:443，偷同网段邻居）
#   TCP 443 来自 Cloudflare     → nftables 重定向 → Nginx 9443 → <XHTTP 路径> → XHTTP 127.0.0.1:10000
#                                                              → /<面板路径>/ → 3x-ui 面板（只监听本机）
#                                                              → /<订阅路径>/ → 3x-ui 订阅 2096
#   UDP 443                     → Xray HY2（Salamander 混淆）
#   TCP 80                      → Nginx 只应答 ACME 验证
#
# 用法：在全新的 Ubuntu 22.04 / 24.04 上以 root 运行
#   bash deploy-vps.sh                # 交互式逐项询问
#   CDN_DOMAIN=... PANEL_DOMAIN=... bash deploy-vps.sh   # 也可以用环境变量预填
#
# 可预填的环境变量：
#   CDN_DOMAIN PANEL_DOMAIN REALITY_SNI REALITY_SNI_BACKUP CLIENTS PANEL_USER PANEL_PASS
#   ACME_EMAIL SSH_PUBKEY CF_API_TOKEN PANEL_PATH SUB_PATH XHTTP_PATH TRUST_HEADER XUI_VERSION(默认 v3.11.0)
#   面板/订阅/XHTTP 路径和可信标记头：运行时可选推荐值、随机生成（默认）或自定义
#   REALITY_SNI 留空 = 自动扫描本机 /24 挑邻居；CF_API_TOKEN 留空 = Cloudflare 那几步手动做
#
# 产出：/root/deploy-summary.txt（含面板地址、SublinkX 接入信息、订阅链接，权限 600）
#       /root/deploy-<时间>.log（完整日志，不含密码）
# =============================================================================
set -Eeuo pipefail

XUI_VERSION="${XUI_VERSION:-v3.11.0}"
XHTTP_PORT=10000
SUB_PORT=2096
WEBROOT=/var/lib/acme-webroot
TS=$(date -u +%Y%m%dT%H%M%SZ)
LOG=/root/deploy-$TS.log
SUMMARY=/root/deploy-summary.txt

exec > >(tee -a "$LOG") 2>&1

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
step()  { echo; green "==== [$1] $2 ===="; }
die()   { red "错误：$*"; red "日志：$LOG"; exit 1; }
trap 'red "第 $LINENO 行出错，部署中止。日志：$LOG"' ERR

ask() {  # ask VAR "提示" [默认值]
  local var=$1 prompt=$2 def=${3:-}
  if [[ -n "${!var:-}" ]]; then echo "$prompt：${!var}（来自环境变量）"; return; fi
  local ans
  if [[ -n "$def" ]]; then read -rp "$prompt [$def]：" ans; ans=${ans:-$def}
  else while [[ -z "${ans:-}" ]]; do read -rp "$prompt：" ans; done; fi
  printf -v "$var" '%s' "$ans"
}
confirm() { local a; read -rp "$1 [y/N]：" a; [[ "$a" =~ ^[Yy]$ ]]; }

# -----------------------------------------------------------------------------
step 0 "检查环境"
[[ $EUID -eq 0 ]] || die "请用 root 运行"
. /etc/os-release
[[ "$ID" == "ubuntu" && ( "$VERSION_ID" == "22.04" || "$VERSION_ID" == "24.04" ) ]] \
  || { yellow "当前系统 $PRETTY_NAME 未经验证（推荐 Ubuntu 22.04/24.04）"; confirm "仍然继续？" || exit 1; }
[[ ! -d /usr/local/x-ui ]] || die "检测到已安装 3x-ui（/usr/local/x-ui）。本脚本只用于全新机器。"
command -v curl >/dev/null && command -v dig >/dev/null || { apt-get update -q && apt-get install -y -q curl dnsutils; }

PUBLIC_IP=$(curl -4 -fsS --max-time 10 https://api.ipify.org || curl -4 -fsS --max-time 10 https://ifconfig.me)
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "取不到公网 IPv4"
IFACE=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
if ip -4 addr show dev "$IFACE" | grep -q "inet $PUBLIC_IP/"; then BIND_IP=$PUBLIC_IP
else BIND_IP=0.0.0.0; yellow "注意：公网 IP $PUBLIC_IP 不在网卡 $IFACE 上（可能是 NAT 机），REALITY 和 Nginx 9443 将监听 0.0.0.0"; fi
echo "公网 IP：$PUBLIC_IP   出口网卡：$IFACE"

# -----------------------------------------------------------------------------
step 1 "收集参数"
ask CDN_DOMAIN   "CDN 域名（XHTTP + 伪装站，之后开橙云）"
ask PANEL_DOMAIN "面板域名（面板 / 订阅 / HY2，之后开橙云）"
ask PANEL_USER   "面板用户名" "admin"
if [[ -z "${PANEL_PASS:-}" ]]; then
  while :; do
    read -rsp "面板密码（至少 10 位，不回显）：" PANEL_PASS; echo
    read -rsp "再输一次：" p2; echo
    [[ "$PANEL_PASS" == "$p2" && ${#PANEL_PASS} -ge 10 ]] && break
    red "两次不一致或少于 10 位，请重输"
  done
fi
ask ACME_EMAIL   "证书邮箱（Let's Encrypt 到期提醒）"
if [[ -z "${SSH_PUBKEY+x}" ]]; then read -rp "你的 SSH 公钥（ssh-ed25519 开头，可留空）：" SSH_PUBKEY; fi

# ---- 可选项：推荐几个 + 随机生成 + 自定义（环境变量预填则跳过）------------------
rand() { python3 -c "import secrets,string;print(''.join(secrets.choice(string.ascii_lowercase+string.digits) for _ in range($1)))"; }
choose() {  # choose VAR "标题" 校验正则 随机值 推荐1 推荐2 推荐3
  local var=$1 title=$2 re=$3 rnd=$4; shift 4
  if [[ -n "${!var:-}" ]]; then
    [[ "${!var}" =~ $re ]] || die "$var=${!var} 格式不对"
    echo "$title：${!var}（来自环境变量）"; return
  fi
  local opts=("$@") i ans val
  echo "$title："
  for i in "${!opts[@]}"; do printf '  %d) %s\n' $((i + 1)) "${opts[$i]}"; done
  printf '  %d) 随机生成：%s（推荐）\n' $((${#opts[@]} + 1)) "$rnd"
  printf '  %d) 自定义\n' $((${#opts[@]} + 2))
  while :; do
    read -rp "选择 [$((${#opts[@]} + 1))]：" ans; ans=${ans:-$((${#opts[@]} + 1))}
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then val=${opts[$((ans - 1))]}
    elif [[ "$ans" == "$((${#opts[@]} + 1))" ]]; then val=$rnd
    elif [[ "$ans" == "$((${#opts[@]} + 2))" ]]; then read -rp "输入自定义值：" val
    else red "请输入 1–$((${#opts[@]} + 2))"; continue; fi
    [[ "$val" =~ $re ]] && break
    red "格式不对：$val"
  done
  printf -v "$var" '%s' "$val"
}

SEG='^/[A-Za-z0-9._-]{2,40}/$'                     # 单段路径，如 /console/
choose PANEL_PATH "面板路径（只能经 Cloudflare 域名访问）" "$SEG" "/$(rand 16)/" \
  "/console/" "/dashboard/" "/manage/"
choose SUB_PATH "订阅路径" "$SEG" "/$(rand 12)/" "/sub/" "/feed/" "/rss/"
[[ "$SUB_PATH" != "$PANEL_PATH" ]] || die "订阅路径不能和面板路径相同"
choose XHTTP_PATH "XHTTP 路径（伪装成网站接口）" '^/[A-Za-z0-9._/-]{2,60}[A-Za-z0-9]$' "/api/$(rand 8)/stream" \
  "/api/v1/poll" "/api/v2/events" "/assets/upload"
[[ "$XHTTP_PATH/" != "$PANEL_PATH" && "$XHTTP_PATH/" != "$SUB_PATH" ]] || die "XHTTP 路径不能和面板/订阅路径相同"
choose TRUST_HEADER "Nginx 传给 Xray 的可信标记头（用于识别真实客户端 IP）" '^X-[A-Za-z0-9-]{3,40}$' "X-$(rand 10)" \
  "X-Edge-Verified" "X-Origin-Trusted" "X-Proxy-Auth"
choose CLIENTS "用户名（多个用逗号分隔）" '^[^,[:space:]]+(,[^,[:space:]]+)*$' "u$(rand 4)" \
  "user1" "home,phone" "user1,user2,user3"

if [[ -z "${CF_API_TOKEN+x}" ]]; then
  echo "Cloudflare API Token（权限：区域 DNS 编辑 + 区域设置编辑）：填了脚本会自动建 DNS 记录、切橙云、设 SSL 严格；"
  read -rsp "留空则这些步骤你手动做（不回显）：" CF_API_TOKEN; echo
fi

# ---- Cloudflare API 小工具 ----------------------------------------------------
cat > /root/.cf-api.py <<'CFEOF'
import json, os, sys, urllib.request, urllib.error
T = os.environ['CF_API_TOKEN']
def call(method, path, body=None):
    req = urllib.request.Request('https://api.cloudflare.com/client/v4' + path, method=method,
          data=None if body is None else json.dumps(body).encode(),
          headers={'Authorization': 'Bearer ' + T, 'Content-Type': 'application/json'})
    try: r = json.load(urllib.request.urlopen(req, timeout=20))
    except urllib.error.HTTPError as e: r = json.load(e)
    if not r.get('success'): raise SystemExit(f'Cloudflare API {method} {path} 失败：{r.get("errors")}')
    return r['result']
def zone(name):
    parts = name.split('.')
    for i in range(len(parts) - 1):
        z = call('GET', '/zones?name=' + '.'.join(parts[i:]))
        if z: return z[0]['id']
    raise SystemExit(f'Token 看不到 {name} 所在的区域（域名不在这个 CF 账号，或 Token 没授权该区域）')
cmd, *a = sys.argv[1:]
if cmd == 'verify':
    print(call('GET', '/user/tokens/verify')['status'])
elif cmd == 'a':                       # a <域名> <IP> <true|false>
    name, ip, prox = a[0], a[1], a[2] == 'true'
    z = zone(name); rec = call('GET', f'/zones/{z}/dns_records?type=A&name={name}')
    body = {'type': 'A', 'name': name, 'content': ip, 'proxied': prox, 'ttl': 1}
    if rec: call('PUT', f'/zones/{z}/dns_records/{rec[0]["id"]}', body)
    else: call('POST', f'/zones/{z}/dns_records', body)
    print(f'{name} → {ip}（{"橙云" if prox else "灰云"}）')
elif cmd == 'ssl':                     # ssl <域名> <模式>
    z = zone(a[0]); call('PATCH', f'/zones/{z}/settings/ssl', {'value': a[1]}); print(f'SSL 模式：{a[1]}')
CFEOF
chmod 600 /root/.cf-api.py
cf() { CF_API_TOKEN="$CF_API_TOKEN" python3 /root/.cf-api.py "$@"; }

if [[ -n "$CF_API_TOKEN" ]]; then
  [[ "$(cf verify)" == "active" ]] || die "Cloudflare Token 无效"
  green "Cloudflare：先建灰云记录（第一次申请证书要直连）"
  cf a "$CDN_DOMAIN" "$PUBLIC_IP" false
  cf a "$PANEL_DOMAIN" "$PUBLIC_IP" false
  cf ssl "$CDN_DOMAIN" strict || yellow "SSL 模式没设成功（Token 可能缺「区域设置编辑」权限），稍后手动设为「完全（严格）」"
  cf ssl "$PANEL_DOMAIN" strict >/dev/null 2>&1 || true   # 两个域名不在同一区域时也设上
  echo -n "等待 DNS 生效"
  for _ in $(seq 1 36); do
    a1=$(dig +short @1.1.1.1 "$CDN_DOMAIN" A | tail -1); a2=$(dig +short @1.1.1.1 "$PANEL_DOMAIN" A | tail -1)
    [[ "$a1" == "$PUBLIC_IP" && "$a2" == "$PUBLIC_IP" ]] && { echo " OK"; break; }
    echo -n "."; sleep 5
  done
  echo
fi

# 两个域名此时应是灰云，直接解析到本机
for d in "$CDN_DOMAIN" "$PANEL_DOMAIN"; do
  got=$(dig +short @1.1.1.1 "$d" A | tail -1)
  if [[ "$got" != "$PUBLIC_IP" ]]; then
    yellow "$d 解析到 ${got:-无}，不是本机 $PUBLIC_IP。"
    yellow "首次申请证书需要灰云（仅 DNS）直连。请到 Cloudflare 把 A 记录改成灰云并指向本机。"
    confirm "已改好或确定要继续？" || exit 1
  fi
done

# ---- REALITY 目标：没指定就扫描本机所在 /24，自动挑邻居 --------------------------
pick_reality_sni() {
  local arch net csv n m total
  arch=$(dpkg --print-architecture); [[ "$arch" == arm64 ]] || arch=amd64
  net="${PUBLIC_IP%.*}.0/24"; csv=/root/reality-scan-$TS.csv
  green "扫描 $net 的 443 端口，找同网段的 TLS 网站（约 1–3 分钟）……"
  curl -fsSL -o /usr/local/bin/RealiTLScanner \
    "https://github.com/XTLS/RealiTLScanner/releases/download/v0.2.3/RealiTLScanner-linux-$arch" || return 1
  chmod 755 /usr/local/bin/RealiTLScanner
  timeout 600 /usr/local/bin/RealiTLScanner -addr "$net" -port 443 -thread 20 -timeout 5 -out "$csv" >/dev/null 2>&1 || true
  [[ -s "$csv" ]] || { yellow "扫描没有结果"; return 1; }
  python3 - "$csv" "$PUBLIC_IP" > /root/reality-candidates.txt <<'SCANEOF'
import csv, ipaddress, socket, subprocess, sys
path, me = sys.argv[1:]
seen, out = set(), []
for r in csv.DictReader(open(path, newline='')):
    d = (r.get('CERT_DOMAIN') or '').strip().lower()
    ip = (r.get('IP') or '').strip()
    if ip == me or not d or d.startswith('*') or d in seen:
        continue
    if any(k in d for k in ('hy2', 'vless', 'vmess', 'trojan', 'xray', 'v2ray', 'proxy', 'vpn', 'reality', 'node')):
        continue                                       # 看起来像别人的代理节点，不偷
    try:
        ipaddress.ip_address(d); continue
    except ValueError:
        pass
    if r.get('TLS') != 'TLS 1.3' or r.get('ALPN') != 'h2' or not (r.get('CURVE') or '').startswith('X25519'):
        continue
    seen.add(d)
    try:
        ips = {a[4][0] for a in socket.getaddrinfo(d, 443, socket.AF_INET)}
    except Exception:
        continue
    if ip not in ips:                                  # DNS 必须解析回这台邻居
        continue
    code = subprocess.run(['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '8',
                           '--resolve', f'{d}:443:{ip}', f'https://{d}/'], capture_output=True, text=True).stdout
    if code != '200':                                  # 首页直接 200，不跳转
        continue
    out.append((0 if 'MLKEM' in r['CURVE'] else 1, d, ip, r['CURVE']))
for _, d, ip, curve in sorted(out):
    print(f'{d}\t{ip}\t{curve}')
SCANEOF
  [[ -s /root/reality-candidates.txt ]] || { yellow "扫到了网站，但没有同时满足 TLS1.3+h2、DNS 回指、首页 200 的"; return 1; }
  echo "合格的邻居（支持 X25519MLKEM768 的排在前面）："
  awk -F'\t' '{printf "  %2d) %-40s %-16s %s\n", NR, $1, $2, $3}' /root/reality-candidates.txt
  total=$(wc -l < /root/reality-candidates.txt)
  read -rp "选主用的编号 [1]：" n; n=${n:-1}
  REALITY_SNI=$(awk -F'\t' -v n="$n" 'NR==n{print $1}' /root/reality-candidates.txt)
  if (( total > 1 )); then
    read -rp "选备用的编号（只记录，不启用）[2]：" m; m=${m:-2}
    REALITY_SNI_BACKUP=$(awk -F'\t' -v n="$m" 'NR==n{print $1}' /root/reality-candidates.txt)
  fi
  [[ -n "$REALITY_SNI" ]]
}

if [[ -z "${REALITY_SNI:-}" ]]; then
  pick_reality_sni || ask REALITY_SNI "没能自动挑到，请手动输入 REALITY 目标域名（同网段邻居）"
fi
REALITY_SNI_BACKUP=${REALITY_SNI_BACKUP:-}
# REALITY 目标基本检查：TLS1.3 + h2
if ! echo | timeout 10 openssl s_client -connect "$REALITY_SNI:443" -servername "$REALITY_SNI" -tls1_3 -alpn h2 2>/dev/null \
     | grep -q "ALPN protocol: h2"; then
  yellow "$REALITY_SNI 不支持 TLS1.3 + h2，或连不上。REALITY 目标必须同时支持两者。"
  confirm "仍然使用它？" || exit 1
fi
NBR=$(getent ahostsv4 "$REALITY_SNI" | awk 'NR==1{print $1}')
[[ "${NBR%.*}" == "${PUBLIC_IP%.*}" ]] || yellow "提醒：$REALITY_SNI 解析到 $NBR，不在本机同一 /24（$PUBLIC_IP），不算「偷邻居」。"
echo "REALITY 主用：$REALITY_SNI   备用：${REALITY_SNI_BACKUP:-无}"

# -----------------------------------------------------------------------------
step 2 "系统更新、swap、BBR、fail2ban"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get -y -q -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef upgrade --with-new-pkgs
apt-get install -y -q nginx nftables fail2ban socat cron sqlite3 python3 openssl dnsutils ca-certificates
systemctl enable --now nftables >/dev/null 2>&1 || true

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if ! swapon --show --noheadings | grep -q . && (( MEM_MB < 1536 )); then
  fallocate -l 256M /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "已加 256MB swap"
fi

cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl --system >/dev/null

cat > /etc/fail2ban/jail.d/sshd-local.conf <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1d
EOF
systemctl enable --now fail2ban >/dev/null; systemctl restart fail2ban

if [[ -n "${SSH_PUBKEY:-}" ]]; then
  install -d -m 700 /root/.ssh
  grep -qF "$SSH_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  echo "已加入你的 SSH 公钥（密码登录仍开着，确认密钥能登后再按手册关闭）"
fi

# -----------------------------------------------------------------------------
step 3 "Nginx 基础配置 + 80 端口 ACME"
NC=/etc/nginx/nginx.conf
cp -a $NC $NC.bak-$TS
grep -q '^worker_rlimit_nofile' $NC || sed -i '1i worker_rlimit_nofile 8192;' $NC
sed -i -E 's/^(\s*)worker_connections\s+[0-9]+;/\1worker_connections 4096;/' $NC
sed -i -E 's/^(\s*)#\s*server_tokens off;/\1server_tokens off;/' $NC
grep -qE '^\s*server_tokens off;' $NC || sed -i '/http {/a \\tserver_tokens off;' $NC
rm -f /etc/nginx/sites-enabled/default
install -d -m 755 $WEBROOT/.well-known/acme-challenge

cat > /etc/nginx/conf.d/acme-http.conf <<EOF
server {
    listen 80;
    server_name $CDN_DOMAIN $PANEL_DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
        try_files \$uri =404;
        add_header Cache-Control "no-store" always;
    }
    location / { return 404; }
}
server {
    listen 80 default_server;
    server_name _;
    return 444;
}
EOF
nginx -t && systemctl enable nginx >/dev/null && systemctl restart nginx

# -----------------------------------------------------------------------------
step 4 "申请 Let's Encrypt 证书（$CDN_DOMAIN + $PANEL_DOMAIN）"
CERT_DIR=/root/cert/$PANEL_DOMAIN
install -d -m 700 "$CERT_DIR"
curl -fsSL https://get.acme.sh | sh -s email="$ACME_EMAIL" >/dev/null
ACME=/root/.acme.sh/acme.sh
$ACME --set-default-ca --server letsencrypt >/dev/null

cat > /usr/local/sbin/reload-public-domain-cert <<EOF
#!/bin/sh
# 续期后：校验证书未过期、域名匹配、私钥匹配，三项通过才重载 Nginx / 重启 x-ui
set -eu
F=$CERT_DIR/fullchain.pem; K=$CERT_DIR/privkey.pem
/usr/bin/openssl x509 -in "\$F" -noout -checkend 0 >/dev/null
/usr/bin/openssl x509 -in "\$F" -noout -checkhost $PANEL_DOMAIN | /bin/grep -q "does match"
certkey=\$(/usr/bin/openssl x509 -in "\$F" -pubkey -noout | /usr/bin/openssl sha256)
filekey=\$(/usr/bin/openssl pkey -in "\$K" -pubout | /usr/bin/openssl sha256)
[ "\$certkey" = "\$filekey" ]
/usr/bin/systemctl reload nginx || true
if /usr/bin/systemctl is-enabled --quiet x-ui 2>/dev/null; then
  /usr/bin/systemctl restart x-ui
  /usr/bin/systemctl is-active --quiet x-ui
fi
EOF
chmod 755 /usr/local/sbin/reload-public-domain-cert

$ACME --issue -d "$PANEL_DOMAIN" -d "$CDN_DOMAIN" --webroot $WEBROOT --keylength ec-256 \
  || die "证书申请失败：确认两个域名是灰云并解析到 $PUBLIC_IP，80 端口没被服务商挡"
$ACME --install-cert -d "$PANEL_DOMAIN" --ecc \
  --fullchain-file "$CERT_DIR/fullchain.pem" --key-file "$CERT_DIR/privkey.pem" \
  --reloadcmd /usr/local/sbin/reload-public-domain-cert
openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -enddate -ext subjectAltName | tr '\n' ' '; echo

# -----------------------------------------------------------------------------
step 5 "安装 3x-ui $XUI_VERSION（面板只监听本机）"
PANEL_PORT=$(shuf -i 20000-60000 -n 1)
while ss -ltnH "sport = :$PANEL_PORT" | grep -q .; do PANEL_PORT=$(shuf -i 20000-60000 -n 1); done
curl -fsSL -o /root/xui-install.sh "https://raw.githubusercontent.com/MHSanaei/3x-ui/$XUI_VERSION/install.sh"
XUI_NONINTERACTIVE=1 XUI_USERNAME="$PANEL_USER" XUI_PASSWORD="$PANEL_PASS" \
XUI_PANEL_PORT="$PANEL_PORT" XUI_WEB_BASE_PATH="${PANEL_PATH//\//}" XUI_SSL_MODE=none \
  bash /root/xui-install.sh "$XUI_VERSION" </dev/null | grep -viE 'password|apiToken' || true
[[ -x /usr/local/x-ui/x-ui ]] || die "3x-ui 安装失败"
XUI=/usr/local/x-ui/x-ui
$XUI setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT" \
  -webBasePath "$PANEL_PATH" -listenIP 127.0.0.1 \
  -webCert "$CERT_DIR/fullchain.pem" -webCertKey "$CERT_DIR/privkey.pem" | grep -vi password || true

# -----------------------------------------------------------------------------
step 6 "Cloudflare 回源分流（nftables：CF 来源的 443 → 9443）"
install -d -m 700 /var/lib/cf-origin-split
cat > /usr/local/sbin/cf-origin-split <<'PYEOF'
#!/usr/bin/python3
"""只维护 cf_origin_split 这张 nftables 表和 Nginx 的 CF 可信代理列表。"""
import fcntl, ipaddress, json, subprocess, sys, urllib.request
from pathlib import Path
CONF = json.loads(Path('/etc/cf-origin-split.json').read_text())
IP, IFACE = CONF['ip'], CONF['iface']
STATE = Path('/var/lib/cf-origin-split/networks.json')
TRUST = Path('/etc/nginx/conf.d/00-port443-client-ip.conf')

def run(args, data=None):
    p = subprocess.run(args, input=data, text=True, capture_output=True, timeout=30)
    if p.returncode: raise RuntimeError(' '.join(args) + ': ' + p.stderr)
    return p.stdout

def validate(values, version):
    nets = {ipaddress.ip_network(v, strict=True) for v in values}
    if not (5 if version == 4 else 2) <= len(nets) <= 256: raise ValueError('Unexpected CF network count')
    if any(n.version != version or not n.is_global or n.prefixlen < (8 if version == 4 else 16) for n in nets):
        raise ValueError('Invalid or overly broad CF network')
    return sorted(map(str, nets))

def fetch():
    with urllib.request.urlopen('https://api.cloudflare.com/client/v4/ips', timeout=25) as r:
        data = r.read(65537)
    p = json.loads(data)
    if p.get('success') is not True: raise ValueError('CF API failed')
    return {str(v): validate(p['result'][f'ipv{v}_cidrs'], v) for v in (4, 6)}

def trusted(nets):
    return ('# Generated by cf-origin-split\n'
            + ''.join(f'set_real_ip_from {n};\n' for v in ('4', '6') for n in nets[v])
            + 'real_ip_header CF-Connecting-IP;\n'
            + "log_format port443_http '$remote_addr peer=$realip_remote_addr port=$server_port [$time_local] \"$request\" $status';\n")

def rules(nets):
    return f'''table inet cf_origin_split {{
    set cf4 {{ type ipv4_addr; flags interval; elements = {{ {', '.join(nets['4'])} }}; }}
    set cf6 {{ type ipv6_addr; flags interval; elements = {{ {', '.join(nets['6'])} }}; }}
    chain prerouting {{
        type nat hook prerouting priority dstnat; policy accept;
        iifname "{IFACE}" fib daddr type local tcp dport 443 ip saddr @cf4 counter redirect to :9443
        iifname "{IFACE}" fib daddr type local tcp dport 443 ip6 saddr @cf6 counter redirect to :9443
    }}
    chain input {{
        type filter hook input priority -5; policy accept;
        iifname "lo" tcp dport 9443 accept
        tcp dport 9443 ct status dnat ct state established,related accept
        tcp dport 9443 ct status dnat ip saddr @cf4 counter accept
        tcp dport 9443 ct status dnat ip6 saddr @cf6 counter accept
        tcp dport 9443 counter drop
    }}
}}
'''

def set_update(nets):
    return ''.join(f'flush set inet cf_origin_split cf{v}\nadd element inet cf_origin_split cf{v} {{ {", ".join(nets[v])} }}\n' for v in ('4', '6'))

def nft(data):
    run(['nft', '--check', '-f', '-'], data); run(['nft', '-f', '-'], data)

def write(path, text):
    t = path.with_name(path.name + '.tmp'); t.write_text(text); t.chmod(0o644); t.replace(path)

def main(action):
    STATE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE.parent / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if action == '--init':
            nets = fetch(); run(['nft', '--check', '-f', '-'], rules(nets))
            write(STATE, json.dumps(nets, indent=2)); write(TRUST, trusted(nets))
            print('Initialized CF networks:', len(nets['4']), len(nets['6'])); return
        old = json.loads(STATE.read_text()); old = {v: validate(old[v], int(v)) for v in ('4', '6')}
        if action == '--load':
            exists = subprocess.run(['nft', 'list', 'table', 'inet', 'cf_origin_split'], capture_output=True).returncode == 0
            nft(('delete table inet cf_origin_split\n' if exists else '') + rules(old)); print('Loaded CF split rules'); return
        if action != '--update': raise ValueError('Unknown action')
        new = fetch()
        if new == old: print('CF networks unchanged'); return
        if any(len(set(old[v]) - set(new[v])) > len(old[v]) // 2 or len(new[v]) > 2 * len(old[v]) for v in ('4', '6')):
            raise ValueError('Large CF list change; kept saved ranges for review')
        original = TRUST.read_text()
        try:
            write(TRUST, trusted(new)); run(['nginx', '-t']); run(['systemctl', 'reload', 'nginx'])
            nft(set_update(new)); write(STATE, json.dumps(new, indent=2))
        except Exception:
            write(TRUST, original); nft(set_update(old)); run(['systemctl', 'reload', 'nginx']); raise
        print('Updated CF ranges')

if __name__ == '__main__':
    main(sys.argv[1])
PYEOF
chmod 755 /usr/local/sbin/cf-origin-split
printf '{"ip":"%s","iface":"%s"}\n' "$PUBLIC_IP" "$IFACE" > /etc/cf-origin-split.json

cat > /etc/systemd/system/cf-origin-split.service <<'EOF'
[Unit]
Description=Cloudflare source-based 443 routing
Wants=network-online.target
After=network-online.target nftables.service
Before=nginx.service x-ui.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cf-origin-split --load
ExecReload=/usr/local/sbin/cf-origin-split --load
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/cf-origin-split-update.service <<'EOF'
[Unit]
Description=Update official Cloudflare ranges safely
Wants=network-online.target
After=network-online.target cf-origin-split.service
Requires=cf-origin-split.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cf-origin-split --update
TimeoutStartSec=180
EOF
cat > /etc/systemd/system/cf-origin-split-update.timer <<'EOF'
[Unit]
Description=Daily Cloudflare address-range check
[Timer]
OnCalendar=daily
RandomizedDelaySec=30m
Persistent=true
[Install]
WantedBy=timers.target
EOF
for u in nginx x-ui; do
  install -d /etc/systemd/system/$u.service.d
  printf '[Unit]\nWants=cf-origin-split.service\nAfter=cf-origin-split.service\n' > /etc/systemd/system/$u.service.d/cf-origin-split.conf
done
/usr/local/sbin/cf-origin-split --init
systemctl daemon-reload
systemctl enable --now cf-origin-split.service cf-origin-split-update.timer >/dev/null

# -----------------------------------------------------------------------------
step 7 "Nginx 9443（CF 回源入口：伪装站 + XHTTP + 面板 + 订阅）"
SITE_ROOT=/var/www/$CDN_DOMAIN
install -d -m 755 "$SITE_ROOT"
[[ -f "$SITE_ROOT/index.html" ]] || cat > "$SITE_ROOT/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Notes</title><style>body{font:16px/1.6 system-ui,sans-serif;max-width:680px;margin:64px auto;padding:0 16px;color:#222}</style></head>
<body><h1>Notes</h1><p>Small things worth writing down.</p></body></html>
EOF
cat > /etc/nginx/conf.d/$CDN_DOMAIN.conf <<EOF
map \$http_upgrade \$admin_connection_upgrade { default upgrade; '' close; }

server {
    listen $BIND_IP:9443 ssl http2;
    server_name $CDN_DOMAIN $PANEL_DOMAIN;
    if (\$host !~ "^(${CDN_DOMAIN//./\\.}|${PANEL_DOMAIN//./\\.})\$") { return 444; }
    access_log /var/log/nginx/cf-origin-access.log port443_http;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;

    root $SITE_ROOT;
    index index.html;

    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type text/plain;
        try_files \$uri =404;
    }

    location ^~ $PANEL_PATH {
        proxy_pass https://127.0.0.1:$PANEL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$admin_connection_upgrade;
        proxy_set_header Host $PANEL_DOMAIN;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_ssl_verify off;
        proxy_connect_timeout 5s;
        proxy_read_timeout 3600s;
        proxy_buffering off;
        add_header Cache-Control "no-store" always;
    }

    location ^~ $SUB_PATH {
        proxy_pass https://127.0.0.1:$SUB_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host $CDN_DOMAIN;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_ssl_verify off;
        proxy_connect_timeout 5s;
        proxy_read_timeout 30s;
        add_header Cache-Control "no-store" always;
    }

    location $XHTTP_PATH {
        proxy_pass http://127.0.0.1:$XHTTP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host $CDN_DOMAIN;
        proxy_set_header $TRUST_HEADER 1;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection upgrade;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location / { try_files \$uri \$uri/ =404; }
}

server {
    listen $BIND_IP:9443 ssl http2 default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF
nginx -t && systemctl reload nginx

# -----------------------------------------------------------------------------
step 8 "订阅设置 + 创建入站（REALITY / XHTTP / HY2）"
systemctl stop x-ui
python3 - "$CERT_DIR" "$CDN_DOMAIN" "$SUB_PATH" "$SUB_PORT" <<'PYEOF'
import sqlite3, sys
cert, cdn, subpath, subport = sys.argv[1:]
c = sqlite3.connect('/etc/x-ui/x-ui.db')
want = {'subEnable': 'true', 'subPort': subport, 'subPath': subpath, 'subListen': '',
        'subDomain': cdn, 'subURI': f'https://{cdn}{subpath}', 'subUpdates': '12',
        'subCertFile': f'{cert}/fullchain.pem', 'subKeyFile': f'{cert}/privkey.pem',
        'subJsonEnable': 'false', 'subClashEnable': 'false', 'remarkModel': '-ieo'}
for k, v in want.items():
    if c.execute('update settings set value=? where key=?', (v, k)).rowcount == 0:
        c.execute('insert into settings(key,value) values(?,?)', (k, v))
c.commit()
PYEOF
systemctl start x-ui
for i in $(seq 1 30); do ss -ltnH "sport = :$PANEL_PORT" | grep -q 127.0.0.1 && break; sleep 1; done
ss -ltnH "sport = :$PANEL_PORT" | grep -q 127.0.0.1 || die "面板没有在 127.0.0.1:$PANEL_PORT 起来"

DEPLOY_TOKEN=$($XUI setting -getApiToken -tokenName deploy -tokenScope admin | awk '/^apiToken:/{print $2}')
[[ -n "$DEPLOY_TOKEN" ]] || die "拿不到面板 API Token"
XRAY_BIN=$(ls /usr/local/x-ui/bin/xray-linux-* | head -1)
REALITY_LISTEN=$BIND_IP

export PANEL_PORT PANEL_PATH DEPLOY_TOKEN XRAY_BIN PUBLIC_IP REALITY_LISTEN REALITY_SNI CDN_DOMAIN \
       PANEL_DOMAIN CLIENTS CERT_DIR XHTTP_PATH XHTTP_PORT TRUST_HEADER
python3 - <<'PYEOF'
import json, os, re, secrets, ssl, subprocess, urllib.request, uuid
E = os.environ
base = f"https://127.0.0.1:{E['PANEL_PORT']}{E['PANEL_PATH']}panel/api"
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE

def api(path, body):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(), method='POST',
          headers={'Authorization': 'Bearer ' + E['DEPLOY_TOKEN'], 'Content-Type': 'application/json'})
    r = json.load(urllib.request.urlopen(req, context=ctx, timeout=30))
    if not r.get('success'): raise SystemExit(f'API {path} 失败：{r.get("msg")}')
    return r.get('obj')

out = subprocess.run([E['XRAY_BIN'], 'x25519'], capture_output=True, text=True).stdout
priv = re.search(r'Private[^:]*:\s*(\S+)', out).group(1)
pub = re.search(r'(?:Public[^:]*|Password[^:]*):\s*(\S+)', out).group(1)
short_ids = [secrets.token_hex(4), secrets.token_hex(8), secrets.token_hex(2)]
names = [n.strip() for n in E['CLIENTS'].split(',') if n.strip()]
people = [{'email': n, 'subId': secrets.token_hex(8), 'uuid': str(uuid.uuid4()), 'hy': secrets.token_urlsafe(12)} for n in names]
base_client = {'enable': True, 'limitIp': 0, 'totalGB': 0, 'expiryTime': 0, 'tgId': '', 'reset': 0, 'comment': ''}
sniff = json.dumps({'enabled': True, 'destOverride': ['http', 'tls', 'quic'], 'routeOnly': True})

def inbound(remark, tag, listen, port, proto, settings, stream, strategy, share=''):
    return api('/inbounds/add', {'remark': remark, 'enable': True, 'listen': listen, 'port': port, 'protocol': proto,
        'tag': tag, 'settings': json.dumps(settings, ensure_ascii=False), 'streamSettings': json.dumps(stream),
        'sniffing': sniff, 'expiryTime': 0, 'total': 0, 'shareAddrStrategy': strategy, 'shareAddr': share})

sni = E['REALITY_SNI']
r = inbound('REALITY-443', 'in-443-tcp', E['REALITY_LISTEN'], 443, 'vless',
    {'clients': [dict(base_client, id=p['uuid'], flow='xtls-rprx-vision', email=p['email'], subId=p['subId']) for p in people],
     'decryption': 'none', 'encryption': 'none'},
    {'network': 'tcp', 'tcpSettings': {'acceptProxyProtocol': False, 'header': {'type': 'none'}}, 'security': 'reality',
     'realitySettings': {'show': False, 'xver': 0, 'target': f'{sni}:443', 'serverNames': [sni], 'privateKey': priv,
        'minClientVer': '', 'maxClientVer': '', 'maxTimediff': 0, 'shortIds': short_ids, 'mldsa65Seed': '',
        'settings': {'publicKey': pub, 'fingerprint': 'chrome', 'serverName': '', 'spiderX': '/', 'mldsa65Verify': ''}}},
    'listen' if E['REALITY_LISTEN'] != '0.0.0.0' else 'custom', '' if E['REALITY_LISTEN'] != '0.0.0.0' else E['PUBLIC_IP'])

x = inbound('XHTTP-CDN', 'in-10000-tcp', '127.0.0.1', int(E['XHTTP_PORT']), 'vless',
    {'clients': [dict(base_client, id=p['uuid'], flow='', email=p['email'], subId=p['subId']) for p in people],
     'decryption': 'none', 'encryption': 'none'},
    {'network': 'xhttp', 'security': 'none',
     'xhttpSettings': {'path': E['XHTTP_PATH'], 'host': E['CDN_DOMAIN'], 'mode': 'auto', 'xPaddingBytes': '100-1000',
                       'scMaxBufferedPosts': 30, 'scStreamUpServerSecs': '20-80'},
     'sockopt': {'tcpcongestion': 'bbr', 'trustedXForwardedFor': [E['TRUST_HEADER']]}},
    'listen')
api('/hosts/add', {'inboundIds': [x['id']], 'hosts': [E['CDN_DOMAIN']], 'remark': 'XHTTP-CDN-443', 'port': 443,
                   'security': 'tls', 'sni': E['CDN_DOMAIN'], 'alpn': ['h2', 'http/1.1'], 'fingerprint': 'chrome'})

cert = E['CERT_DIR']
inbound('HY2-443', 'in-443-udp', '', 443, 'hysteria',
    {'clients': [dict(base_client, auth=p['hy'], email=p['email'], subId=p['subId']) for p in people], 'version': 2},
    {'network': 'hysteria', 'hysteriaSettings': {'version': 2, 'udpIdleTimeout': 60}, 'security': 'tls',
     'tlsSettings': {'serverName': E['PANEL_DOMAIN'], 'minVersion': '1.2', 'maxVersion': '1.3', 'alpn': ['h3'],
        'certificates': [{'certificateFile': f'{cert}/fullchain.pem', 'keyFile': f'{cert}/privkey.pem',
                          'ocspStapling': 0, 'oneTimeLoading': False, 'usage': 'encipherment', 'buildChain': False}],
        'settings': {'fingerprint': 'chrome', 'echConfigList': '', 'pinnedPeerCertSha256': [], 'verifyPeerCertByName': ''}},
     'finalmask': {'udp': [{'type': 'salamander', 'settings': {'password': secrets.token_urlsafe(16)}}]}},
    'custom', E['PUBLIC_IP'])

json.dump([{'email': p['email'], 'subId': p['subId']} for p in people], open('/root/.deploy-clients.json', 'w'))
print('已创建入站：REALITY-443、XHTTP-CDN（含主机记录）、HY2-443；用户：', ', '.join(names))
PYEOF
chmod 600 /root/.deploy-clients.json
systemctl restart x-ui
sleep 5

# -----------------------------------------------------------------------------
step 9 "SublinkX 专用 Token（node-sync 权限）"
SUBLINKX_TOKEN=$($XUI setting -getApiToken -tokenName sublinkx -tokenScope node-sync | awk '/^apiToken:/{print $2}')
# 部署用的 admin token 用完即作废：旋转成一个不保存的新值
$XUI setting -getApiToken -tokenName deploy -tokenScope admin >/dev/null

# -----------------------------------------------------------------------------
step 10 "自检"
ok=1
chk() { if eval "$2" >/dev/null 2>&1; then green "  ✓ $1"; else red "  ✗ $1"; ok=0; fi; }
chk "x-ui / nginx / fail2ban / cf-origin-split 运行中" "systemctl is-active --quiet x-ui nginx fail2ban cf-origin-split"
chk "REALITY 监听 TCP 443" "ss -ltnpH 'sport = :443' | grep -q xray"
chk "HY2 监听 UDP 443"     "ss -lunpH 'sport = :443' | grep -q xray"
chk "XHTTP 监听 127.0.0.1:$XHTTP_PORT" "ss -ltnH 'sport = :$XHTTP_PORT' | grep -q 127.0.0.1"
chk "面板只监听 127.0.0.1:$PANEL_PORT" "! ss -ltnH 'sport = :$PANEL_PORT' | grep -vq 127.0.0.1"
chk "Nginx 9443 在监听" "ss -ltnH 'sport = :9443' | grep -q ."
chk "nftables 分流表已加载" "nft list table inet cf_origin_split"
chk "BBR 已启用" "[ \"\$(sysctl -n net.ipv4.tcp_congestion_control)\" = bbr ]"
chk "REALITY 目标 $REALITY_SNI 带 SNI 握手成功（xray tls ping）" "timeout 20 $XRAY_BIN tls ping $REALITY_SNI | awk '/Pinging with SNI/{f=1} f&&/Handshake succeeded/{ok=1} END{exit !ok}'"
chk "证书续期任务存在" "crontab -l | grep -q acme.sh"

echo
echo "原生订阅内容核对（地址 / SNI）："
python3 - "$SUB_PORT" "$SUB_PATH" "$CDN_DOMAIN" <<'PYEOF' || true
import base64, json, re, ssl, sys, urllib.parse, urllib.request
port, path, cdn = sys.argv[1:]
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
for c in json.load(open('/root/.deploy-clients.json')):
    req = urllib.request.Request(f'https://127.0.0.1:{port}{path}{c["subId"]}', headers={'Host': cdn})
    raw = urllib.request.urlopen(req, context=ctx, timeout=10).read()
    try: txt = base64.b64decode(raw + b'==').decode()
    except Exception: txt = raw.decode()
    for line in txt.splitlines():
        m = re.match(r'(\w+)://[^@]+@([^?#]+)\??([^#]*)', line)
        if m:
            q = urllib.parse.parse_qs(m.group(3))
            print(f"  {c['email']:8} {m.group(1):10} {m.group(2):28} sni={q.get('sni', [''])[0]} security={q.get('security', [''])[0]}")
PYEOF

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
if [[ -n "$CF_API_TOKEN" ]]; then
  step 11 "Cloudflare 切橙云并验证"
  cf a "$CDN_DOMAIN" "$PUBLIC_IP" true
  cf a "$PANEL_DOMAIN" "$PUBLIC_IP" true
  echo -n "等待 Cloudflare 生效"
  for _ in $(seq 1 24); do
    c1=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$CDN_DOMAIN/" || true)
    c2=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$PANEL_DOMAIN$PANEL_PATH" || true)
    [[ "$c1" == 200 && "$c2" == 200 ]] && break
    echo -n "."; sleep 5
  done
  echo
  [[ "$c1" == 200 ]] && green "  ✓ https://$CDN_DOMAIN/ 伪装站 200" || { red "  ✗ https://$CDN_DOMAIN/ 返回 $c1"; ok=0; }
  [[ "$c2" == 200 ]] && green "  ✓ https://$PANEL_DOMAIN$PANEL_PATH 面板 200" || { red "  ✗ 面板返回 $c2"; ok=0; }
fi
CF_DONE=$([[ -n "$CF_API_TOKEN" ]] && echo 1 || echo 0)

umask 077
{
  echo "部署时间（UTC）：$TS"
  echo "公网 IP：$PUBLIC_IP"
  echo
  echo "【面板】https://$PANEL_DOMAIN$PANEL_PATH  （Cloudflare 切橙云后可用；用户名 $PANEL_USER，密码为部署时输入的那个）"
  echo "        面板本机端口：$PANEL_PORT（只监听 127.0.0.1，外网直连不可达）"
  echo
  echo "【SublinkX 添加来源】"
  echo "  接入方式：API Token"
  echo "  面板基础地址：https://$PANEL_DOMAIN${PANEL_PATH%/}"
  echo "  API Token：$SUBLINKX_TOKEN"
  echo "  订阅服务器地址：https://$CDN_DOMAIN"
  echo "  订阅路径：${SUB_PATH//\//}"
  echo
  echo "【各用户原生订阅】"
  python3 -c "import json;[print(f'  {c[\"email\"]}: https://$CDN_DOMAIN$SUB_PATH'+c['subId']) for c in json.load(open('/root/.deploy-clients.json'))]"
  echo
  echo "【路径】面板 $PANEL_PATH   订阅 $SUB_PATH   XHTTP $XHTTP_PATH   可信标记头 $TRUST_HEADER"
  echo "【REALITY】目标/SNI：$REALITY_SNI   备用：${REALITY_SNI_BACKUP:-无}   监听：$REALITY_LISTEN:443"
  echo "【证书】$CERT_DIR（Let's Encrypt，自动续期，续期后执行 /usr/local/sbin/reload-public-domain-cert）"
  echo
  if [[ "$CF_DONE" == 1 ]]; then echo "【接下来】1) Cloudflare 已由脚本切成橙云、SSL 设为严格（若上面提示设置失败，请手动补上）"
  else echo "【接下来】1) Cloudflare 把 $CDN_DOMAIN 和 $PANEL_DOMAIN 切成橙云；SSL 模式设为「完全（严格）」"; fi
  echo "          2) 打开面板，开启两步验证"
  echo "          3) SublinkX 添加来源并同步；v2rayN 更新订阅后实测"
  echo "          4) 确认用你的 SSH 密钥能登录后，再关闭密码登录（见手册）"
} > "$SUMMARY"
chmod 600 "$SUMMARY"

echo
if (( ok )); then green "部署完成，自检全部通过。"; else yellow "部署完成，但有自检项未通过（见上方 ✗），请按手册「验收与常见坑」排查。"; fi
echo "汇总信息（含 SublinkX Token）已写入：$SUMMARY"
echo "查看：cat $SUMMARY"
