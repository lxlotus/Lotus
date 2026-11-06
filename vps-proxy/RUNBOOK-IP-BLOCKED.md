# IP 被墙了怎么办（操作手册）

给 Lotus 本人，也给以后接手的 AI（GPT / Codex / Claude Code）。

**约定**：遇到 IP 被墙，先按本文的方法处理；本文的方法走不通，再用自己的办法，并把新发现补进本文末尾的「踩坑记录」。

Lotus 只用手机（Termux），没有电脑；他看不懂代码，只认几个简单英文。给他的每一步都要能直接复制粘贴，别让他手改长命令。

## 1. 先确认是不是真被墙

症状（出现任意几个）：

- Clash Meta 里自建节点连不上，商业代理能上
- Lab → Activity → IP 页：出口不是自建服务器的 IP，或 Exit check 显示 Mismatch
- Lab → Activity → VPS 页：`SSH blocked` / `Timed out` / `Monitor offline`，下面的数字是几小时前的缓存（**只有这一条、代理照常能用** → 多半不是被墙，先看 1.5）
- Termux 里 `ssh root@服务器IP` 超时

确认方法：用 itdog.cn 的「在线Tcping」测 **`IP:443`**（或 22）。国内节点基本全部超时，就是被墙了。

**区分「IP 被墙」和「线路抽风」**：

- 在 itdog 用「在线Ping」测服务器 IP。国内节点**基本全部超时**（几乎 100%），才是 IP 被墙
- 自建和商业代理的美国节点**同时**连不上，但自建 IP 的 ping 大部分能通（只有零星超时）→ 是国内到美国的线路问题，不是 IP。**别急着重开机，等几小时**，通常自己会恢复
- 2026-10-29 实例：旧机 ping 317 个节点全超时（被墙），新机只有 35 个超时（正常）

> ⚠️ 不要测 80 端口。ufw 只放行 22 和 443，80 本来就不通，全红不能说明被墙。（2026-10-26 当天就测了 80，白看了半天。）

## 1.5 不是被墙：代理能用，只有 SSH 连不上

症状：Clash 里自建节点照常能用，IP 页正常；但 VPS 页是 `Monitor offline` / `SSH unreachable`（3.0.8 及以前写作 `SSH blocked`），数字停在几小时或几天前；Termux 里 `ssh root@服务器IP` 也连不上。

**先从国外测 22 端口**（App 3.0.9 起，VPS 页红框下面的 **Test port 22 from abroad** 直接打开它）：

```
https://check-host.net/check-tcp?host=服务器IP:22
```

- **国外也几乎全红（`Connection refused`）** → 不是墙，是服务器上的 SSH 自己停了。按下面修，**不要开新机**
- **国外大多是绿的，只有国内不通** → 是国内把 22 封了。代理没事就先不动；要恢复 SSH，给 sshd 加一个别的端口（再找 AI 做）

### SSH 自己停了的修法（Vultr 网页控制台，不用 SSH）

1. Vultr → Products → 点这台服务器；Overview 页里 **Password** 旁边点复制
2. 右上角显示器图标 **View Console**；输 `root` 回车，粘贴密码回车（不显示是正常的）
3. 先看状态（粘贴一行回车）：

```bash
systemctl is-active ssh ssh.socket
```

两行分别是 `inactive` 和 `failed`，就是 2026-11-06 那次的情况。

4. 修（改用常驻的 ssh.service，粘贴一行回车）：

```bash
systemctl disable --now ssh.socket; systemctl enable --now ssh; systemctl is-active ssh
```

最后一行出 `active` 就好了。再用 check-host 测一次应全绿；回 App 的 VPS 页点刷新，数字回来（配对不用重做，主机指纹没变）。

> 控制台里粘贴命令时竖线 `|` 可能会变形（2026-11-06 出现过），给 Lotus 的控制台命令里**不要用 `|`**，用 `;` 分开。

**原因（2026-11-06 查明）**：这台机器内核里 IPv6 是关着的（`/proc/sys/net/ipv6` 不存在）。Ubuntu 24.04 默认用 `ssh.socket` 替 sshd 开 22 端口，它要同时开 IPv4 和 IPv6，没有 IPv6 就以 `Failed with result 'resources'` 失败，22 端口没人接，全世界都是 refused。sshd 配置本身是好的（`sshd -t` 无报错）。改成 ssh.service 后 sshd 自己开端口，没有 IPv6 也能只开 IPv4，以后重启也不会再犯。`install.sh`（2026-11-06 起）装机时就会改用 ssh.service。

## 2. 开新机（按小时计费，几美分）

1. Vultr 开一台新机，洛杉矶（或别的机房），Ubuntu 24.04，选上 SSH Key
2. Cloud-Init User Data 用 [README.md](README.md)「方式 A」里那段，`NODE_NAME` 保持 `Vultr-LA`
3. **先别急着用**。机器 Running 后，拿到新 IP，立刻用 itdog 测 `新IP:22`。国内通 → 留下；不通 → 直接 Destroy 重开换 IP，别往下装
4. 等 3–5 分钟装完，Termux 里取配置：

```bash
ssh root@新IP 'bash /root/install.sh --show'
```

第一次连会问 `yes/no`，输 `yes`。

### 2.1 更省事的开新机法：用快照（推荐，需提前拍好）

平时在一台**确认稳定**的机器上拍一张快照（Vultr → Snapshots，按存储量收费，几毛钱一个月，价格以 Vultr 页面为准）。以后被墙：

1. Vultr 用快照开新机（同样先用 itdog 测新 IP 的 22 端口，通才留）
2. 快照里已有 sing-box、密钥和配置，**不用重装**。只需让脚本按新 IP 刷新配置（密钥不变）：

```bash
ssh root@新IP 'bash /root/install.sh'
```

3. 取回 Clash 配置（脚本每次运行都会按当前公网 IP 重写它）：

```bash
termux-setup-storage
scp root@新IP:/root/flclash.yaml ~/storage/downloads/
```

4. Clash Meta 导入 `Download/flclash.yaml` 并选中，然后继续做第 3 节里的 3.2、3.3

注意：快照里是拍摄时的脚本版本；SSH 主机密钥也一起带过来了，所以 VPS 页配对时的指纹不变，但 IP 变了仍需重新配对（3.3）。

## 3. 更新手机上的三处

### 3.1 Clash Meta 节点

把新机的配置（`/root/flclash.yaml` 或 `vless://` 链接）导入，选中新节点。节点里的 server 必须是新 IP。

### 3.2 Lab 的 IP 页（出口预期 IP）

IP 页的 Mismatch 是因为后端还记着旧 IP。在 Termux 里改（把 `新IP` 换成真实 IP）：

```bash
sed -i 's/"PROXY_EXPECTED_IP": *"[^"]*"/"PROXY_EXPECTED_IP": "新IP"/' ~/.config/lotus-ip-monitor/config.json
grep PROXY_EXPECTED_IP ~/.config/lotus-ip-monitor/config.json
```

第二行应显示新 IP。**然后必须重启 Lab 后端**（关掉 Termux 里跑 Lab 的会话再重开，或用平时的启动命令重启）：后端只在启动时读一次这个配置，不重启的话 IP 页会一直显示 Mismatch（Refresh attribution 也没用）。重启后回 App 的 IP 页看，应变绿。这一项只影响状态灯，不影响代理本身。

### 3.3 Lab 的 VPS 页（重新配对）

VPS 页是 App 直接 SSH 到服务器读状态，服务器换了就必须重新配对：

1. VPS 页 → 点 **Monitor** 一行 → **Direct connection**，先点 **Forget**（忘掉旧机）
2. 点 **Copy command**。这条命令里还是旧 IP，**不要手改**，在 Termux 里这样做：

```bash
cat > ~/p.sh
```

粘贴命令，回车，再按 **Ctrl+D**。然后：

```bash
sed -i 's/旧IP/新IP/' ~/p.sh && bash ~/p.sh
```

3. 脚本最后会打印一行 `lotus-vps://lotusmon@新IP:22#SHA256:…`。复制它，回 App 点 **Paste → Connect**
4. 页面出现 `Healthy` 就成功

**自检偶尔会失败一次**：最后一步 `统计脚本运行失败`，是因为 vnstat 刚装好还没数据，脚本本身没问题（可手动验证：`ssh root@新IP 'runuser -u lotusmon -- /usr/local/bin/lotus-vps-stats'` 应输出一行 JSON）。失败时不会打印配对行，**直接再跑一遍 `bash ~/p.sh` 即可**（可重复运行）。

## 4. 收尾

- Vultr 里把旧机 **Destroy**（关机也收费）
- Exit match 灰着没关系，在 IP 页刷新一次测到出口后会自动变 verified

## 5. 备用方案（建议常备）

- Clash Meta 里**保留商业代理节点**当「找 Claude 的专线」：偶尔上来求救、聊几句没问题；它是上千人共用的出口，**不要长期用它登录 ChatGPT / Claude 账号**（验证多，风控风险高）
- 自建挂了就手动切到商业节点；平时账号类流量只走自建的独享 IP
- 低成本的「备用线路」：给稳定的那台拍快照（见 2.1），不要常开第二台机器（每月多花几美元），也不要「关机放着」（Vultr 关机照样收费）
- 想更稳：另备一台不同机房的小 VPS，主节点挂了再开

## 6. 踩坑记录

| 日期 | 情况 | 结论 |
|---|---|---|
| 2026-10-26 | 旧机 144.202.127.142 下午起国内全超时 | 新机 149.28.69.76 重建，约 20 分钟恢复；按本文 3.1–3.3 全部重做 |
| 2026-10-26 | itdog 测 80 端口全红 | 80 没开放，应测 443/22 |
| 2026-10-26 | VPS 页重新配对时自检失败一次 | vnstat 刚装好，再跑一遍即通 |
| 2026-10-26 | 改了 `PROXY_EXPECTED_IP` 后 IP 页仍是 Mismatch | 后端只在启动时读配置，需重启 Lab 后端（10-29 重启后恢复） |
| 2026-10-29 | 早上自建和商业美国节点同时连不上，下午自行恢复 | 当时先判成线路问题，后测 ping 发现旧机确实全超时（被墙），新机正常；以 ping 结果为准，别凭感觉 |
| 2026-10-29 | 旧机 149.28.69.76 被墙，换到 149.28.95.214 | 按本文 3.1–3.3 重做，旧机已 Destroy |
| 2026-11-04 → 11-06 | VPS 页 `SSH blocked` 两天，代理一直正常；当时以为是国内封了 22 | check-host 国外也全 `refused`：其实是 ssh.socket 因 IPv6 被关而失败（`resources`），SSH 根本没在听。Vultr 控制台改用 ssh.service 后恢复，见 1.5。先测国外，别先猜墙 |

> 补充规则：每次被墙处理完，往上表加一行；链接、密钥、配对码不要写进仓库。
