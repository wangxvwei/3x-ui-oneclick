# 3x-ui-oneclick

在一台全新的 Ubuntu VPS 上，一条命令部署 **REALITY + XHTTP（经 Cloudflare）+ Hysteria2**，三种入口共用 443 端口，面板不暴露在公网。

```
TCP 443 普通客户端        → Xray REALITY（偷同网段邻居网站的 TLS）
TCP 443 来自 Cloudflare   → nftables 转到 Nginx 9443 → XHTTP / 面板 / 订阅 / 伪装站
UDP 443                   → Xray Hysteria2（Salamander 混淆）
TCP 80                    → 只应答 Let's Encrypt 验证
```

## 特点

- **同一个 443 按来源分流**：只有 Cloudflare 的 IP 段会被转进 Nginx，其余连接全部交给 REALITY；CF IP 段每天自动更新。
- **自动挑 REALITY 目标**：扫描本机所在 /24，筛出支持 TLS1.3 + h2 + X25519、DNS 解析回邻居、首页 200 的网站，列出来让你选主用和备用。
- **面板只监听 127.0.0.1**：只能经 Cloudflare 后面的域名访问，扫 IP 扫不到。
- **路径不写死**：面板、订阅、XHTTP 路径和可信标记头，运行时可选推荐值、随机生成（默认）或自定义。
- **证书**：一张 Let's Encrypt 证书覆盖两个域名，自动续期；续期后先校验证书、域名、私钥，三项通过才重载。
- **可选 Cloudflare 自动化**：提供 API Token 后，自动建 DNS 记录、设 SSL「完全（严格）」、申请证书后切橙云并验证。
- **结束自检**：服务、端口、分流、BBR、REALITY 目标握手，以及每个用户原生订阅里的地址和 SNI。

## 准备

- 全新的 Ubuntu 22.04 或 24.04（64 位），root 登录，有独立公网 IPv4。
- 一个托管在 Cloudflare 的域名，准备两个名字：
  - CDN 域名（如 `example.com`）：XHTTP 和伪装站
  - 面板域名（如 `panel.example.com`）：面板、订阅、HY2 证书
- 可选：Cloudflare API Token，权限为「区域 · DNS · 编辑」+「区域 · 区域设置 · 编辑」。不提供时，需要你先把两个域名的 A 记录以**灰云**指向 VPS，部署完再手动切橙云。

## 使用

```bash
curl -fsSLO https://raw.githubusercontent.com/wangxvwei/3x-ui-oneclick/main/deploy-vps.sh
bash deploy-vps.sh
```

脚本会逐项询问参数，也可以用环境变量预填（适合无人值守）：

| 变量 | 说明 |
| --- | --- |
| `CDN_DOMAIN` / `PANEL_DOMAIN` | 两个域名 |
| `REALITY_SNI` / `REALITY_SNI_BACKUP` | REALITY 目标；留空则自动扫描挑选 |
| `CLIENTS` | 用户名，逗号分隔 |
| `PANEL_USER` / `PANEL_PASS` | 面板账号密码（密码至少 10 位） |
| `PANEL_PATH` / `SUB_PATH` / `XHTTP_PATH` / `TRUST_HEADER` | 不填则运行时选择，默认随机 |
| `ACME_EMAIL` | Let's Encrypt 邮箱 |
| `CF_API_TOKEN` | 可选，Cloudflare 自动化 |
| `SSH_PUBKEY` | 可选，加入 `authorized_keys` |
| `XUI_VERSION` | 3x-ui 版本，默认 `v3.11.0` |

部署完成后：

```bash
cat /root/deploy-summary.txt   # 面板地址、SublinkX 接入信息、各用户订阅链接（权限 600）
```

## 部署后建议

1. 面板「面板设置 → 安全」开启两步验证。
2. 确认能用 SSH 密钥登录后，关闭密码登录：
   ```bash
   printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/10-key-only.conf
   sshd -t && systemctl reload ssh
   ```
3. 每两周检查一次 REALITY 目标：`/usr/local/x-ui/bin/xray-linux-amd64 tls ping <目标域名>`。

## 注意事项

- 只用于**全新机器**：检测到已安装 3x-ui 会直接退出。
- 换 REALITY 目标时，只改「入站 → 安全 → REALITY」的 Target 和 Server Names；不要给 REALITY 入站添加「主机」记录或「外部代理」，否则订阅会一直发写死的旧 SNI。
- 3x-ui 自身行为随版本变化；脚本在 3x-ui v3.11.0 上验证过入站创建和订阅导出。

## 免责声明

本项目仅供学习与在合法合规的前提下自用。请遵守你所在地及服务器所在地的法律法规，以及 VPS 服务商的服务条款。
