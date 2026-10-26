# IP 被墙了怎么办（操作手册）

给 Lotus 本人，也给以后接手的 AI（GPT / Codex / Claude Code）。

**约定**：遇到 IP 被墙，先按本文的方法处理；本文的方法走不通，再用自己的办法，并把新发现补进本文末尾的「踩坑记录」。

Lotus 只用手机（Termux），没有电脑；他看不懂代码，只认几个简单英文。给他的每一步都要能直接复制粘贴，别让他手改长命令。

## 1. 先确认是不是真被墙

症状（出现任意几个）：

- Clash Meta 里自建节点连不上，商业代理能上
- Lab → Activity → IP 页：出口不是自建服务器的 IP，或 Exit check 显示 Mismatch
- Lab → Activity → VPS 页：`SSH blocked` / `Timed out` / `Monitor offline`，下面的数字是几小时前的缓存
- Termux 里 `ssh root@服务器IP` 超时

确认方法：用 itdog.cn 的「在线Tcping」测 **`IP:443`**（或 22）。国内节点基本全部超时，就是被墙了。

> ⚠️ 不要测 80 端口。ufw 只放行 22 和 443，80 本来就不通，全红不能说明被墙。（2026-10-26 当天就测了 80，白看了半天。）

## 2. 开新机（按小时计费，几美分）

1. Vultr 开一台新机，洛杉矶（或别的机房），Ubuntu 24.04，选上 SSH Key
2. Cloud-Init User Data 用 [README.md](README.md)「方式 A」里那段，`NODE_NAME` 保持 `Vultr-LA`
3. **先别急着用**。机器 Running 后，拿到新 IP，立刻用 itdog 测 `新IP:22`。国内通 → 留下；不通 → 直接 Destroy 重开换 IP，别往下装
4. 等 3–5 分钟装完，Termux 里取配置：

```bash
ssh root@新IP 'bash /root/install.sh --show'
```

第一次连会问 `yes/no`，输 `yes`。

## 3. 更新手机上的三处

### 3.1 Clash Meta 节点

把新机的配置（`/root/flclash.yaml` 或 `vless://` 链接）导入，选中新节点。节点里的 server 必须是新 IP。

### 3.2 Lab 的 IP 页（出口预期 IP）

IP 页的 Mismatch 是因为后端还记着旧 IP。在 Termux 里改（把 `新IP` 换成真实 IP）：

```bash
sed -i 's/"PROXY_EXPECTED_IP": *"[^"]*"/"PROXY_EXPECTED_IP": "新IP"/' ~/.config/lotus-ip-monitor/config.json
grep PROXY_EXPECTED_IP ~/.config/lotus-ip-monitor/config.json
```

第二行应显示新 IP。回 App 的 IP 页点刷新（或详情里 Refresh attribution）。这一项只影响状态灯，不影响代理本身。

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
- 想更稳：另备一台不同机房的小 VPS（平时关机或不建），主节点挂了直接开

## 6. 踩坑记录

| 日期 | 情况 | 结论 |
|---|---|---|
| 2026-10-26 | 旧机 144.202.127.142 下午起国内全超时 | 新机 149.28.69.76 重建，约 20 分钟恢复；按本文 3.1–3.3 全部重做 |
| 2026-10-26 | itdog 测 80 端口全红 | 80 没开放，应测 443/22 |
| 2026-10-26 | VPS 页重新配对时自检失败一次 | vnstat 刚装好，再跑一遍即通 |

> 补充规则：每次被墙处理完，往上表加一行；链接、密钥、配对码不要写进仓库。
