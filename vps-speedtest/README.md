# 美国 VPS 测速脚本

在**你自己的网络**上（比如手机 Termux）测试各家美国 VPS 机房的延迟、丢包和下载速度。
只用 Python 标准库，不需要装别的东西。

- 所有机房**同时**测延迟，几秒钟就测完
- 只对延迟最低的前 8 个做下载测速，每个最多 5 秒
- 每次连接都有超时限制，失效的地址直接标记失败，不会卡住
- 结果自动存成 CSV，可以比较晚高峰和白天的数据

## 在 Termux 里运行

```bash
pkg install -y python curl            # 只需第一次
mkdir -p ~/vps-speedtest && cd ~/vps-speedtest
curl -fsSLO https://raw.githubusercontent.com/lxlotus/Lotus/claude/default-environment-capabilities-s8omfr/vps-speedtest/vps_speedtest.py
python vps_speedtest.py
```

> ⚠️ **测之前先关掉 Clash / v2ray 等代理或 VPN。** 不然测到的是代理节点的数据。
> 如果有域名被解析成 `198.18.x.x`（Fake-IP），脚本会提醒你。

## 常用参数

| 命令 | 作用 |
|---|---|
| `python vps_speedtest.py --no-download` | 只测延迟，十几秒就能出结果 |
| `python vps_speedtest.py --only vultr racknerd` | 只测某几家 |
| `python vps_speedtest.py --label peak` | 给结果文件加后缀，方便区分 |
| `python vps_speedtest.py --count 20` | 每个机房连 20 次，结果更稳 |
| `python vps_speedtest.py --dl-top 3 --dl-seconds 8` | 只对前 3 名做下载测速，每个测 8 秒 |
| `python vps_speedtest.py --compare results/A.csv results/B.csv` | 对比两次结果 |

## 晚高峰对比

```bash
# 白天或凌晨跑一次
python vps_speedtest.py --label offpeak
# 晚上 8–11 点再跑一次
python vps_speedtest.py --label peak
# 对比
python vps_speedtest.py --compare results/*-offpeak.csv results/*-peak.csv
```

（每种标签各保留一个文件时，上面的通配符正好匹配两个文件；如果有多个，就手动写出完整文件名。）

## 添加或替换测试点

内置测试点来自各家公开的 Looking Glass 或测速服务器，**没有逐一验证过**。
可以写一个 JSON 文件追加测试点（`paths` 可省略，省略时会自动尝试 `/100MB.test`、`/10mb.test` 等常见路径）：

```json
[
  {"name": "RackNerd-LAX03", "host": "lg-lax03.racknerd.com"},
  {"name": "Foo-LA", "host": "lg.example.com", "paths": ["/100MB.bin"]}
]
```

```bash
python vps_speedtest.py --targets my_targets.json                    # 追加（同名的会覆盖）
python vps_speedtest.py --targets my_targets.json --replace-targets  # 只测文件里的
```

## 怎么看结果

- **中位延迟**：TCP 建立连接的时间，跟 ping 差不多。到美国西海岸，优化线路一般在 130–180ms，普通线路一般在 180–250ms 以上。
- **抖动**：延迟的波动程度，越小越稳定。
- **丢包**：连接失败的比例。晚高峰明显上升，说明这条线路高峰期拥堵。
- **下载**：单线程下载速度。手机信号和套餐本身也会影响这个数字，所以主要用来横向比较各机房。
- 测试服务器的线路**不一定**和你实际买到的 VPS 一样（尤其是有 CN2 GIA 等优化线路的套餐），结果只能当参考。
