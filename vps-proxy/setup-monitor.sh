#!/usr/bin/env bash
# Lotus VPS 只读监控（给 Lotus Agent Lab 提供服务器状态）
#
# 做什么：建一个专用账号 lotusmon。它只能用专用 SSH 钥匙登录，登录后只会运行固定的只读程序，
#         输出一行 JSON 就断开；不能开 shell、不能端口转发、不能读 /etc/sing-box。
#   · Termux 钥匙（ed25519）→ /usr/local/bin/lotus-vps-stats：现采一次，给 Lab 后端
#   · App 钥匙（ecdsa-sha2-nistp256，Lotus Lab App 自己生成）→ /usr/local/bin/lotus-vps-app：
#     服务器每 5 分钟自己采样（systemd 定时器，以 lotusmon 身份），App 直接读结果，
#     手机睡眠、Termux 被系统冻结都不影响记录
# 不做什么：不改 sshd 配置、不改 ufw 防火墙、不碰 sing-box 配置和服务。
#
# 用法（root 运行）：
#   bash setup-monitor.sh < lotus_vps_monitor.pub   安装或更新 Termux 钥匙（标准输入，只接受 ed25519）
#   bash setup-monitor.sh --app-key "ecdsa-sha2-nistp256 AAAA... lotus-lab-app"
#                                                   安装或更新 App 钥匙（App 里复制的命令就是这一条），
#                                                   结尾打印配对码，粘贴回 App
#   bash setup-monitor.sh                           只更新程序，保留已安装的钥匙
#   bash setup-monitor.sh --pair                    再打印一次配对码
#   bash setup-monitor.sh --test                    以 lotusmon 身份各跑一次，打印结果
#   bash setup-monitor.sh --vultr-key               （可选）保存 Vultr API Key，见 README 的安全说明
#   bash setup-monitor.sh --vultr-off               删除保存的 Vultr API Key
#   bash setup-monitor.sh --uninstall               删除 lotusmon 账号、钥匙、程序、定时器和记录（vnstat 保留）
#
# 可和 --app-key 一起用的选项：
#   --label "Vultr LA"    App 里显示的名字        --quota-gb 1024     每月流量额度（GB）
#   --quota-basis tx      tx（只算出站）或 rx+tx    --host / --port     配对码里的地址和 SSH 端口（默认自动检测）
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
APP_BIN=/usr/local/bin/lotus-vps-app
STATE_DIR=/var/lib/lotus-monitor
CONF_DIR=/etc/lotus-monitor
UNIT=lotus-vps-collect
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
run_app()   { runuser -u "$MON_USER" -- "$APP_BIN" "$@"; }

# sshd 生效配置（Ubuntu 24.04 是 socket 激活，/run/sshd 可能不存在；先完整取输出再解析，避免 SIGPIPE）
sshd_effective() {
  command -v sshd >/dev/null || return 0
  mkdir -p /run/sshd
  sshd -T -C "user=$MON_USER,host=localhost,addr=127.0.0.1" 2>/dev/null || true
}

# 配对码：lotus-vps://lotusmon@地址:端口#SHA256:主机指纹（App 只信这个 ECDSA 主机钥匙）
print_pairing() {
  local conf host port fp="" f line
  conf=$(sshd_effective)
  host=${PAIR_HOST:-}
  if [[ -z $host ]]; then
    host=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
  fi
  port=${PAIR_PORT:-$(awk '/^port /{print $2; exit}' <<<"$conf")}
  port=${port:-22}
  while read -r f; do
    [[ -f $f.pub ]] || continue
    line=$(ssh-keygen -l -E sha256 -f "$f.pub" 2>/dev/null || true)
    if [[ $line == "256 SHA256:"*"(ECDSA)" ]]; then fp=$(awk '{print $2}' <<<"$line"); break; fi
  done < <(awk '/^hostkey /{print $2}' <<<"$conf")
  if [[ -z $fp && -f /etc/ssh/ssh_host_ecdsa_key.pub ]]; then
    line=$(ssh-keygen -l -E sha256 -f /etc/ssh/ssh_host_ecdsa_key.pub 2>/dev/null || true)
    [[ $line == "256 SHA256:"*"(ECDSA)" ]] && fp=$(awk '{print $2}' <<<"$line")
  fi
  if [[ -z $fp ]]; then
    warn "找不到 sshd 的 ECDSA (nistp256) 主机钥匙，App 无法核对服务器身份。可运行 ssh-keygen -A 后 systemctl restart ssh，再 bash setup-monitor.sh --pair"
    return 1
  fi
  if [[ -z $host ]]; then
    warn "无法检测服务器 IPv4：bash setup-monitor.sh --pair --host 你的服务器IP"
    return 1
  fi
  [[ $host == *:* ]] && host="[$host]"
  log "App 配对码（复制整行，粘贴到 Lotus Lab → Activity → VPS → Direct）："
  printf '\n    lotus-vps://%s@%s:%s#%s\n\n' "$MON_USER" "$host" "$port" "$fp"
}

# 保存 Vultr API Key：只存在服务器上（root:lotusmon 0640），App 只收到余额和流量数字
read_vultr_key() {
  local key=""
  if [[ -t 0 ]]; then
    read -rsp "粘贴 Vultr API Key（不显示）：" key; echo
  else
    IFS= read -r key || true
  fi
  key=${key%$'\r'}
  [[ $key =~ ^[A-Za-z0-9]{20,128}$ ]] || die "API Key 格式不对"
  install -d -m 0750 -o root -g "$MON_USER" "$CONF_DIR"
  local tmp; tmp=$(mktemp)
  printf '%s\n' "$key" >"$tmp"
  install -m 0640 -o root -g "$MON_USER" "$tmp" "$CONF_DIR/vultr.key"
  rm -f "$tmp"
  log "已保存 Vultr API Key。下一次采样（5 分钟内）开始读取余额和本月流量"
  warn "这把 Key 能管理整个 Vultr 账号：服务器被入侵时它也会泄露。请在 Vultr → Account → API 把 Access Control 只填这台服务器的 IP；不需要了用 --vultr-off 删除"
}

[[ $EUID -eq 0 ]] || die "请用 root 运行"

APP_KEY=""; LABEL=""; QUOTA_GB=""; QUOTA_BASIS=""; PAIR_HOST=""; PAIR_PORT=""; MODE=install
while (($#)); do
  case $1 in
    --test|--uninstall|--pair|--vultr-key|--vultr-off) MODE=${1#--} ;;
    --app-key)     (($# >= 2)) || die "--app-key 需要一行公钥"; APP_KEY=$2; shift ;;
    --label)       (($# >= 2)) || die "--label 需要名字"; LABEL=$2; shift ;;
    --quota-gb)    (($# >= 2)) || die "--quota-gb 需要数字"; QUOTA_GB=$2; shift ;;
    --quota-basis) (($# >= 2)) || die "--quota-basis 需要 tx 或 rx+tx"; QUOTA_BASIS=$2; shift ;;
    --host)        (($# >= 2)) || die "--host 需要地址"; PAIR_HOST=$2; shift ;;
    --port)        (($# >= 2)) || die "--port 需要端口"; PAIR_PORT=$2; shift ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

case $MODE in
  test)
    id "$MON_USER" >/dev/null 2>&1 && [[ -x $STATS_BIN ]] || die "还没安装监控"
    trap - ERR; set +e
    echo "== lotus-vps-stats（Termux 钥匙）=="
    run_stats | python3 -m json.tool
    if [[ -x $APP_BIN ]]; then
      echo "== lotus-vps-app（App 钥匙，服务器自己的记录）=="
      run_app --print
      systemctl list-timers "$UNIT.timer" --no-pager 2>/dev/null | head -3
    fi
    exit 0 ;;
  uninstall)
    systemctl disable --now "$UNIT.timer" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$UNIT.timer" "/etc/systemd/system/$UNIT.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
    pkill -u "$MON_USER" 2>/dev/null || true
    if id "$MON_USER" >/dev/null 2>&1; then userdel "$MON_USER"; fi
    rm -rf -- "$MON_HOME" "$STATE_DIR" "$CONF_DIR"
    rm -f -- "$STATS_BIN" "$APP_BIN"
    log "已删除 $MON_USER 账号、钥匙、程序、定时器、记录和 Vultr Key（vnstat 保留；不需要可 apt purge vnstat）"
    exit 0 ;;
  pair)
    [[ -x $APP_BIN ]] && grep -q "command=\"$APP_BIN\"" "$KEYS_FILE" 2>/dev/null || die "还没安装 App 钥匙：在 App 里复制安装命令运行"
    print_pairing || exit 1
    exit 0 ;;
  vultr-key)
    id "$MON_USER" >/dev/null 2>&1 && [[ -x $APP_BIN ]] || die "先安装 App 监控（App 里复制的命令），再保存 Vultr Key"
    read_vultr_key
    exit 0 ;;
  vultr-off)
    rm -f -- "$CONF_DIR/vultr.key"
    log "已删除 Vultr API Key（App 里的 Vultr 一栏会在下一次采样后消失）"
    exit 0 ;;
esac

# ---------- 检查参数 ----------
[[ $PROXY_UNIT =~ ^[A-Za-z0-9@._-]{1,64}$ ]] || die "PROXY_UNIT 不合法"
[[ $PROXY_PORT =~ ^[0-9]{1,5}$ ]] && (( PROXY_PORT >= 1 && PROXY_PORT <= 65535 )) || die "PROXY_PORT 不合法"
[[ $PROXY_BIN =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "PROXY_BIN 不合法"
[[ -z $LABEL || $LABEL =~ ^[A-Za-z0-9\ ._-]{1,40}$ ]] || die "--label 只能用字母、数字、空格和 ._-（最多 40 个）"
[[ -z $QUOTA_GB || $QUOTA_GB =~ ^[0-9]{1,6}$ ]] || die "--quota-gb 需要整数 GB"
[[ -z $QUOTA_BASIS || $QUOTA_BASIS == tx || $QUOTA_BASIS == rx+tx ]] || die "--quota-basis 只能是 tx 或 rx+tx"
[[ -z $PAIR_HOST || $PAIR_HOST =~ ^[A-Za-z0-9.:-]{1,253}$ ]] || die "--host 不合法"
[[ -z $PAIR_PORT || ( $PAIR_PORT =~ ^[0-9]{1,5}$ && PAIR_PORT -ge 1 && PAIR_PORT -le 65535 ) ]] || die "--port 不合法"
[[ -x /usr/bin/python3 ]] || die "缺少 /usr/bin/python3"
command -v systemctl >/dev/null || die "需要 systemd"

# ---------- 读取公钥 ----------
check_pubkey() {   # $1 = 一行公钥：能解析、不是 root 登录钥匙
  local tmpkey body
  body=$(cut -d' ' -f2 <<<"$1")
  if [[ -f /root/.ssh/authorized_keys ]] && grep -qF -- "$body" /root/.ssh/authorized_keys; then
    die "这把是 root 登录用的钥匙，不能当监控钥匙"
  fi
  tmpkey=$(mktemp)
  printf '%s\n' "$1" >"$tmpkey"
  ssh-keygen -l -f "$tmpkey" >/dev/null 2>&1 || { rm -f "$tmpkey"; die "公钥无法解析"; }
  rm -f "$tmpkey"
}

PUBKEY=""
if [[ -n $APP_KEY ]]; then
  APP_KEY=${APP_KEY%$'\r'}
  [[ $APP_KEY =~ ^ecdsa-sha2-nistp256\ AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABB[A-Za-z0-9+/]+=*(\ [A-Za-z0-9@._-]{1,64})?$ ]] \
    || die "App 公钥格式不对：请从 App 里重新复制整条命令"
  check_pubkey "$APP_KEY"
elif [[ ! -t 0 ]]; then
  # 只有没给 --app-key 时才读标准输入（Termux 钥匙），避免 ssh 远程执行时卡在等待输入
  IFS= read -r PUBKEY || true
  PUBKEY=${PUBKEY%$'\r'}
fi
if [[ -n $PUBKEY ]]; then
  [[ $PUBKEY =~ ^ssh-ed25519\ AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/]+=*(\ [A-Za-z0-9@._-]{1,64})?$ ]] \
    || die "公钥格式不对：只接受一行 ssh-ed25519 公钥（.pub 文件），不要传私钥"
  check_pubkey "$PUBKEY"
fi
if [[ -z $PUBKEY && -z $APP_KEY ]]; then
  [[ -s $KEYS_FILE ]] || die "第一次安装需要一把钥匙：App 里复制的 --app-key 命令，或 bash setup-monitor.sh < lotus_vps_monitor.pub"
  log "没有传入新公钥，保留已安装的钥匙"
fi

# ---------- vnstat（本月流量统计） ----------
if ! command -v vnstat >/dev/null; then
  log "安装 vnstat（统计本月流量）"
  apt_get update -qq >/dev/null 2>&1 || warn "apt update 失败，继续"
  apt_get install -qq vnstat >/dev/null 2>&1 || warn "vnstat 安装失败：流量一栏会显示不可用，其余正常"
fi
if command -v vnstat >/dev/null; then
  systemctl enable --now vnstat >/dev/null 2>&1 || warn "vnstat 服务启动失败"
fi

# ---------- 监控账号 ----------
if ! id "$MON_USER" >/dev/null 2>&1; then
  log "创建只读监控账号 $MON_USER"
  # 需要一个 shell 来执行强制命令；交互登录由钥匙上的 restrict + command 挡住。
  useradd --system --home-dir "$MON_HOME" --no-create-home --shell /bin/sh \
    --comment "Lotus VPS monitor (read-only)" "$MON_USER"
fi
# 专用主组：/etc/lotus-monitor 归 root:lotusmon，只有这个账号能读
getent group "$MON_USER" >/dev/null || groupadd --system "$MON_USER"
[[ $(id -gn "$MON_USER") == "$MON_USER" ]] || usermod -g "$MON_USER" "$MON_USER"
usermod -p '*' "$MON_USER"            # 无密码（只能用钥匙），不是“锁定”，以免影响钥匙登录
usermod -G '' "$MON_USER" 2>/dev/null || true   # 不加入任何附加组（sudo 等）
install -d -m 0755 -o root -g root "$MON_HOME" "$KEYS_DIR"   # 目录归 root，监控账号无法改自己的钥匙

# ---------- 统计脚本（Termux 钥匙用，现采一次） ----------
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
        # Raw cumulative jiffies let the caller average over its own poll interval,
        # which hides the cost of this very login (the 1 s window cannot).
        result["cpu"] = {"ok": True, "percent": round(100.0 * (total - idle) / total, 1),
                         "window_s": round(time.monotonic() - started, 2),
                         "cores": os.cpu_count(), "load": load,
                         "counters": {"total": after[0], "idle": after[1]}}
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

# ---------- App 采样与读取程序 ----------
log "写入服务器自采样程序 $APP_BIN"
tmpapp=$(mktemp)
cat >"$tmpapp" <<'PYEOF'
#!/usr/bin/python3 -I
"""Lotus VPS monitor: on-server collector and the Lotus Lab App's read-only view.

  lotus-vps-app --collect   systemd timer, every 5 minutes, as lotusmon: one sample into /var/lib/lotus-monitor
  lotus-vps-app --print     (any user who can read the state) the snapshot, indented, for a human
  lotus-vps-app             SSH forced command of the App key. SSH_ORIGINAL_COMMAND may be "snapshot"
                            (default) or "refresh"; anything else is refused. Prints one JSON line.

The snapshot has the same shape (schema 1) as the Lab backend's /api/vps, so the App reads either.
Rules: no client-supplied paths or arguments, nothing under /etc/sing-box, only whitelisted numbers and
short texts leave the server, a failed section stays ok=false (never a fake 0), old data is never current.
"""
import calendar
import copy
import fcntl
import ipaddress
import json
import os
import re
import signal
import subprocess
import sys
import time
import uuid

SCHEMA = 1
COLLECTOR = 2
STATS_BIN = "/usr/local/bin/lotus-vps-stats"
STATE_DIR = "/var/lib/lotus-monitor"
CONFIG_DIR = "/etc/lotus-monitor"
INTERVAL = 300
STALE_AFTER = INTERVAL * 2 + 60
KEEP_SAMPLES = 7 * 86400
SERIES_WINDOW = 86400
KEEP_EVENTS = 30 * 86400
MAX_EVENTS = 60
QUOTA_STEPS = (50, 80, 90, 100)
REFRESH_COOLDOWN = 30
GAP = 600
VULTR_EVERY = 1800
VULTR_RETRY = 600
VULTR_API = "https://api.vultr.com/v2"

ERRORS = {
    "busy": ("Server busy", None),
    "timeout": ("Stats timed out", None),
    "stats_failed": ("Stats script failed", "Run: bash setup-monitor.sh --test"),
    "bad_response": ("Unexpected stats output", "Re-run setup-monitor.sh"),
    "schema": ("Stats script version unsupported", "Re-run setup-monitor.sh"),
}
PROXY_STATES = {"running", "stopped", "failed", "starting", "stopping", "not_found", "unknown"}


# ---------- sanitising the stats JSON (mirrors Lab web/vps_monitor.py) ----------

def _num(v, lo=0, hi=1e18):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v:
        return None
    return v if lo <= v <= hi else None


def _int(v, lo=0, hi=1 << 62):
    n = _num(v, lo, hi)
    return int(n) if n is not None else None


def _text(v, limit=64):
    if not isinstance(v, str):
        return None
    v = "".join(c for c in v if c.isprintable())[:limit]
    return v or None


def _flag(v):
    return v if isinstance(v, bool) else None


def _ips(values, version):
    out = []
    for v in values if isinstance(values, list) else []:
        try:
            ip = ipaddress.ip_address(v)
        except (ValueError, TypeError):
            continue
        if ip.version == version and ip.is_global:
            out.append(str(ip))
    return out[:4]


def _section(raw, build):
    if not isinstance(raw, dict):
        return {"ok": False, "error": "missing"}
    if raw.get("ok") is not True:
        return {"ok": False, "error": _text(raw.get("error"), 24) or "unavailable"}
    try:
        out = build(raw)
    except (TypeError, ValueError, KeyError):
        return {"ok": False, "error": "parse_error"}
    out["ok"] = True
    return out


class Busy(Exception):
    pass


class WrongSchema(Exception):
    pass


def sanitize(raw):
    if not isinstance(raw, dict):
        raise ValueError("not an object")
    if raw.get("error") == "busy":
        raise Busy()
    if raw.get("schema") != SCHEMA:
        raise WrongSchema()
    ts = _int(raw.get("ts"), 1, 1 << 40)
    if ts is None:
        raise ValueError("ts")

    def host(r):
        return {"hostname": _text(r.get("hostname")), "os": _text(r.get("os")),
                "kernel": _text(r.get("kernel")), "boot_ts": _int(r.get("boot_ts"), 1, 1 << 40),
                "uptime_s": _int(r.get("uptime_s")), "interface": _text(r.get("interface"), 32),
                "ipv4": _ips(r.get("ipv4"), 4), "ipv6": _ips(r.get("ipv6"), 6)}

    def cpu(r):
        c = r.get("counters") if isinstance(r.get("counters"), dict) else {}
        load = r.get("load") if isinstance(r.get("load"), list) else []
        out = {"percent": _num(r.get("percent"), 0, 100), "window_s": _num(r.get("window_s"), 0, 60),
               "cores": _int(r.get("cores"), 1, 4096),
               "load": [x for x in (_num(v, 0, 1e6) for v in load[:3]) if x is not None]}
        total, idle = _int(c.get("total")), _int(c.get("idle"))
        if total is not None and idle is not None and idle <= total:
            out["counters"] = {"total": total, "idle": idle}
        return out

    def memory(r):
        total, used = _int(r["total_bytes"], 1), _int(r["used_bytes"])
        if used is None or used > total:
            raise ValueError("memory")
        return {"total_bytes": total, "used_bytes": used, "available_bytes": _int(r.get("available_bytes")),
                "swap_total_bytes": _int(r.get("swap_total_bytes")), "swap_used_bytes": _int(r.get("swap_used_bytes")),
                "method": "MemTotal-MemAvailable"}

    def disk(r):
        total, used = _int(r["total_bytes"], 1), _int(r["used_bytes"])
        if used is None or used > total:
            raise ValueError("disk")
        return {"mount": "/", "total_bytes": total, "used_bytes": used, "available_bytes": _int(r.get("available_bytes"))}

    def proxy(r):
        status = r.get("status") if r.get("status") in PROXY_STATES else "unknown"
        return {"unit": _text(r.get("unit")), "status": status, "since_ts": _int(r.get("since_ts"), 1, 1 << 40),
                "restarts": _int(r.get("restarts"), 0, 1 << 31), "version": _text(r.get("version"), 32),
                "port": _int(r.get("port"), 1, 65535), "listening": _flag(r.get("listening")),
                "established": _int(r.get("established"), 0, 1 << 31)}

    def traffic(r):
        month = r.get("month") if isinstance(r.get("month"), str) and re.fullmatch(r"\d{4}-\d{2}", r["month"]) else None
        since = r.get("tracking_since")
        since = since if isinstance(since, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", since) else None
        rx, tx = _int(r["rx_bytes"]), _int(r["tx_bytes"])
        if month is None or rx is None or tx is None:
            raise ValueError("traffic")
        return {"source": "vnstat", "month": month, "rx_bytes": rx, "tx_bytes": tx, "tracking_since": since}

    def counters(r):
        rx, tx = _int(r["rx_bytes"]), _int(r["tx_bytes"])
        if rx is None or tx is None:
            raise ValueError("counters")
        return {"interface": _text(r.get("interface"), 32), "rx_bytes": rx, "tx_bytes": tx}

    def system(r):
        return {"reboot_required": _flag(r.get("reboot_required"))}

    return {"schema": SCHEMA, "ts": ts, "duration_ms": _int(raw.get("duration_ms"), 0, 600000),
            "host": _section(raw.get("host"), host), "cpu": _section(raw.get("cpu"), cpu),
            "memory": _section(raw.get("memory"), memory), "disk": _section(raw.get("disk"), disk),
            "proxy": _section(raw.get("proxy"), proxy), "traffic": _section(raw.get("traffic"), traffic),
            "counters": _section(raw.get("counters"), counters), "system": _section(raw.get("system"), system)}


def _month_start(ts):
    t = time.gmtime(ts)
    return calendar.timegm((t.tm_year, t.tm_mon, 1, 0, 0, 0))


def _pct(used, total):
    return round(100.0 * used / total, 1) if isinstance(used, (int, float)) and total else None


# ---------- settings and state ----------

def settings():
    raw = {}
    try:
        with open(os.path.join(CONFIG_DIR, "config.json")) as f:
            raw = json.load(f)
    except (OSError, ValueError):
        pass
    if not isinstance(raw, dict):
        raw = {}
    label = _text(str(raw.get("label") or "VPS").strip(), 40) or "VPS"
    quota = raw.get("quota_gb", 1024)
    quota = float(quota) if isinstance(quota, (int, float)) and not isinstance(quota, bool) and 0 <= quota <= 1e6 else 1024.0
    basis = raw.get("quota_basis") if raw.get("quota_basis") in ("tx", "rx+tx") else "tx"
    return {"label": label, "quota_gb": quota, "quota_basis": basis}


def empty_state():
    return {"last_sample": None, "prev_sample": None, "last_success_at": None, "last_attempt_at": None,
            "last_error": None, "failures": 0, "duration_ms": None, "samples": [], "events": [],
            "quota_fired": {}, "collection_started_at": None, "vultr": None, "vultr_attempt_at": None}


def load():
    state = empty_state()
    try:
        with open(os.path.join(STATE_DIR, "state.json")) as f:
            saved = json.load(f)
        if isinstance(saved, dict):
            for key in state:
                if key in saved:
                    state[key] = saved[key]
    except (OSError, ValueError):
        pass
    return state


def save(state, now):
    state["samples"] = [x for x in state["samples"] if now - KEEP_SAMPLES <= x["ts"] <= now + 300]
    state["events"] = [e for e in state["events"] if now - KEEP_EVENTS <= e["ts"]][:MAX_EVENTS]
    path = os.path.join(STATE_DIR, "state.json")
    temp = path + ".tmp"
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(temp, path)


class Locked:
    """One sampler at a time (timer and an App refresh may overlap)."""

    def __init__(self, wait):
        self.wait = wait

    def __enter__(self):
        self.f = open(os.path.join(STATE_DIR, "lock"), "a")
        deadline = time.monotonic() + self.wait
        while True:
            try:
                fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError:
                if time.monotonic() >= deadline:
                    self.f.close()
                    raise Busy()
                time.sleep(0.2)

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def event(state, kind, now, **fields):
    state["events"].insert(0, {"id": uuid.uuid4().hex[:12], "type": kind, "ts": now, **fields})


# ---------- derived numbers (mirrors Lab web/vps_monitor.py) ----------

def traffic_of(cur, s):
    quota_gb, basis = s["quota_gb"], s["quota_basis"]
    month_start = _month_start(cur["ts"])
    month = time.strftime("%Y-%m", time.gmtime(cur["ts"]))
    candidates = []
    t = cur["traffic"]
    if t["ok"] and t.get("month") == month:
        since = t.get("tracking_since")
        partial = bool(since and since > time.strftime("%Y-%m-01", time.gmtime(cur["ts"])))
        candidates.append({"source": "vnstat", "rx_bytes": t["rx_bytes"], "tx_bytes": t["tx_bytes"],
                           "since": since, "partial": partial})
    k, h = cur["counters"], cur["host"]
    if k["ok"] and h["ok"] and h.get("boot_ts") and h["boot_ts"] >= month_start:
        candidates.append({"source": "Interface counters since boot", "rx_bytes": k["rx_bytes"],
                           "tx_bytes": k["tx_bytes"], "since": time.strftime("%Y-%m-%d", time.gmtime(h["boot_ts"])),
                           "partial": h["boot_ts"] > month_start + 3600})
    quota = int(quota_gb * 1e9) if quota_gb else None
    if not candidates:
        return {"month": month, "used_bytes": None, "quota_bytes": quota, "percent": None, "basis": basis, "source": None}
    pick = max(candidates, key=lambda c: c["tx_bytes"] if basis == "tx" else c["rx_bytes"] + c["tx_bytes"])
    used = pick["tx_bytes"] if basis == "tx" else pick["rx_bytes"] + pick["tx_bytes"]
    return {"month": month, "used_bytes": used, "rx_bytes": pick["rx_bytes"], "tx_bytes": pick["tx_bytes"],
            "quota_bytes": quota, "percent": _pct(used, quota), "basis": basis,
            "basis_label": "Outbound only (Vultr meters outbound)" if basis == "tx" else "Inbound + outbound",
            "source": pick["source"], "since": pick["since"], "at_least": pick["partial"]}


def derive(cur, prev, s):
    same_boot = bool(prev and (prev.get("host") or {}).get("ok") and cur["host"]["ok"]
                     and prev["host"].get("boot_ts") == cur["host"].get("boot_ts"))
    dt = cur["ts"] - prev["ts"] if prev else 0
    cpu = {"percent": None, "window_s": None, "basis": None}
    c, pc = cur["cpu"], (prev or {}).get("cpu") or {}
    if c["ok"] and same_boot and 30 <= dt <= 600 and c.get("counters") and pc.get("counters"):
        dtot = c["counters"]["total"] - pc["counters"]["total"]
        didle = c["counters"]["idle"] - pc["counters"]["idle"]
        if dtot > 0 and 0 <= didle <= dtot:
            cpu = {"percent": round(100.0 * (dtot - didle) / dtot, 1), "window_s": dt,
                   "basis": "Average between two samples"}
    if cpu["percent"] is None and c["ok"] and c.get("percent") is not None:
        cpu = {"percent": c["percent"], "window_s": c.get("window_s"), "basis": "One-second sample"}
    rates = {"rx_bps": None, "tx_bps": None, "window_s": None}
    k, pk = cur["counters"], (prev or {}).get("counters") or {}
    if k["ok"] and pk.get("ok") and same_boot and 30 <= dt <= 600:
        drx, dtx = k["rx_bytes"] - pk["rx_bytes"], k["tx_bytes"] - pk["tx_bytes"]
        if drx >= 0 and dtx >= 0:
            rates = {"rx_bps": int(drx / dt), "tx_bps": int(dtx / dt), "window_s": dt}
    uptime = None
    if cur["proxy"]["ok"] and cur["proxy"].get("status") == "running" and cur["proxy"].get("since_ts"):
        uptime = max(0, cur["ts"] - cur["proxy"]["since_ts"])
    return {"cpu": cpu, "rates": rates, "traffic": traffic_of(cur, s), "proxy_uptime_s": uptime}


def transitions(state, prev, cur, s, now):
    p_proxy, c_proxy = (prev or {}).get("proxy") or {}, cur["proxy"]
    p_host, c_host = (prev or {}).get("host") or {}, cur["host"]
    if prev and p_host.get("ok") and c_host["ok"] and p_host.get("boot_ts") and c_host.get("boot_ts") \
            and abs(c_host["boot_ts"] - p_host["boot_ts"]) > 5:
        event(state, "VPS rebooted", now)
    if prev and p_proxy.get("ok") and c_proxy["ok"]:
        was, is_now = p_proxy.get("status"), c_proxy.get("status")
        if was == "running" and is_now != "running":
            event(state, "Proxy stopped", now, reason=is_now)
        elif was != "running" and is_now == "running":
            event(state, "Proxy started", now)
        elif is_now == "running" and p_proxy.get("since_ts") and c_proxy.get("since_ts") \
                and c_proxy["since_ts"] != p_proxy["since_ts"]:
            event(state, "Proxy restarted", now)
    p_sys, c_sys = (prev or {}).get("system") or {}, cur["system"]
    if c_sys["ok"] and c_sys.get("reboot_required") and not p_sys.get("reboot_required"):
        event(state, "Reboot required", now)
    traffic = traffic_of(cur, s)
    if traffic.get("percent") is not None:
        fired = state["quota_fired"].setdefault(traffic["month"], [])
        for step in QUOTA_STEPS:
            if traffic["percent"] >= step and step not in fired:
                fired.append(step)
                event(state, "Traffic %d%%" % step, now)
        for month in list(state["quota_fired"]):
            if month != traffic["month"]:
                del state["quota_fired"][month]


# ---------- one sample ----------

def run_stats():
    try:
        p = subprocess.run([STATS_BIN], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=20, env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C.UTF-8"})
    except subprocess.TimeoutExpired:
        return None, ""
    except OSError:
        return -1, ""
    return p.returncode, p.stdout[:262144].decode("utf-8", "replace")


def sample_once(runner):
    """Returns (sample, error code, duration ms)."""
    started = time.monotonic()
    code = None
    for attempt in range(3):
        rc, out = runner()
        if rc is None:
            code = "timeout"
            break
        try:
            lines = out.strip().splitlines()
            sample = sanitize(json.loads(lines[-1])) if lines else None
            if sample is not None and rc == 0:
                return sample, None, int((time.monotonic() - started) * 1000)
            code = "stats_failed"
        except Busy:
            code = "busy"
            time.sleep(1.5)
            continue
        except WrongSchema:
            code = "schema"
        except (ValueError, IndexError, TypeError):
            code = "stats_failed" if rc not in (0, None) else "bad_response"
        break
    return None, code, int((time.monotonic() - started) * 1000)


def collect(clock=time.time, runner=run_stats, vultr=None):
    """Take one sample and record it. Returns the error code or None."""
    s = settings()
    with Locked(25):
        state = load()
        previous = state["last_attempt_at"]
        sample, code, duration = sample_once(runner)
        now = clock()
        if previous is not None and now - previous > GAP:
            event(state, "Monitoring paused", now, from_ts=previous, to_ts=now, duration_s=now - previous,
                  reason="No samples recorded; the VPS was off or the collector did not run. "
                         "Server state during this interval is unknown.")
        state["last_attempt_at"] = now
        state["duration_ms"] = duration
        if sample is not None:
            prev = state["last_sample"]
            if state["failures"] >= 2:
                event(state, "Sampling recovered", now)
            state["prev_sample"], state["last_sample"] = prev, sample
            if state["collection_started_at"] is None:
                state["collection_started_at"] = min([sample["ts"]] + [x["ts"] for x in state["samples"]])
            state["last_success_at"] = now
            state["failures"] = 0
            state["last_error"] = None
            transitions(state, prev, sample, s, now)
            d = derive(sample, prev, s)
            mem = sample["memory"]
            averaged = (d["cpu"]["basis"] or "").startswith("Average")
            state["samples"].append({
                "ts": sample["ts"], "cpu": d["cpu"]["percent"] if averaged else None,
                "mem": _pct(mem.get("used_bytes"), mem.get("total_bytes")) if mem["ok"] else None,
                "conns": sample["proxy"].get("established") if sample["proxy"]["ok"] else None,
                "rx_bps": d["rates"]["rx_bps"], "tx_bps": d["rates"]["tx_bps"],
                "proxy": sample["proxy"].get("status") if sample["proxy"]["ok"] else None})
        else:
            state["failures"] += 1
            state["last_error"] = {"code": code, "ts": now}
            if state["failures"] == 2:
                event(state, "Sampling failed", now, reason=ERRORS.get(code, ("Stats failed",))[0])
        if vultr is not None:
            state["vultr"], state["vultr_attempt_at"] = vultr, now
        save(state, now)
    return code


# ---------- optional: Vultr account figures (key only on this server) ----------

def vultr_due(state, now):
    if not os.path.isfile(os.path.join(CONFIG_DIR, "vultr.key")):
        return False
    last = state.get("vultr_attempt_at") or 0
    ok = bool((state.get("vultr") or {}).get("ok"))
    return now - last >= (VULTR_EVERY if ok else VULTR_RETRY)


def vultr_fetch(now, opener=None):
    """Balance, pending charges and this month's billed bandwidth. The key never leaves this function."""
    import urllib.error
    import urllib.request
    try:
        with open(os.path.join(CONFIG_DIR, "vultr.key")) as f:
            key = f.read().strip()
    except OSError:
        return {"ok": False, "error": "key_unreadable", "ts": now}
    if not re.fullmatch(r"[A-Za-z0-9]{20,128}", key):
        return {"ok": False, "error": "key_invalid", "ts": now}
    opener = opener or urllib.request.build_opener(urllib.request.HTTPSHandler())

    def get(path):
        req = urllib.request.Request(VULTR_API + path, headers={
            "Authorization": "Bearer " + key, "Accept": "application/json", "User-Agent": "lotus-vps-monitor/2"})
        with opener.open(req, timeout=10) as r:
            return json.loads(r.read(262144).decode("utf-8", "replace"))

    try:
        account = (get("/account") or {}).get("account") or {}
        bandwidth = (get("/account/bandwidth") or {}).get("bandwidth") or {}
    except urllib.error.HTTPError as e:
        code = {401: "unauthorized", 403: "forbidden", 429: "rate_limited"}.get(e.code, "http_%d" % e.code)
        return {"ok": False, "error": code, "ts": now}
    except (urllib.error.URLError, OSError, ValueError, AttributeError):
        return {"ok": False, "error": "unreachable", "ts": now}

    def period(p):
        p = p if isinstance(p, dict) else {}
        return {"gb_in": _num(p.get("gb_in"), 0, 1e9), "gb_out": _num(p.get("gb_out"), 0, 1e9),
                "overage_gb": _num(p.get("overage"), 0, 1e9), "overage_cost": _num(p.get("overage_cost"), 0, 1e9),
                "start_ts": _int(int(p["timestamp_start"]) if str(p.get("timestamp_start", "")).isdigit() else None, 1, 1 << 40),
                "end_ts": _int(int(p["timestamp_end"]) if str(p.get("timestamp_end", "")).isdigit() else None, 1, 1 << 40)}

    return {"ok": True, "ts": now, "balance": _num(account.get("balance"), -1e9, 1e9),
            "pending_charges": _num(account.get("pending_charges"), -1e9, 1e9),
            "month": period(bandwidth.get("current_month_to_date")),
            "projected": period(bandwidth.get("current_month_projected"))}


# ---------- snapshot (same shape as the Lab backend's /api/vps) ----------

def verdict(state_name, code, sample, derived):
    if state_name == "checking":
        return "Checking", "muted", []
    if state_name == "error":
        return "Attention", "warn", [ERRORS.get(code, ("Unavailable",))[0]]
    if state_name == "stale":
        return "Unknown", "muted", ["No current sample"]
    proxy = sample["proxy"]
    if not proxy["ok"] or proxy.get("status") != "running" or proxy.get("listening") is False:
        label = "Proxy service " + (proxy.get("status") or "unknown").replace("_", " ") if proxy["ok"] else "Proxy status unavailable"
        if proxy["ok"] and proxy.get("status") == "running":
            label = "Proxy port not listening"
        return "Proxy down", "bad", [label]
    reasons = []
    mem, disk, sysinfo = sample["memory"], sample["disk"], sample["system"]
    if derived["cpu"]["percent"] is not None and derived["cpu"]["percent"] >= 90 and derived["cpu"]["basis"].startswith("Average"):
        reasons.append("CPU %.0f%%" % derived["cpu"]["percent"])
    mp = _pct(mem.get("used_bytes"), mem.get("total_bytes")) if mem["ok"] else None
    if mp is not None and mp >= 90:
        reasons.append("Memory %.0f%%" % mp)
    dp = _pct(disk.get("used_bytes"), disk.get("total_bytes")) if disk["ok"] else None
    if dp is not None and dp >= 90:
        reasons.append("Disk %.0f%%" % dp)
    tp = derived["traffic"].get("percent")
    if tp is not None and tp >= 80:
        reasons.append("Traffic %.0f%%" % tp)
    if sysinfo["ok"] and sysinfo.get("reboot_required"):
        reasons.append("Reboot required")
    if state_name == "retrying":
        reasons.insert(0, "Last sample failed · retrying")
    if reasons:
        return "Attention", "warn", reasons
    return "Healthy", "ok", []


def snapshot(state, s, now):
    sample, prev = state["last_sample"], state["prev_sample"]
    last_ok, last_try = state["last_success_at"], state["last_attempt_at"]
    err = state["last_error"]
    code = err["code"] if err else None
    age = int(now - last_ok) if last_ok else None
    fresh = age is not None and 0 <= age <= STALE_AFTER
    if last_try is None:
        name = "checking"
    elif code is None:
        name = "online" if fresh else "stale"
    elif fresh:
        name = "retrying"
    else:
        name = "error"
    # The timer stopped (or the clock jumped): nothing is current, whatever the last result was.
    if name in ("online", "retrying", "error") and now - last_try > STALE_AFTER:
        name = "stale"
    if sample is None and name in ("online", "retrying"):
        name = "stale"
    derived = derive(sample, prev, s) if sample else None
    overall, tone, reasons = verdict(name, code, sample, derived)
    error = None
    if code:
        msg, hint = ERRORS.get(code, ("Unavailable", None))
        error = {"code": code, "message": msg, "hint": hint, "ts": err.get("ts")}
    host = (sample or {}).get("host") or {}
    vultr = state.get("vultr")
    return {
        "schema": SCHEMA, "collector": COLLECTOR, "source": "vps", "configured": True,
        "label": s["label"], "host": (host.get("ipv4") or [None])[0] if host.get("ok") else None,
        "state": name, "overall": overall, "tone": tone, "reasons": reasons,
        "checked_at": last_try, "last_success_at": last_ok, "data_age_s": age,
        "next_check_at": (last_try + INTERVAL) if last_try else None, "refreshing": False, "server_time": now,
        "interval_s": INTERVAL, "stale_after_s": STALE_AFTER, "error": error, "monitor_error": None,
        "channel": {"duration_ms": None, "proxy_path": "unknown", "sample_ms": state.get("duration_ms"),
                    "definition": "Read over SSH by the App; the VPS samples itself"},
        "server": sample, "derived": derived,
        "series": [x for x in state["samples"] if now - SERIES_WINDOW <= x["ts"] <= now + 300],
        "series_started_at": state.get("collection_started_at") or min((x["ts"] for x in state["samples"]), default=None),
        "events": state["events"][:20],
        "vultr": vultr if isinstance(vultr, dict) else None,
        "background": "The VPS samples itself every 5 minutes (systemd timer); phone sleep does not interrupt it",
    }


# ---------- entry points ----------

def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main(argv, clock=time.time):
    signal.alarm(80)
    args = argv[1:]
    if args == ["--collect"]:
        if os.geteuid() == 0:
            sys.stderr.write("run as lotusmon (runuser -u lotusmon -- lotus-vps-app --collect)\n")
            return 2
        state = load()
        info = vultr_fetch(clock()) if vultr_due(state, clock()) else None
        try:
            return 0 if collect(clock, vultr=info) is None else 1
        except Busy:
            return 75
    if args == ["--print"]:
        print(json.dumps(snapshot(load(), settings(), clock()), ensure_ascii=False, indent=2))
        return 0
    if args:
        emit({"schema": SCHEMA, "error": "unsupported"})
        return 2
    command = os.environ.get("SSH_ORIGINAL_COMMAND", "").strip()
    if command not in ("", "snapshot", "refresh"):
        emit({"schema": SCHEMA, "error": "unsupported"})
        return 2
    extra = {}
    if command == "refresh":
        last = load()["last_attempt_at"] or 0
        wait = REFRESH_COOLDOWN - (clock() - last)
        if wait > 0:
            extra = {"refreshed": False, "retry_after_s": int(wait) + 1}
        else:
            try:
                collect(clock)
                extra = {"refreshed": True}
            except Busy:
                extra = {"refreshed": False, "retry_after_s": 5}
    emit({**snapshot(load(), settings(), clock()), **extra})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PYEOF
install -m 0755 -o root -g root "$tmpapp" "$APP_BIN"
rm -f "$tmpapp"
install -d -m 0700 -o "$MON_USER" -g "$MON_USER" "$STATE_DIR"
install -d -m 0750 -o root -g "$MON_USER" "$CONF_DIR"

# 显示名和额度：给了就更新，没给保留原值
if [[ -n $LABEL || -n $QUOTA_GB || -n $QUOTA_BASIS || ! -f $CONF_DIR/config.json ]]; then
  tmpconf=$(mktemp)
  LABEL=$LABEL QUOTA_GB=$QUOTA_GB QUOTA_BASIS=$QUOTA_BASIS CONF=$CONF_DIR/config.json python3 -I -c '
import json, os
try:
    with open(os.environ["CONF"]) as f:
        c = json.load(f)
    c = c if isinstance(c, dict) else {}
except (OSError, ValueError):
    c = {}
c.setdefault("label", "VPS"); c.setdefault("quota_gb", 1024); c.setdefault("quota_basis", "tx")
if os.environ["LABEL"]: c["label"] = os.environ["LABEL"]
if os.environ["QUOTA_GB"]: c["quota_gb"] = int(os.environ["QUOTA_GB"])
if os.environ["QUOTA_BASIS"]: c["quota_basis"] = os.environ["QUOTA_BASIS"]
print(json.dumps(c))' >"$tmpconf"
  install -m 0640 -o root -g "$MON_USER" "$tmpconf" "$CONF_DIR/config.json"
  rm -f "$tmpconf"
fi
[[ -f $CONF_DIR/vultr.key ]] && chown root:"$MON_USER" "$CONF_DIR/vultr.key" && chmod 0640 "$CONF_DIR/vultr.key"

# ---------- 定时器：服务器每 5 分钟自己采样一次 ----------
log "启用定时采样（每 5 分钟，$UNIT.timer）"
cat >"/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=Lotus VPS monitor sample (read-only)
After=network-online.target

[Service]
Type=oneshot
User=$MON_USER
Group=$MON_USER
ExecStart=$APP_BIN --collect
TimeoutStartSec=90
Nice=10
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
EOF
cat >"/etc/systemd/system/$UNIT.timer" <<EOF
[Unit]
Description=Lotus VPS monitor sample every 5 minutes

[Timer]
OnActiveSec=1min
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF
chmod 0644 "/etc/systemd/system/$UNIT.service" "/etc/systemd/system/$UNIT.timer"
systemctl daemon-reload
systemctl enable --now "$UNIT.timer" >/dev/null 2>&1 || warn "定时器启动失败：systemctl status $UNIT.timer"

# ---------- 钥匙：强制命令 + restrict（两把钥匙各管各的，更新一把不影响另一把） ----------
if [[ -n $PUBKEY || -n $APP_KEY ]]; then
  tmpauth=$(mktemp)
  STATS_LINE="" APP_LINE=""
  [[ -n $PUBKEY ]] && STATS_LINE="restrict,command=\"$STATS_BIN\" $PUBKEY"
  [[ -n $APP_KEY ]] && APP_LINE="restrict,command=\"$APP_BIN\" $APP_KEY"
  STATS_LINE=$STATS_LINE APP_LINE=$APP_LINE KEYS=$KEYS_FILE STATS_BIN=$STATS_BIN APP_BIN=$APP_BIN python3 -I -c '
import os
e = os.environ
lines = []
try:
    with open(e["KEYS"]) as f:
        lines = [l.rstrip("\n") for l in f if l.strip()]
except OSError:
    pass
def role(line):
    for name in ("STATS_BIN", "APP_BIN"):
        if line.startswith("restrict,command=\"%s\" " % e[name]):
            return name
    return None
out = []
for line in lines:
    r = role(line)
    if r == "STATS_BIN" and e["STATS_LINE"]: continue
    if r == "APP_BIN" and e["APP_LINE"]: continue
    if r is None: continue          # 只保留本脚本写入的两类钥匙
    out.append(line)
out += [l for l in (e["STATS_LINE"], e["APP_LINE"]) if l]
print("\n".join(out))' >"$tmpauth"
  install -m 0644 -o root -g root "$tmpauth" "$KEYS_FILE"
  rm -f "$tmpauth"
  [[ -n $PUBKEY ]] && log "已写入 Termux 监控钥匙（强制命令 $STATS_BIN）"
  [[ -n $APP_KEY ]] && log "已写入 App 钥匙（强制命令 $APP_BIN，只读，不能开 shell、不能转发端口）"
fi

# ---------- sshd 是否允许这个账号用钥匙登录（只检查，不修改） ----------
sshd_eff=$(sshd_effective)
if [[ -z $sshd_eff ]]; then
  warn "无法读取 sshd 生效配置，跳过检查"
else
  if grep -qi '^pubkeyauthentication no' <<<"$sshd_eff"; then
    warn "sshd 关闭了钥匙登录，监控账号将无法登录"
  fi
  if grep -qiE '^(allowusers|allowgroups) ' <<<"$sshd_eff" && ! grep -qiE "^allowusers .*\b$MON_USER\b" <<<"$sshd_eff"; then
    warn "sshd 设置了 AllowUsers/AllowGroups，可能挡住 $MON_USER（本脚本不改 sshd，需要的话手动加）"
  fi
  if grep -q "command=\"$APP_BIN\"" "$KEYS_FILE" 2>/dev/null; then
    # App 只用这一组算法（Android 原生支持）：缺一项就连不上
    for want in "kexalgorithms ecdh-sha2-nistp256" "hostkeyalgorithms ecdsa-sha2-nistp256" \
                "pubkeyacceptedalgorithms ecdsa-sha2-nistp256" "ciphers aes128-ctr|aes256-ctr" \
                "macs hmac-sha2-256-etm@openssh.com|hmac-sha2-256"; do
      key=${want%% *}; pattern=${want#* }
      value=$(awk -v k="$key" '$1==k {print $2; exit}' <<<"$sshd_eff")
      if [[ -n $value ]] && ! grep -qE "(^|,)($pattern)(,|$)" <<<"$value"; then
        warn "sshd 的 $key 不含 ${pattern//|/ 或 }，App 将无法连接（本脚本不改 sshd）"
      fi
    done
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
if run_app --collect; then
  state=$(run_app | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("state"), "·", d.get("overall"))') \
    || die "服务器自采样程序输出不对"
  log "服务器自采样：$state（之后每 5 分钟一次）"
else
  warn "服务器自采样第一次运行失败：bash setup-monitor.sh --test 查看"
fi

if grep -q "command=\"$STATS_BIN\"" "$KEYS_FILE" 2>/dev/null; then
  fp=$(grep "command=\"$STATS_BIN\"" "$KEYS_FILE" | sed 's/^restrict,command="[^"]*" //' | ssh-keygen -l -f - 2>/dev/null | awk '{print $2}' || true)
  log "Termux 监控钥匙指纹：${fp:-未知}（验证：ssh -i ~/.ssh/lotus_vps_monitor -o IdentitiesOnly=yes $MON_USER@<VPS IP>）"
fi
if grep -q "command=\"$APP_BIN\"" "$KEYS_FILE" 2>/dev/null; then
  print_pairing || true
else
  log "完成。要让 App 直接读取：在 Lotus Lab → Activity → VPS → Direct 复制安装命令运行"
fi
