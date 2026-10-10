#!/usr/bin/env bash
# Lotus VPS 只读监控（给 Lotus Agent Lab 后端提供服务器状态）
#
# 做什么：建一个专用账号 lotusmon，它只能通过一把专用 SSH 钥匙登录，
#         而且登录后只会运行 /usr/local/bin/lotus-vps-stats，输出一行 JSON 就断开。
#         不能开 shell、不能端口转发、不能读 /etc/sing-box。
# 不做什么：不改 sshd 配置、不改 ufw 防火墙、不碰 sing-box 配置和服务。
#
# 用法（root 运行）：
#   bash setup-monitor.sh < lotus_vps_monitor.pub   安装或更新（从标准输入读监控公钥，只接受 ed25519）
#   bash setup-monitor.sh                           只更新统计脚本，保留已安装的公钥
#   bash setup-monitor.sh --test                    以 lotusmon 身份跑一次，打印 JSON
#   bash setup-monitor.sh --uninstall               删除 lotusmon 账号、钥匙和统计脚本（vnstat 保留）
#
# 可选环境变量：
#   PROXY_UNIT=sing-box   要监测的 systemd 服务名
#   PROXY_PORT=443        代理端口（只读连接数，不发起连接）
#   PROXY_BIN=sing-box    读取版本号用的程序名

set -Eeuo pipefail
trap 'printf "\033[1;31m[x]\033[0m 脚本在第 %s 行出错退出：%s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

MON_USER=lotusmon
MON_HOME=/var/lib/lotusmon
KEYS_DIR=$MON_HOME/.ssh
KEYS_FILE=$KEYS_DIR/authorized_keys
STATS_BIN=/usr/local/bin/lotus-vps-stats
PROXY_UNIT=${PROXY_UNIT:-sing-box}
PROXY_PORT=${PROXY_PORT:-443}
PROXY_BIN=${PROXY_BIN:-sing-box}

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -y "$@"
}

run_stats() { runuser -u "$MON_USER" -- "$STATS_BIN"; }

[[ $EUID -eq 0 ]] || die "请用 root 运行"

case ${1:-} in
  --test)
    id "$MON_USER" >/dev/null 2>&1 && [[ -x $STATS_BIN ]] || die "还没安装监控"
    trap - ERR; set +e
    run_stats | python3 -m json.tool
    exit 0 ;;
  --uninstall)
    pkill -u "$MON_USER" 2>/dev/null || true
    if id "$MON_USER" >/dev/null 2>&1; then userdel "$MON_USER"; fi
    rm -rf -- "$MON_HOME"
    rm -f -- "$STATS_BIN"
    log "已删除 $MON_USER 账号、钥匙和统计脚本（vnstat 保留；不需要可 apt purge vnstat）"
    exit 0 ;;
  "") ;;
  *) die "未知参数：$1" ;;
esac

# ---------- 检查参数 ----------
[[ $PROXY_UNIT =~ ^[A-Za-z0-9@._-]{1,64}$ ]] || die "PROXY_UNIT 不合法"
[[ $PROXY_PORT =~ ^[0-9]{1,5}$ ]] && (( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )) || die "PROXY_PORT 不合法"
[[ $PROXY_BIN =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "PROXY_BIN 不合法"
[[ -x /usr/bin/python3 ]] || die "缺少 /usr/bin/python3"

# ---------- 读取公钥 ----------
PUBKEY=""
if [[ ! -t 0 ]]; then
  IFS= read -r PUBKEY || true
  PUBKEY=${PUBKEY%$'\r'}
fi
if [[ -z $PUBKEY ]]; then
  [[ -s $KEYS_FILE ]] || die "第一次安装需要从标准输入传入监控公钥：bash setup-monitor.sh < lotus_vps_monitor.pub"
  log "没有传入新公钥，保留已安装的钥匙"
else
  [[ $PUBKEY =~ ^ssh-ed25519\ AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/]+=*(\ [A-Za-z0-9@._-]{1,64})?$ ]] \
    || die "公钥格式不对：只接受一行 ssh-ed25519 公钥（.pub 文件），不要传私钥"
  KEY_BODY=$(cut -d' ' -f2 <<<"$PUBKEY")
  if [[ -f /root/.ssh/authorized_keys ]] && grep -qF -- "$KEY_BODY" /root/.ssh/authorized_keys; then
    die "这把是 root 登录用的钥匙。请在 Termux 另生成一把专用监控钥匙"
  fi
  tmpkey=$(mktemp)
  printf '%s\n' "$PUBKEY" >"$tmpkey"
  ssh-keygen -l -f "$tmpkey" >/dev/null 2>&1 || { rm -f "$tmpkey"; die "公钥无法解析"; }
  rm -f "$tmpkey"
fi

# ---------- vnstat（本月流量统计） ----------
if ! command -v vnstat >/dev/null; then
  log "安装 vnstat（统计本月流量）"
  apt_get update -qq >/dev/null 2>&1 || warn "apt update 失败，继续"
  apt_get install -qq vnstat >/dev/null 2>&1 || warn "vnstat 安装失败：流量一栏会显示不可用，其余正常"
fi
if command -v vnstat >/dev/null && command -v systemctl >/dev/null; then
  systemctl enable --now vnstat >/dev/null 2>&1 || warn "vnstat 服务启动失败"
fi

# ---------- 监控账号 ----------
if ! id "$MON_USER" >/dev/null 2>&1; then
  log "创建只读监控账号 $MON_USER"
  # 需要一个 shell 来执行强制命令；交互登录由钥匙上的 restrict + command 挡住。
  useradd --system --home-dir "$MON_HOME" --no-create-home --shell /bin/sh \
    --comment "Lotus VPS monitor (read-only)" "$MON_USER"
fi
usermod -p '*' "$MON_USER"            # 无密码（只能用钥匙），不是“锁定”，以免影响钥匙登录
usermod -G '' "$MON_USER" 2>/dev/null || true   # 不加入任何附加组（sudo 等）
install -d -m 0755 -o root -g root "$MON_HOME" "$KEYS_DIR"   # 目录归 root，监控账号无法改自己的钥匙

# ---------- 统计脚本 ----------
log "写入统计脚本 $STATS_BIN"
tmpstats=$(mktemp)
cat >"$tmpstats" <<'PYEOF'
#!/usr/bin/python3 -I
"""Lotus VPS read-only stats. Prints one JSON line and exits.

Runs as the SSH forced command of the lotusmon account. It never reads the client's
requested command (SSH_ORIGINAL_COMMAND), arguments, or anything under /etc/sing-box.
Every section reports ok=false with an error code instead of a fake 0 when it fails.
"""
import fcntl, ipaddress, json, os, re, shutil, signal, socket, subprocess, sys, time

SCHEMA = 1
PROXY_UNIT = "@PROXY_UNIT@"
PROXY_PORT = @PROXY_PORT@
PROXY_BIN = "@PROXY_BIN@"
SAFE_PATH = "/usr/sbin:/usr/bin:/sbin:/bin"
ENV = {"PATH": SAFE_PATH, "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"}
CPU_WINDOW = 1.0


def run(args, timeout=3):
    exe = shutil.which(args[0], path=SAFE_PATH)
    if not exe:
        raise FileNotFoundError(args[0])
    p = subprocess.run([exe] + args[1:], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, universal_newlines=True, timeout=timeout, env=ENV)
    if p.returncode != 0:
        raise RuntimeError("exit")
    return p.stdout


def fail(exc):
    if isinstance(exc, FileNotFoundError):
        code = "not_installed"
    elif isinstance(exc, subprocess.TimeoutExpired):
        code = "timeout"
    elif isinstance(exc, (ValueError, KeyError, IndexError, TypeError)):
        code = "parse_error"
    else:
        code = "unavailable"
    return {"ok": False, "error": code}


def read(path):
    with open(path) as f:
        return f.read()


def cpu_sample():
    fields = read("/proc/stat").splitlines()[0].split()[1:]
    vals = [int(x) for x in fields[:8]]
    idle = vals[3] + vals[4]  # idle + iowait
    return sum(vals), idle


def boot_ts():
    for line in read("/proc/stat").splitlines():
        if line.startswith("btime "):
            return int(line.split()[1])
    raise ValueError("btime")


def default_iface():
    for line in read("/proc/net/route").splitlines()[1:]:
        cols = line.split()
        if len(cols) > 3 and cols[1] == "00000000" and int(cols[3], 16) & 2:
            return cols[0]
    return None


def host_section(iface):
    os_name = None
    try:
        for line in read("/etc/os-release").splitlines():
            if line.startswith("PRETTY_NAME="):
                os_name = line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    out = {"ok": True, "hostname": socket.gethostname(), "os": os_name,
           "kernel": os.uname().release, "boot_ts": boot_ts(),
           "uptime_s": int(float(read("/proc/uptime").split()[0])),
           "interface": iface, "ipv4": [], "ipv6": []}
    if iface:
        try:
            for item in json.loads(run(["ip", "-j", "addr", "show", "dev", iface])):
                for a in item.get("addr_info", []):
                    ip = ipaddress.ip_address(a.get("local", ""))
                    # Only globally routable addresses on the interface count as the host's public IP.
                    if ip.is_global and a.get("scope") == "global":
                        out["ipv%d" % ip.version].append(str(ip))
        except Exception:
            out["addr_error"] = "unavailable"
    return out


def memory_section():
    info = {}
    for line in read("/proc/meminfo").splitlines():
        key, _, rest = line.partition(":")
        info[key] = int(rest.split()[0]) * 1024
    total, avail = info["MemTotal"], info["MemAvailable"]
    return {"ok": True, "method": "MemTotal-MemAvailable", "total_bytes": total,
            "available_bytes": avail, "used_bytes": total - avail,
            "swap_total_bytes": info.get("SwapTotal", 0),
            "swap_used_bytes": info.get("SwapTotal", 0) - info.get("SwapFree", 0)}


def disk_section():
    st = os.statvfs("/")
    total = st.f_blocks * st.f_frsize
    used = (st.f_blocks - st.f_bfree) * st.f_frsize
    return {"ok": True, "mount": "/", "total_bytes": total, "used_bytes": used,
            "available_bytes": st.f_bavail * st.f_frsize}


def tcp_ports(port):
    listening, established = False, 0
    for name in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            lines = read(name).splitlines()[1:]
        except OSError:
            continue
        for line in lines:
            cols = line.split()
            if len(cols) < 4 or int(cols[1].rsplit(":", 1)[1], 16) != port:
                continue
            if cols[3] == "0A":
                listening = True
            elif cols[3] == "01":
                established += 1
    return listening, established


def proxy_section(btime):
    props = {}
    text = run(["systemctl", "show", PROXY_UNIT, "--no-pager", "--property=LoadState,ActiveState,"
                "SubState,MainPID,NRestarts,ActiveEnterTimestampMonotonic"])
    for line in text.splitlines():
        key, _, value = line.partition("=")
        props[key] = value
    active, sub = props.get("ActiveState", ""), props.get("SubState", "")
    if props.get("LoadState") == "not-found":
        status = "not_found"
    elif active == "active" and sub == "running":
        status = "running"
    elif active == "failed":
        status = "failed"
    elif active == "inactive":
        status = "stopped"
    elif active in ("activating", "reloading"):
        status = "starting"
    elif active == "deactivating":
        status = "stopping"
    else:
        status = "unknown"
    mono = int(props.get("ActiveEnterTimestampMonotonic") or 0)
    out = {"ok": True, "unit": PROXY_UNIT, "status": status, "active_state": active or None,
           "sub_state": sub or None,
           "since_ts": btime + mono // 1000000 if status == "running" and mono > 0 else None,
           "restarts": int(props["NRestarts"]) if props.get("NRestarts", "").isdigit() else None,
           "version": None, "port": PROXY_PORT}
    try:
        m = re.search(r"version\s+v?([0-9][0-9A-Za-z.+-]*)", run([PROXY_BIN, "version"]))
        out["version"] = m.group(1) if m else None
    except Exception:
        pass
    out["listening"], out["established"] = tcp_ports(PROXY_PORT)
    return out


def traffic_section(iface):
    if not iface:
        return {"ok": False, "error": "no_interface"}
    data = json.loads(run(["vnstat", "--json", "m", "-i", iface], timeout=4))
    now = time.localtime()
    for item in data.get("interfaces", []):
        if item.get("name") != iface:
            continue
        created = (item.get("created") or {}).get("date") or {}
        since = "%04d-%02d-%02d" % (created["year"], created["month"], created["day"]) if created else None
        for month in (item.get("traffic") or {}).get("month", []):
            d = month.get("date") or {}
            if d.get("year") == now.tm_year and d.get("month") == now.tm_mon:
                return {"ok": True, "source": "vnstat", "interface": iface,
                        "month": "%04d-%02d" % (now.tm_year, now.tm_mon),
                        "rx_bytes": int(month["rx"]), "tx_bytes": int(month["tx"]),
                        "tracking_since": since}
        return {"ok": False, "error": "no_data", "tracking_since": since}
    return {"ok": False, "error": "no_data"}


def counters_section(iface):
    if not iface:
        return {"ok": False, "error": "no_interface"}
    for line in read("/proc/net/dev").splitlines()[2:]:
        name, _, rest = line.partition(":")
        if name.strip() == iface:
            cols = rest.split()
            return {"ok": True, "interface": iface, "rx_bytes": int(cols[0]), "tx_bytes": int(cols[8])}
    return {"ok": False, "error": "no_data"}


def section(fn, *args):
    try:
        return fn(*args)
    except Exception as exc:
        return fail(exc)


def main():
    started = time.monotonic()
    signal.alarm(10)  # hard stop if anything hangs
    try:
        lock = open(__file__)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)  # one run at a time
    except OSError:
        sys.stdout.write(json.dumps({"schema": SCHEMA, "ts": int(time.time()), "error": "busy"}) + "\n")
        return 75
    try:
        before = cpu_sample()
    except Exception:
        before = None
    try:
        iface = default_iface()
    except Exception:
        iface = None
    try:
        btime = boot_ts()
    except Exception:
        btime = 0
    result = {"schema": SCHEMA, "ts": None,
              "host": section(host_section, iface),
              "memory": section(memory_section),
              "disk": section(disk_section),
              "proxy": section(proxy_section, btime),
              "traffic": section(traffic_section, iface),
              "counters": section(counters_section, iface),
              "system": {"ok": True, "reboot_required": os.path.exists("/run/reboot-required")}}
    # CPU percent needs two samples over a known window; never guess from one snapshot.
    remaining = CPU_WINDOW - (time.monotonic() - started)
    if remaining > 0:
        time.sleep(remaining)
    try:
        if before is None:
            raise RuntimeError("cpu")
        after = cpu_sample()
        total, idle = after[0] - before[0], after[1] - before[1]
        if total <= 0:
            raise ValueError("cpu window")
        load = [float(x) for x in read("/proc/loadavg").split()[:3]]
        result["cpu"] = {"ok": True, "percent": round(100.0 * (total - idle) / total, 1),
                         "window_s": round(time.monotonic() - started, 2),
                         "cores": os.cpu_count(), "load": load}
    except Exception as exc:
        result["cpu"] = fail(exc)
    result["ts"] = int(time.time())
    result["duration_ms"] = int((time.monotonic() - started) * 1000)
    sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
sed -i -e "s|@PROXY_UNIT@|$PROXY_UNIT|" -e "s|@PROXY_PORT@|$PROXY_PORT|" -e "s|@PROXY_BIN@|$PROXY_BIN|" "$tmpstats"
install -m 0755 -o root -g root "$tmpstats" "$STATS_BIN"
rm -f "$tmpstats"

# ---------- 钥匙：强制命令 + restrict ----------
if [[ -n $PUBKEY ]]; then
  log "写入监控钥匙（强制命令 + restrict：不能开 shell、不能转发端口）"
  tmpauth=$(mktemp)
  printf 'restrict,command="%s" %s\n' "$STATS_BIN" "$PUBKEY" >"$tmpauth"
  install -m 0644 -o root -g root "$tmpauth" "$KEYS_FILE"
  rm -f "$tmpauth"
fi

# ---------- sshd 是否允许这个账号用钥匙登录（只检查，不修改） ----------
if command -v sshd >/dev/null; then
  mkdir -p /run/sshd
  sshd_eff=$(sshd -T -C "user=$MON_USER,host=localhost,addr=127.0.0.1" 2>/dev/null || true)
  if [[ -z $sshd_eff ]]; then
    warn "无法读取 sshd 生效配置，跳过检查"
  else
    if grep -qi '^pubkeyauthentication no' <<<"$sshd_eff"; then
      warn "sshd 关闭了钥匙登录，监控账号将无法登录"
    fi
    if grep -qiE '^(allowusers|allowgroups) ' <<<"$sshd_eff" && ! grep -qiE "^allowusers .*\b$MON_USER\b" <<<"$sshd_eff"; then
      warn "sshd 设置了 AllowUsers/AllowGroups，可能挡住 $MON_USER（本脚本不改 sshd，需要的话手动加）"
    fi
  fi
fi

# ---------- 自检 ----------
log "自检：以 $MON_USER 身份运行一次"
out=$(run_stats) || die "统计脚本运行失败"
summary=$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
p, c, m, t = d.get("proxy", {}), d.get("cpu", {}), d.get("memory", {}), d.get("traffic", {})
print("代理服务：%s %s，端口 %s %s" % (p.get("unit"), p.get("status", p.get("error")), p.get("port"),
      "监听中" if p.get("listening") else "未监听"))
print("CPU：%s%%  内存：%s/%s MB" % (c.get("percent", "-"),
      m.get("used_bytes", 0) // 1048576, m.get("total_bytes", 0) // 1048576))
print("流量统计：%s" % ("本月已有数据" if t.get("ok") else "暂无（vnstat 刚装好需几分钟采集）"))
' <<<"$out") || die "自检输出不是有效 JSON"
printf '%s\n' "$summary"

fp=$(ssh-keygen -l -f "$KEYS_FILE" 2>/dev/null | awk '{print $2}' || true)
log "完成。监控钥匙指纹：${fp:-未知}"
echo "    在 Termux 里验证（应只输出一行 JSON）："
echo "    ssh -i ~/.ssh/lotus_vps_monitor -o IdentitiesOnly=yes $MON_USER@<VPS IP>"
