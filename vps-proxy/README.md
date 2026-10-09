# VPS 一键部署：安全稳定的私人代理

脚本 `install.sh` 会在一台全新的 Debian 12 / Ubuntu 24.04 VPS 上完成：

| 项目 | 做了什么 | 为什么 |
|---|---|---|
| 代理 | sing-box + **VLESS + Reality**，TCP 443 | 流量看起来像在访问正常的 HTTPS 网站，抗封锁好，密钥认证 |
| 加速 | 开启 BBR | 跨太平洋长距离传输更快、更稳 |
| 防火墙 | ufw 只放行 SSH 和 443 | 不暴露多余端口 |
| SSH | 关闭密码登录，只允许密钥（前提是已配置 SSH Key） | 杜绝密码爆破 |
| 防爆破 | fail2ban | 自动封禁暴力尝试 SSH 的 IP |
| 更新 | 自动安装系统安全更新 | 长期无人值守也能及时打补丁 |

重复运行不会改变密钥，手机上的配置一直有效。

## 部署前准备（只做一次）

在 Termux 里生成 SSH 密钥，并把**公钥**加到 Vultr：

```bash
pkg install -y openssh
ssh-keygen -t ed25519 -C "vultr-la"   # 一路回车
cat ~/.ssh/id_ed25519.pub             # 复制这一行 → Vultr「SSH Keys」→ Add SSH Key
```

> ⚠️ 只复制 `.pub` 结尾的公钥。`~/.ssh/id_ed25519` 是私钥，不要发给任何人。

## 方式 A：开机自动部署（推荐）

在 Vultr 创建机器时：

1. **SSH Keys** 选上刚才添加的密钥
2. 打开 **Cloud-Init User Data**，粘贴下面整段：

```bash
#!/bin/bash
curl -fsSL https://raw.githubusercontent.com/lxlotus/Lotus/claude/default-environment-capabilities-s8omfr/vps-proxy/install.sh -o /root/install.sh
NODE_NAME=Vultr-LA bash /root/install.sh > /var/log/proxy-install.log 2>&1
```

3. 部署。机器显示 Running 后等 **3–5 分钟**（脚本在后台更新系统、安装软件）
4. 在 Termux 里取回配置：

```bash
ssh root@你的服务器IP 'bash /root/install.sh --show'
```

如果提示找不到文件，说明还没装完，等一会儿再试；或者看进度：
`ssh root@你的服务器IP tail -20 /var/log/proxy-install.log`

## 方式 B：手动运行

机器建好后：

```bash
ssh root@你的服务器IP
curl -fsSL https://raw.githubusercontent.com/lxlotus/Lotus/claude/default-environment-capabilities-s8omfr/vps-proxy/install.sh -o install.sh
NODE_NAME=Vultr-LA bash install.sh
```

跑完会直接显示链接和二维码。

## 导入手机客户端

输出里有三种格式，选你用的客户端对应的那种：

- `vless://...` 一整行 → v2rayNG、NekoBox、Shadowrocket、Hiddify 等：复制后在客户端里「从剪贴板导入」，或扫二维码
- `- name: ...` 那一段 → Clash Meta / mihomo 系（FlClash、Clash Verge Rev 等）：粘贴到配置文件的 `proxies:` 下面

> 链接等同于密码，不要截图发到群里或发给别人。

## 部署后检查

1. 用 [itdog.cn](https://www.itdog.cn/ping/) 等国内多节点 ping 工具测服务器 IP：
   - 国内大部分节点能通 → 正常
   - 国内全部不通、国外能通 → IP 被墙，在 Vultr 删掉重建换个 IP（按小时计费，只花几美分）
2. 客户端连上后打开网页、测速，看是否正常

## 常用命令（在服务器上）

| 命令 | 作用 |
|---|---|
| `bash install.sh --show` | 再次查看链接 |
| `bash install.sh` | 修复 / 重装（密钥不变） |
| `bash install.sh --reset` | 重新生成密钥（链接泄露时用，旧配置失效） |
| `systemctl status sing-box` | 查看代理运行状态 |
| `apt update && apt upgrade -y` | 手动升级（包括 sing-box） |

## 可选：Hysteria2 备用协议

默认只开 Reality（越少越安全）。如果以后遇到 TCP 被干扰、速度很差，可以额外开启 UDP 协议 Hysteria2：

```bash
ENABLE_HY2=1 bash install.sh
```

注意：中国移动对 UDP 有时会限速，Hysteria2 不一定更快，作为备用即可。

## 换机房 / 备用节点

在 Vultr 开一台硅谷或西雅图的机器，同样的方式部署，`NODE_NAME` 改成 `Vultr-SJC` 之类即可。
记得：Vultr **关机也收费**，不用的机器要 Destroy。
