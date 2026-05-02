<h1 align="center">cloudflare-cn-kit (cfcn)</h1>
<p align="center">
  <b>面向中国/香港运维的 Cloudflare CLI · 含最常见的 Flexible-SSL 重定向死循环诊断</b><br/>
  <sub>An opinionated Cloudflare CLI for China / HK operators — with a built-in diagnostic for the #1 "my site broke after moving to CF" bug.</sub>
</p>

<p align="center">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square" alt="MIT"/></a>
  <img src="https://img.shields.io/badge/shell-bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white" alt="Bash"/>
  <img src="https://img.shields.io/badge/API-scoped_token-F38020?style=flat-square&logo=cloudflare&logoColor=white" alt="Scoped Token"/>
  <img src="https://img.shields.io/badge/status-v0.1.3-0A66C2?style=flat-square" alt="Version"/>
</p>

---

## 它为什么存在 · Why this exists

Cloudflare 官方有 `flarectl` 和 `cloudflared`，但它们面向欧美场景，不会告诉你：

1. 你的 **Flexible SSL + 源站 301 跳 HTTPS = 无限重定向** — 这是中国大陆运维最常撞的墙，`cfcn ssl diag` 一条命令告诉你是不是踩了这个坑。
2. 你的 CF 面板从中国看过去常常是 504，但 API 是通的 —— `cfcn` 全程走 API，不用翻。
3. 批量操作域名（10+ 个 zone 一起改）和 `*.xxx.com` 泛解析在 CF 后台都是鼠标戳到死的操作。
4. 国内 ISP 各节点的真实连通性，得看 itdog / chinaz，而不是你 laptop 上的 `ping`。

这套 CLI 把这些场景一次写完，全部走 scoped API token（不是上古的 `X-Auth-Key`）。

---

## 30 秒上手 · 30-second start

```bash
# 1. 装（zero-build，默认安装到 ~/.local/bin/cfcn）
curl -fsSL https://raw.githubusercontent.com/tianmind-studio/cloudflare-cn-kit/main/install.sh | bash

# 如果 ~/.local/bin 还没进 PATH：
export PATH="$HOME/.local/bin:$PATH"

# 2. 拿一个 scoped token
# https://dash.cloudflare.com/profile/api-tokens  → Create Token
# 推荐最小权限：Zone:Zone:Read + Zone:DNS:Edit（限定到你要动的 Zone）
export CFCN_TOKEN="***"

# 3. 验证
cfcn doctor

# 4. 看看你当前所有 zone 的 SSL 模式
cfcn zone list

# 5. 最核心的用例 —— 诊断那个死循环
cfcn ssl diag example.com
```

---

## 命令速查 · Command reference

**Zone 级**：

| 命令 | 作用 |
|------|------|
| `cfcn zone list` | 列你能访问的全部 zone + SSL 模式 |
| `cfcn zone show <name>` | 单个 zone 详情（SSL / HSTS / name servers） |
| `cfcn zone ssl <name> [mode]` | 读或改 SSL 模式（off/flexible/full/strict） |
| `cfcn zone purge <name> [host]` | 清缓存（默认全清；可指定 hostname） |

**DNS**：

| 命令 | 作用 |
|------|------|
| `cfcn dns list [zone]` | 列 DNS 记录（不给 zone 会遍历全部） |
| `cfcn dns add <fqdn> <ip> [--proxied]` | 新增或 upsert A 记录（**自动推断 zone**） |
| `cfcn dns del <fqdn>` | 删 A 记录 |
| `cfcn dns bulk <yaml>` | YAML 批量上人（见 `examples/bulk-dns.yaml`） |
| `cfcn dns diff <yaml>` | 预览 `dns bulk <yaml>` 会改什么（只读，不写） |
| `cfcn dns wildcard <domain> <ip>` | 创建 `*.domain` A 记录（多租户 SaaS 常用） |
| `cfcn dns export <zone> [--out f]` | 导出整个 zone 的 DNS 为 `dns bulk` 兼容 YAML |

**SSL / HTTPS**：

| 命令 | 作用 |
|------|------|
| `cfcn ssl diag <domain> [--origin-ip <ip>]` | ⭐ **区分 Cloudflare Edge 与源站直连，诊断 Flexible-SSL 循环、证书和中国 ISP 000 返回** |
| `cfcn ssl mode <zone> [mode]` | 设 SSL 模式（`zone ssl` 别名） |
| `cfcn ssl hsts <zone> [on/off]` | 切 HSTS（小心，一开难撤） |

**CN 观测**：

| 命令 | 作用 |
|------|------|
| `cfcn cn ping <host>` | 本地 ping + 推荐 itdog/chinaz 全国探针 |
| `cfcn cn trace <host>` | 本地 mtr/traceroute + ipip.net 国内起点 |

**其它**：`cfcn doctor` / `cfcn version` / `cfcn --help`。

---

## 核心用例：诊断 Flexible SSL 死循环 · The killer feature

这是这个工具存在的最大理由。**强烈建议每次新站上线后都跑一遍 `cfcn ssl diag`。**

```
$ cfcn ssl diag example.com

==> SSL diagnosis: example.com
    zone:      example.com
    ssl mode:  flexible
    proxied:   true
    probing edge and origin...
    Edge HTTP/80:       301
    Edge HTTPS/443:     301
    Edge HTTPS with -L: 000  (up to 10 redirects)
    origin IP:          203.0.113.10 (DNS A)
    Origin HTTP/80:     301
    Origin HTTPS/443:   000
==> Diagnosis
warn: SSL mode is 'flexible' AND DNS is proxied.
→ This is the classic Flexible-SSL redirect loop setup.
→   - CF talks to your origin over HTTP, but your origin (nginx)
→     redirects HTTP to HTTPS. CF receives the 301, redirects the
→     client, client loops.
warn: direct origin HTTP redirects, but direct origin HTTPS is unreachable.
→ Likely origin has no valid cert installed while nginx force-redirects to HTTPS.
→   - If using CF Flexible: DON'T redirect on origin. Let CF redirect.
→   - If using CF Full/Strict: install or renew an origin cert.
```

完整原理和两种修法见 [`docs/flexible-ssl-loop.md`](./docs/flexible-ssl-loop.md)。如果 DNS 是 proxied CNAME、负载均衡或多源站，`cfcn` 无法可靠从 Cloudflare 记录反推出源站 IP；这时用 `cfcn ssl diag <domain> --origin-ip <ip>` 指定一次性直连探测地址。

---

## 批量 DNS · Bulk DNS

给 YAML，一口气推：

```yaml
# bulk-dns.yaml
records:
  - name: app1.example.com
    ip: 10.0.0.10
  - name: app2.example.com
    ip: 10.0.0.11
    proxied: true
  - name: api.example.com
    ip: 10.0.0.12
    proxied: true
```

```bash
cfcn dns diff bulk-dns.yaml             # 看清楚会改什么（推荐，输出带颜色）
cfcn --dry-run dns bulk bulk-dns.yaml   # 或者走 dry-run 路径
cfcn dns bulk bulk-dns.yaml             # 真的跑
```

`dns diff` 输出：

```
+ api.example.com    10.0.0.12 (proxied=true)            # 会创建
~ app1.example.com   10.0.0.10 (proxied=false)  ->  10.0.0.20 (proxied=false)   # 会更新
= app2.example.com   10.0.0.11 (proxied=true)            # 不变
. legacy.example.com 10.0.0.99 (proxied=false)  (unmanaged — dns bulk will not touch)

summary: 1 create, 1 update, 1 unchanged, 1 unmanaged
```

多租户 SaaS 泛解析一条命令：

```bash
cfcn dns wildcard saas.example.com 203.0.113.10
# 会创建 *.saas.example.com A 记录
```

---

## 设计原则 · Design

1. **只用 scoped token**。最小权限 `Zone:Zone:Read + Zone:DNS:Edit`。`X-Auth-Key` 彻底不支持。
2. **FQDN 自动推断 zone**。`cfcn dns add blog.foo.bar.com 1.2.3.4` 自动找到 `bar.com` 或 `foo.bar.com`（哪个是 zone 就用哪个）。
3. **`--dry-run` 普遍覆盖**。所有写操作都支持先预览。
4. **`--json` 机器可读**。列出类命令能直接给 jq 管。
5. **失败信息够具体**。API 报错会把 CF 原始 error message 吐出来，不藏。

---

## 安全边界与 token 权限 · Trust boundary

- `cfcn` 只接受 Cloudflare **scoped API token**：`CFCN_TOKEN` 优先，`CF_API_TOKEN` 作为兼容 fallback。不要给全局 API Key；本项目也不支持 `X-Auth-Key`。
- token 放在环境变量里，不会写入本仓库配置文件；运行日志和报错应避免打印 token 原文。
- 所有写操作都应该先用 `--dry-run` 或 `dns diff` 看清楚变更；`ssl diag`、`zone list/show`、`dns list/export/diff` 是读/诊断路径。
- 推荐按命令拆权限、按 zone 限定授权：
  - 读/诊断：`Zone:Zone:Read`、`Zone:DNS:Read`、`Zone Settings:Read`。
  - DNS 写入：再加 `Zone:DNS:Edit`。
  - SSL/HSTS 设置：再加 `Zone Settings:Edit`。
  - 清缓存：再加 `Cache Purge:Purge`。
- 如果你只想快速跑通 DNS 工作流，常用最小组合是 `Zone:Zone:Read + Zone:DNS:Edit`，并限定到目标 zone；不要把账号下所有 zone 都开放给一个日常 token。

---

## 系统要求

- Bash 4+、`curl`、`jq`、`awk`。Linux 通常自带 Bash 4+。
- macOS 自带 `/bin/bash` 仍是 3.2；请用 Homebrew 安装新版 Bash（`brew install bash`），并确保 `env bash` 能找到 Bash 4+。
- 一个 scoped Cloudflare API token（[这里创建](https://dash.cloudflare.com/profile/api-tokens)）。

---

## 和其它工具的关系

- 用 [`site-bootstrap`](https://github.com/tianmind-studio/site-bootstrap) 部站、用 `cfcn` 运维 CF。两者共享 `CF_API_TOKEN` 环境变量，不用重复配。
- 用 [`vps-init`](https://github.com/tianmind-studio/vps-init) 初始化 VPS、用 `cfcn ssl diag` 确认部署后 CF 端没问题。

## License

MIT © 2026 Tianmind Studio. See [LICENSE](./LICENSE).
