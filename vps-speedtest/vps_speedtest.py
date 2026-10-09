#!/usr/bin/env python3
"""美国 VPS 机房测速脚本（在本地网络上运行，例如 Termux）。

只用 Python 标准库。流程：
  1. 并发对所有机房做 TCP 连接延迟测试（多次取中位数、抖动、丢包）
  2. 对延迟最低的若干机房依次做限时下载测速
  3. 输出排序表格，并把结果存成 CSV，方便晚高峰前后对比

用法示例：
  python vps_speedtest.py                 # 完整测试
  python vps_speedtest.py --no-download   # 只测延迟
  python vps_speedtest.py --only vultr    # 只测名字里含 vultr 的
  python vps_speedtest.py --compare results/a.csv results/b.csv
"""

import argparse
import concurrent.futures as cf
import csv
import datetime as dt
import ipaddress
import json
import os
import socket
import statistics
import sys
import time
import unicodedata
import urllib.error
import urllib.request

# 测试点列表。"ip" 是官方公布或已实测过的测试 IP：DNS 失败或被解析成 Fake-IP 时用它。
# 失效的会在结果里标记出来，可以用 --targets 追加或替换。
# DigitalOcean 的 speedtest-sfoX 域名和 RackNerd LAX02 已 NXDOMAIN，不再内置。
DEFAULT_PATHS = ["/100MB.test", "/100mb.test", "/10MB.test", "/10mb.test"]

TARGETS = [
    # Vultr（西海岸为主要候选，东部/中部作参照）
    {"name": "Vultr-LosAngeles", "host": "lax-ca-us-ping.vultr.com", "ip": "108.61.219.200",
     "paths": ["/vultr.com.100MB.bin"]},
    {"name": "Vultr-SiliconValley", "host": "sjo-ca-us-ping.vultr.com", "paths": ["/vultr.com.100MB.bin"]},
    {"name": "Vultr-Seattle", "host": "wa-us-ping.vultr.com", "ip": "108.61.194.105",
     "paths": ["/vultr.com.100MB.bin"]},
    {"name": "Vultr-Dallas", "host": "tx-us-ping.vultr.com", "paths": ["/vultr.com.100MB.bin"]},
    {"name": "Vultr-NewJersey", "host": "nj-us-ping.vultr.com", "paths": ["/vultr.com.100MB.bin"]},
    # RackNerd（IP 来自官方 DC-03 机房页）
    {"name": "RackNerd-LAX03", "host": "lg-lax03.racknerd.com", "ip": "107.174.51.158"},
    # CloudCone（旧 LG 会 301 跳到新地址）
    {"name": "CloudCone-LA", "host": "lg-la.us.cloudc.one"},
    {"name": "CloudCone-LA-old", "host": "la.lg.cloudc.one", "ip": "185.206.180.179"},
]

# 到美国的真实 RTT 不可能低于这个值；更低说明 VPN/TUN 在本地代答了 TCP 握手
MIN_PLAUSIBLE_MS = 50

FAKE_IP_NET = ipaddress.ip_network("198.18.0.0/15")  # Clash / sing-box 等 Fake-IP 常用网段
USER_AGENT = "Mozilla/5.0 (vps-speedtest)"

# 不走环境变量里的代理，保证测的是直连
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def resolve(host):
    try:
        infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
    except socket.gaierror:
        return None
    return infos[0][4][0] if infos else None


def tcp_ping(ip, port, count, interval, timeout):
    samples = []
    for i in range(count):
        start = time.perf_counter()
        try:
            with socket.create_connection((ip, port), timeout=timeout):
                samples.append((time.perf_counter() - start) * 1000)
        except OSError:
            pass
        if i < count - 1:
            time.sleep(interval)
    return samples


def ping_target(t, args):
    r = {"name": t["name"], "host": t["host"], "ip": "", "port": "", "sent": args.count,
         "ok": 0, "loss_pct": 100.0, "min_ms": None, "median_ms": None, "jitter_ms": None,
         "mbps": None, "note": ""}
    ip = resolve(t["host"])
    if ip and ipaddress.ip_address(ip) in FAKE_IP_NET:
        r["fake_ip"] = True
        if t.get("ip"):
            ip, r["note"] = t["ip"], "Fake-IP，已改用内置 IP"
        else:
            r["note"] = "Fake-IP! 请关闭代理后重测"
    elif not ip:
        if not t.get("ip"):
            r["note"] = "DNS 解析失败"
            return r
        ip, r["note"] = t["ip"], "DNS 失败，已改用内置 IP"
    r["ip"] = ip
    # 先用 80 端口，不通再试 443
    for port in (80, 443):
        samples = tcp_ping(ip, port, args.count, args.interval, args.timeout)
        if samples:
            break
    if not samples:
        r["note"] = r["note"] or "TCP 连接全部失败"
        return r
    r["port"] = port
    r["ok"] = len(samples)
    r["loss_pct"] = round(100 * (1 - len(samples) / args.count), 1)
    r["min_ms"] = round(min(samples), 1)
    r["median_ms"] = round(statistics.median(samples), 1)
    r["jitter_ms"] = round(statistics.pstdev(samples), 1) if len(samples) > 1 else 0.0
    if r["median_ms"] < MIN_PLAUSIBLE_MS:
        r["tun"] = True
        r["note"] = (r["note"] + "; " if r["note"] else "") + "延迟不真实(VPN?)"
    return r


def download_speed(t, args):
    """返回 (Mbps, 备注)。读到时间或字节上限就停，不需要下完整个文件。"""
    paths = t.get("paths") or DEFAULT_PATHS
    max_bytes = args.dl_mb * 1024 * 1024
    last_err = "无可用测速文件"
    for path in paths:
        for scheme in ("http", "https"):
            url = f"{scheme}://{t['host']}{path}"
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            try:
                resp = OPENER.open(req, timeout=args.timeout + 2)
            except urllib.error.HTTPError as e:
                last_err = f"HTTP {e.code}"
                break  # 文件不存在，换下一个路径
            except (urllib.error.URLError, OSError) as e:
                last_err = f"连接失败: {getattr(e, 'reason', e)}"
                continue  # 换 https 再试
            with resp:
                got = 0
                start = time.perf_counter()
                try:
                    while got < max_bytes and time.perf_counter() - start < args.dl_seconds:
                        chunk = resp.read(64 * 1024)
                        if not chunk:
                            break
                        got += len(chunk)
                except (OSError, socket.timeout) as e:
                    last_err = f"下载中断: {e}"
                elapsed = time.perf_counter() - start
            if got >= 256 * 1024 and elapsed > 0:
                return round(got * 8 / elapsed / 1e6, 1), f"{got // 1024 // 1024}MB/{elapsed:.1f}s"
            last_err = f"数据太少 ({got // 1024}KB)"
    return None, last_err


def check_proxy_env():
    keys = [k for k in ("http_proxy", "https_proxy", "all_proxy",
                        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY") if os.environ.get(k)]
    if keys:
        print(f"[提示] 检测到代理环境变量 {', '.join(keys)}，脚本已忽略它们走直连。")


def fmt(v, suffix=""):
    return "-" if v is None else f"{v}{suffix}"


def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def row(cells, widths):
    """按终端显示宽度对齐（中文占两格）。第一列左对齐，其余右对齐。"""
    out = []
    for i, (c, w) in enumerate(zip(cells, widths)):
        pad = " " * max(0, w - width(c))
        out.append(c + pad if i == 0 else pad + c)
    return "".join(out)


TABLE_W = [26, 10, 9, 9, 8, 12]
COMPARE_W = [24, 9, 9, 10, 8, 8, 9, 9, 10]


def print_table(results):
    print(row(["  # 机房", "中位延迟", "最低", "抖动", "丢包", "下载"], TABLE_W) + "  备注")
    print("-" * 90)
    for i, r in enumerate(results, 1):
        print(row([f"{i:>3} {r['name']}", fmt(r["median_ms"], "ms"), fmt(r["min_ms"], "ms"),
                   fmt(r["jitter_ms"], "ms"), fmt(r["loss_pct"], "%"), fmt(r["mbps"], "Mbps")],
                  TABLE_W) + f"  {r['note']}")


def sort_key(r):
    return (r["median_ms"] is None, r["median_ms"] or 0, r["loss_pct"])


FIELDS = ["name", "host", "ip", "port", "sent", "ok", "loss_pct", "min_ms",
          "median_ms", "jitter_ms", "mbps", "note"]


def save_csv(results, out_dir, label):
    os.makedirs(out_dir, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M")
    name = f"{stamp}-{label}.csv" if label else f"{stamp}.csv"
    path = os.path.join(out_dir, name)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        for r in results:
            w.writerow({k: ("" if r.get(k) is None else r[k]) for k in FIELDS})
    return path


def load_csv(path):
    with open(path, encoding="utf-8") as f:
        return {row["name"]: row for row in csv.DictReader(f)}


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def diff(a, b, suffix):
    if a is None or b is None:
        return "-"
    d = b - a
    return f"{'+' if d >= 0 else ''}{d:.1f}{suffix}"


def compare(path_a, path_b):
    a, b = load_csv(path_a), load_csv(path_b)
    print(f"A = {path_a}\nB = {path_b}\n")
    print(row(["机房", "延迟A", "延迟B", "变化", "丢包A", "丢包B", "下载A", "下载B", "变化"], COMPARE_W))
    print("-" * 96)
    for name in sorted(set(a) | set(b)):
        ra, rb = a.get(name, {}), b.get(name, {})
        la, lb = num(ra.get("median_ms")), num(rb.get("median_ms"))
        sa, sb = num(ra.get("mbps")), num(rb.get("mbps"))
        print(row([name, fmt(la), fmt(lb), diff(la, lb, "ms"),
                   fmt(num(ra.get("loss_pct")), "%"), fmt(num(rb.get("loss_pct")), "%"),
                   fmt(sa), fmt(sb), diff(sa, sb, "")], COMPARE_W))
    print("\n延迟单位 ms，下载单位 Mbps。延迟变化为正 = 变慢；下载变化为负 = 变慢。")


def load_targets(args):
    targets = list(TARGETS)
    if args.targets:
        with open(args.targets, encoding="utf-8") as f:
            extra = json.load(f)
        if args.replace_targets:
            targets = extra
        else:
            names = {t["name"] for t in extra}
            targets = [t for t in targets if t["name"] not in names] + extra
    if args.only:
        keys = [k.lower() for k in args.only]
        targets = [t for t in targets if any(k in t["name"].lower() or k in t["host"] for k in keys)]
    return targets


def main():
    p = argparse.ArgumentParser(description="美国 VPS 机房延迟与下载测速")
    p.add_argument("--count", type=int, default=10, help="每个机房 TCP 连接次数（默认 10）")
    p.add_argument("--interval", type=float, default=0.3, help="每次连接间隔秒数（默认 0.3）")
    p.add_argument("--timeout", type=float, default=2.0, help="单次连接超时秒数（默认 2）")
    p.add_argument("--no-download", action="store_true", help="跳过下载测速")
    p.add_argument("--dl-top", type=int, default=8, help="只对延迟最低的前 N 个做下载测速（默认 8）")
    p.add_argument("--dl-seconds", type=float, default=5, help="每个机房最多下载几秒（默认 5）")
    p.add_argument("--dl-mb", type=int, default=30, help="每个机房最多下载多少 MB（默认 30）")
    p.add_argument("--only", nargs="+", help="只测名字或域名含这些关键词的机房")
    p.add_argument("--targets", help="额外测试点 JSON 文件，格式同脚本里的 TARGETS")
    p.add_argument("--replace-targets", action="store_true", help="用 --targets 文件完全替换内置列表")
    p.add_argument("--label", default="", help="结果文件名后缀，例如 peak / offpeak")
    p.add_argument("--out", default="results", help="结果保存目录（默认 results）")
    p.add_argument("--compare", nargs=2, metavar=("A.csv", "B.csv"), help="对比两次测试结果")
    args = p.parse_args()

    if args.compare:
        compare(*args.compare)
        return

    targets = load_targets(args)
    if not targets:
        sys.exit("没有要测试的机房。")

    check_proxy_env()
    now = dt.datetime.now()
    print(f"开始测试 {len(targets)} 个机房  {now:%Y-%m-%d %H:%M}"
          f"{'（晚高峰时段）' if 20 <= now.hour < 23 else ''}\n")

    t0 = time.perf_counter()
    with cf.ThreadPoolExecutor(max_workers=min(32, len(targets))) as ex:
        results = list(ex.map(lambda t: ping_target(t, args), targets))
    print(f"延迟测试完成，用时 {time.perf_counter() - t0:.1f}s")

    if any(r.get("fake_ip") for r in results):
        print("\n[警告] 有域名被解析到 198.18.x.x（Fake-IP），说明代理/VPN 还开着，"
              "结果不是直连数据。请关闭后重测。")
    if any(r.get("tun") for r in results):
        print(f"\n[警告] 有机房延迟低于 {MIN_PLAUSIBLE_MS}ms，到美国不可能这么快——"
              "VPN/TUN 在本地代答了连接，这一轮数据作废。请彻底关闭 VPN 后重测。")

    results.sort(key=sort_key)

    if not args.no_download:
        by_name = {t["name"]: t for t in targets}
        candidates = [r for r in results if r["ok"]][: args.dl_top]
        for i, r in enumerate(candidates, 1):
            print(f"下载测速 {i}/{len(candidates)}: {r['name']} ...", end="", flush=True)
            mbps, note = download_speed(by_name[r["name"]], args)
            r["mbps"] = mbps
            if mbps is None:
                r["note"] = (r["note"] + "; " if r["note"] else "") + note
            print(f" {fmt(mbps, ' Mbps')}" if mbps is not None else f" 失败（{note}）")

    print(f"\n总用时 {time.perf_counter() - t0:.1f}s\n")
    print_table(results)
    path = save_csv(results, args.out, args.label)
    print(f"\n结果已保存：{path}")
    print("说明：延迟是 TCP 建连时间（约等于 ping），下载是单线程速度。"
          "测之前请关闭代理/VPN。")


if __name__ == "__main__":
    main()
