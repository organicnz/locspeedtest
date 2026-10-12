#!/usr/bin/env bash
#
# locspeed.sh — live local-network connections + speed monitor
# Single-file, zero-dependency (curl/awk/netstat/ping only), bash 3.2 compatible.
#
# Local run:   bash locspeed.sh [--interval 2] [--once] [--json] [--no-color]
# Remote run:  bash <(curl -fsSL https://raw.githubusercontent.com/organicnz/locspeedtest/v1.0.0/locspeed.sh)
# Pipe mode:   curl -fsSL .../locspeed.sh | bash -s -- --once
#
# No sudo, no writes outside ${TMPDIR:-/tmp}, HTTPS only.
#
set -euo pipefail
IFS=$' \t\n'
umask 022

VERSION="1.0.0"
INTERVAL=2
ONCE=0
JSON=0
NO_COLOR=0
NO_PUBIP=0
NO_TOP=0
TOP_PREV="${TMPDIR:-/tmp}/.locspeed_topprev.$$"
TOP_CUR="${TMPDIR:-/tmp}/.locspeed_topcur.$$"
IFACE=""
TEST_BYTES=25000000   # 25 MB Cloudflare download probe
PUBIP_TTL=300         # seconds to cache public IP in /tmp

# ---------------------------------------------------------------- args
usage() {
  cat <<EOF
locspeed v${VERSION} — live connections + speed in your terminal

Usage:
  bash locspeed.sh [options]
  bash <(curl -fsSL https://raw.githubusercontent.com/organicnz/locspeedtest/v1.0.0/locspeed.sh) [options]
  curl -fsSL .../locspeed.sh | bash -s -- [options]

Options:
  --interval N   refresh seconds (default 2, min 1)
  --iface NAME   force interface (default: route default)
  --once         print one snapshot, exit (no loop)
  --json         one JSON snapshot on stdout, exit (no colors, no loop)
  --no-color     disable ANSI colors (also honors NO_COLOR=1)
  --no-pubip     skip public-IP lookup (faster, fully offline-safe)
  --no-top       hide the live per-process top section
  -h, --help     this help
  -v, --version  version

Keys (interactive TTY only):  t = full speed test   q = quit
EOF
}

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    --interval=*) INTERVAL="${1#--interval=}"; shift ;;
    --iface) IFACE="${2:-}"; shift 2 ;;
    --iface=*) IFACE="${1#--iface=}"; shift ;;
    --once) ONCE=1; shift ;;
    --json) JSON=1; shift ;;
    --no-color) NO_COLOR=1; shift ;;
    --no-pubip) NO_PUBIP=1; shift ;;
    --no-top) NO_TOP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -v|--version) echo "locspeed v${VERSION}"; exit 0 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1 (see --help)" >&2; exit 2 ;;
    *) break ;;
  esac
done

case "$INTERVAL" in ''|*[!0-9]*) echo "--interval must be an integer" >&2; exit 2;; esac
[ "$INTERVAL" -lt 1 ] && INTERVAL=1

# ---------------------------------------------------------------- tty / color
INTERACTIVE=0
if [ -t 0 ] && [ -t 1 ]; then INTERACTIVE=1; fi
# piped via `curl | bash`: stdin is not a TTY -> never prompt, never read keys
if [ "${NO_COLOR:-0}" = "1" ] || [ "$JSON" = "1" ]; then NO_COLOR=1; fi
if [ "$NO_COLOR" = "0" ] && [ ! -t 1 ]; then NO_COLOR=1; fi

if [ "$NO_COLOR" = "1" ]; then
  C_RST=""; C_BLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_MAG=""; C_CYN=""
else
  C_RST=$'\033[0m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_MAG=$'\033[35m'; C_CYN=$'\033[36m'
fi

OS="$(uname -s 2>/dev/null || echo unknown)"

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- detectors
default_iface() {
  local ifx=""
  if [ "$OS" = "Darwin" ]; then
    ifx="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
  else
    if has_cmd ip; then
      ifx="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    fi
    if [ -z "$ifx" ]; then
      ifx="$(route -n 2>/dev/null | awk '$1=="0.0.0.0"{print $NF; exit}')"
    fi
  fi
  echo "$ifx"
}

local_ip() {
  local ifx="$1" ip=""
  if [ "$OS" = "Darwin" ] && has_cmd ipconfig; then
    ip="$(ipconfig getifaddr "$ifx" 2>/dev/null || true)"
  fi
  if [ -z "$ip" ] && has_cmd ip; then
    ip="$(ip -4 addr show "$ifx" 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')"
  fi
  if [ -z "$ip" ] && has_cmd hostname; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [ -z "$ip" ] && ip="—"
  echo "$ip"
}

gateway() {
  local gw=""
  if [ "$OS" = "Darwin" ]; then
    gw="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')"
  elif has_cmd ip; then
    gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
  fi
  [ -z "$gw" ] && gw="—"
  echo "$gw"
}

dns_server() {
  local dns=""
  if [ "$OS" = "Darwin" ] && has_cmd scutil; then
    dns="$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3; exit}')"
  fi
  if [ -z "$dns" ] && [ -f /etc/resolv.conf ]; then
    dns="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)"
  fi
  [ -z "$dns" ] && dns="—"
  echo "$dns"
}

ssid() {
  local s="—"
  if [ "$OS" = "Darwin" ] && has_cmd networksetup; then
    # prints "Current Wi-Fi Network: NAME" or "You are not associated…"
    s="$(networksetup -getairportnetwork en0 2>/dev/null | sed 's/^Current Wi-Fi Network: //')"
    case "$s" in *"not associated"*) s="— (wired)";; ""*) s="—";; esac
  elif has_cmd iwgetid; then
    s="$(iwgetid -r 2>/dev/null || echo "—")"
  fi
  echo "$s"
}

# Cached public IP in /tmp only (respects TMPDIR). Never fails the loop.
public_ip() {
  [ "$NO_PUBIP" = "1" ] && { echo "skipped"; return; }
  ! has_cmd curl && { echo "—"; return; }
  local cache="${TMPDIR:-/tmp}/.locspeed_pubip" now ts=0 cached=""
  now="$(date +%s 2>/dev/null || echo 0)"
  if [ -f "$cache" ]; then
    cached="$(head -n1 "$cache" 2>/dev/null || true)"
    ts="$(tail -n1 "$cache" 2>/dev/null || echo 0)"
    case "$ts" in ''|*[!0-9]*) ts=0;; esac
    if [ -n "$cached" ] && [ $((now - ts)) -lt "$PUBIP_TTL" ]; then echo "$cached"; return; fi
  fi
  local ip=""
  ip="$(curl -fsSL --max-time 4 --proto '=https' https://ifconfig.me 2>/dev/null | head -c 64 || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -fsSL --max-time 4 --proto '=https' https://icanhazip.com 2>/dev/null | tr -d ' \t\r\n' || true)"
  fi
  ip="$(echo "$ip" | tr -d ' \t\r\n')"
  if [ -z "$ip" ]; then echo "offline"; return; fi
  { echo "$ip"; echo "$now"; } > "$cache" 2>/dev/null || true
  echo "$ip"
}

# "rx_bytes tx_bytes" for iface, or "0 0"
iface_bytes() {
  local ifx="$1"
  if [ "$OS" = "Darwin" ]; then
    netstat -ib 2>/dev/null | awk -v f="$ifx" '$1==f && $3 ~ /^<Link/ {print $7" "$10; exit}'
  else
    if [ -f "/sys/class/net/$ifx/statistics/rx_bytes" ]; then
      echo "$(cat "/sys/class/net/$ifx/statistics/rx_bytes" 2>/dev/null || echo 0) $(cat "/sys/class/net/$ifx/statistics/tx_bytes" 2>/dev/null || echo 0)"
    elif [ -f /proc/net/dev ]; then
      awk -v f="$ifx:" '$1==f {print $2" "$10; exit}' /proc/net/dev 2>/dev/null || echo "0 0"
    else
      echo "0 0"
    fi
  fi
}

# "total estab wait listen"
tcp_counts() {
  local t=0 e=0 w=0 l=0 line
  if has_cmd ss; then
    line="$(ss -s 2>/dev/null | grep -i '^TCP:' | head -n1 || true)"
    # "TCP:   42 (estab 30, closed 5, ...)" — best effort parse
    t="$(echo "$line" | sed -n 's/.*TCP:[^0-9]*\([0-9][0-9]*\).*/\1/p')"
    e="$(echo "$line" | sed -n 's/.*estab[^0-9]*\([0-9][0-9]*\).*/\1/p')"
    [ -z "$t" ] && t=0; [ -z "$e" ] && e=0
    if has_cmd netstat; then
      w="$(netstat -an 2>/dev/null | grep -cE '^tcp.*TIME_WAIT' || true)"
      l="$(netstat -an 2>/dev/null | grep -cE '^tcp.*LISTEN' || true)"
    fi
  else
    local states
    states="$(netstat -an 2>/dev/null | grep -E '^tcp' | awk '{print $NF}' || true)"
    [ -z "$states" ] && { echo "0 0 0 0"; return; }
    t="$(echo "$states" | wc -l | tr -d ' ')"
    e="$(echo "$states" | grep -c ESTABLISHED || true)"
    w="$(echo "$states" | grep -c TIME_WAIT || true)"
    l="$(echo "$states" | grep -c LISTEN || true)"
  fi
  echo "${t:-0} ${e:-0} ${w:-0} ${l:-0}"
}

top_hosts() {
  netstat -an 2>/dev/null | grep -E '^tcp' | grep ESTABLISHED | awk '{print $5}' \
    | sed 's/\.[0-9][0-9]*$//' | sort | uniq -c | sort -rn | head -5 \
    | awk '{printf "      %4dx  %s\n", $1, $2}' || true
}

# Live per-process traffic rates via macOS nettop (cumulative counters diffed
# across calls). Prints tab-separated "total name in_rps out_rps" top-5 lines.
# Prints nothing on the first call (baseline only) or when idle. Always 0.
sample_top() { # sample_top <interval_sec>
  local dt="$1"
  case "$dt" in ''|*[!0-9]*) dt=1;; esac
  [ "$dt" -ge 1 ] || dt=1
  [ "$OS" = "Darwin" ] || return 0
  has_cmd nettop || return 0
  nettop -P -L 1 2>/dev/null | awk -F, '
    $1=="time" {next}
    $2!="" && ($5+0>0 || $6+0>0) {n=$2; sub(/\.[0-9]+$/,"",n); i[n]+=$5; o[n]+=$6}
    END{for(n in i) printf "%s\t%d\t%d\n", n, i[n], o[n]}' | sort > "$TOP_CUR" 2>/dev/null || return 0
  if [ -f "$TOP_PREV" ]; then
    awk -F'\t' -v dt="$dt" '
      NR==FNR{pi[$1]=$2; po[$1]=$3; next}
      {di=$2-(pi[$1]+0); ou=$3-(po[$1]+0); if(di<0)di=0; if(ou<0)ou=0; t=di+ou;
       if(t>0) printf "%d\t%s\t%d\t%d\n", t, $1, int(di/dt), int(ou/dt)}' \
      "$TOP_PREV" "$TOP_CUR" 2>/dev/null | sort -rn | head -5
  fi
  mv -f "$TOP_CUR" "$TOP_PREV" 2>/dev/null || true
  return 0
}

ping_ms() {
  local host="$1" out ms
  if [ "$OS" = "Darwin" ]; then
    out="$(ping -c1 -t1 "$host" 2>/dev/null | grep -o 'time=[0-9.]* ms' | head -n1 || true)"
  else
    out="$(ping -c1 -W1 "$host" 2>/dev/null | grep -o 'time=[0-9.]* ms' | head -n1 || true)"
  fi
  ms="$(echo "$out" | sed 's/time=//;s/ ms//')"
  [ -z "$ms" ] && ms="timeout"
  echo "$ms"
}

# ---------------------------------------------------------------- format
human_rate() { # bytes/sec -> "12.4 Mb/s"
  awk -v b="${1:-0}" 'BEGIN{m=b*8/1000000; if(m>=100)printf "%.0f Mb/s",m; else if(m>=1)printf "%.1f Mb/s",m; else printf "%.0f Kb/s",m*1000}'
}

color_for_ms() { # echoes color var name content
  local ms="$1"
  [ "$ms" = "timeout" ] && { printf "%s" "$C_RED"; return; }
  awk -v m="$ms" 'BEGIN{exit !(m<30)}' && { printf "%s" "$C_GRN"; return; }
  awk -v m="$ms" 'BEGIN{exit !(m<100)}' && { printf "%s" "$C_YEL"; return; }
  printf "%s" "$C_RED"
}

bar() { # bar <pct 0-100> <width>
  local pct="$1" w="$2" f i s=""
  [ "$pct" -gt 100 ] && pct=100
  f=$((pct * w / 100))
  i=0; while [ "$i" -lt "$f" ]; do s="${s}█"; i=$((i+1)); done
  while [ "$i" -lt "$w" ]; do s="${s}░"; i=$((i+1)); done
  printf "%s" "$s"
}

spark() { # spark "12 40 timeout 15" -> blocks
  local v out="" b
  for v in $1; do
    if [ "$v" = "timeout" ]; then b="×";
    elif awk -v m="$v" 'BEGIN{exit !(m<20)}'; then b="▁";
    elif awk -v m="$v" 'BEGIN{exit !(m<40)}'; then b="▂";
    elif awk -v m="$v" 'BEGIN{exit !(m<70)}'; then b="▃";
    elif awk -v m="$v" 'BEGIN{exit !(m<120)}'; then b="▄";
    elif awk -v m="$v" 'BEGIN{exit !(m<200)}'; then b="▅";
    else b="▆"; fi
    out="${out}${b}"
  done
  printf "%s" "$out"
}

push_hist() { # push_hist "var" value maxlen — appends, trims from left
  local var="$1" val="$2" max="$3" cur n
  eval "cur=\$$var"
  cur="${cur} ${val}"
  n="$(echo "$cur" | wc -w | tr -d ' ')"
  while [ "$n" -gt "$max" ]; do cur="${cur#* }"; n=$((n-1)); done
  eval "$var=\$cur"
}

# Full download probe. Prints Mbps or "fail". TTY shows curl progress bar.
speed_test_mbps() {
  ! has_cmd curl && { echo "fail (no curl)"; return; }
  local url="https://speed.cloudflare.com/__down?bytes=${TEST_BYTES}" raw mbps
  if [ "$INTERACTIVE" = "1" ]; then
    printf "  probing %s …\n" "$url" >&2
    raw="$(curl -L --progress-bar --max-time 30 --proto '=https' -o /dev/null -w "%{speed_download}" "$url" 2>/dev/stderr || echo 0)"
  else
    raw="$(curl -fsSL --max-time 30 --proto '=https' -o /dev/null -w "%{speed_download}" "$url" 2>/dev/null || echo 0)"
  fi
  case "$raw" in ''|*[!0-9.]*) echo "fail"; return;; esac
  mbps="$(awk -v b="$raw" 'BEGIN{printf "%.1f", b*8/1000000}')"
  awk -v m="$mbps" 'BEGIN{exit !(m>0.05)}' || { echo "fail"; return; }
  echo "$mbps"
}

# ---------------------------------------------------------------- snapshot
snapshot_human() { # args: iface lip gw dns wifi pubip counts down up ping_gw ping_11 ping_88 hist lasttest topsample topstate
  local ifx="$1" lip="$2" gw="$3" dns="$4" wifi="$5" pub="$6"
  local t="$7" e="$8" w="$9" l="${10}" down="${11}" up="${12}"
  local pg="${13}" p1="${14}" p8="${15}" hist="${16}" lt="${17}"
  local topsample="${18:-}" topstate="${19:-live}"
  local top_total=0 pct=0 stotal="" sname="" sin="" sout=""
  local cg c1 c8 now
  cg="$(color_for_ms "$pg")"; c1="$(color_for_ms "$p1")"; c8="$(color_for_ms "$p8")"
  now="$(date '+%H:%M:%S' 2>/dev/null || echo "??:??:??")"

  printf "%s%s locspeed v%s %s│%s %s %s│%s iface %s%s\n" \
    "$C_BLD" "$C_CYN" "$VERSION" "$C_DIM" "$C_RST$C_DIM" "$now" "$C_DIM" "$C_RST$C_BLD" "$ifx" "$C_RST"
  printf "%s─ local ─%s  ip %s%s%s  gw %s  dns %s  wifi %s%s%s\n" \
    "$C_DIM" "$C_RST" "$C_BLD" "$lip" "$C_RST" "$gw" "$dns" "$C_DIM" "$wifi" "$C_RST"
  printf "%s─ public ─%s  %s%s%s\n" "$C_DIM" "$C_RST" "$C_BLU" "$pub" "$C_RST"
  printf "%s─ conns ─%s  total %s%d%s  estab %s%d%s  wait %d  listen %d\n" \
    "$C_DIM" "$C_RST" "$C_BLD" "$t" "$C_RST" "$C_GRN" "$e" "$C_RST" "$w" "$l"
  printf "%s  top talkers:%s\n" "$C_DIM" "$C_RST"
  top_hosts
  if [ "$NO_TOP" = "0" ]; then
    if [ "$topstate" = "fallback" ]; then
      printf "%s─ top ─%s  %sby connections (no per-process counters on this OS)%s\n" "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
      top_hosts
    elif [ -n "$topsample" ]; then
      printf "%s─ top ─%s  %slive per-process%s\n" "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
      top_total="$(printf "%s\n" "$topsample" | head -n1 | cut -f1)"
      case "$top_total" in ''|*[!0-9]*) top_total=0;; esac
      printf "%s\n" "$topsample" | while IFS=$'\t' read -r stotal sname sin sout; do
        if [ "$top_total" -gt 0 ]; then pct=$(( stotal * 100 / top_total )); else pct=0; fi
        printf "  %s%-16.16s%s  %s↓%s %s%s%s  %s↑%s %s%s%s  %s%s%s\n" \
          "$C_BLD" "$sname" "$C_RST" \
          "$C_DIM" "$C_RST" "$C_GRN" "$(human_rate "${sin:-0}")" "$C_RST" \
          "$C_DIM" "$C_RST" "$C_GRN" "$(human_rate "${sout:-0}")" "$C_RST" \
          "$C_DIM" "$(bar "$pct" 10)" "$C_RST"
      done
    elif [ "$topstate" = "sampling" ]; then
      printf "%s─ top ─%s  %s(sampling…)%s\n" "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
    else
      printf "%s─ top ─%s  %s(idle — no process traffic this interval)%s\n" "$C_DIM" "$C_RST" "$C_DIM" "$C_RST"
    fi
  fi
  printf "%s─ ping ─%s   gw %s%s ms%s   1.1.1.1 %s%s ms%s   8.8.8.8 %s%s ms%s\n" \
    "$C_DIM" "$C_RST" "$cg" "$pg" "$C_RST" "$c1" "$p1" "$C_RST" "$c8" "$p8" "$C_RST"
  printf "%s  trend %s %s%s\n" "$C_DIM" "$(spark "$hist")" "$C_RST"
  printf "%s─ speed ─%s  down %s%s%s  up %s%s%s" \
    "$C_DIM" "$C_RST" "$C_GRN" "$down" "$C_RST" "$C_GRN" "$up" "$C_RST"
  if [ -n "$lt" ] && [ "$lt" != "—" ]; then
    printf "  full-test %s%s Mb/s%s" "$C_BLD" "$lt" "$C_RST"
  fi
  printf "\n"
  if [ "$INTERACTIVE" = "1" ]; then
    printf "%s[t] speed test   [q] quit%s\n" "$C_DIM" "$C_RST"
  fi
}

snapshot_json() {
  printf '{"version":"%s","iface":"%s","local_ip":"%s","gateway":"%s","dns":"%s","wifi":"%s","public_ip":"%s","tcp_total":%s,"tcp_estab":%s,"tcp_wait":%s,"tcp_listen":%s,"ping_gw_ms":"%s","ping_1111_ms":"%s","ping_8888_ms":"%s","live_down":"%s","live_up":"%s","full_test_mbps":"%s"}\n' \
    "$VERSION" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}" "${14}" "${15}" "${16}"
}

# ---------------------------------------------------------------- main
main() {
  [ -z "$IFACE" ] && IFACE="$(default_iface)"
  [ -z "$IFACE" ] && { echo "no default route found (offline?)" >&2; exit 1; }

  local gw dns wifi pub lip
  local TOP_SAMPLE="" TOP_STATE="live"
  gw="$(gateway)"
  dns="$(dns_server)"
  wifi="$(ssid)"
  lip="$(local_ip "$IFACE")"
  if [ "$JSON" = "1" ] || [ "$ONCE" = "1" ] || [ "$NO_PUBIP" = "0" ]; then
    pub="$(public_ip)"
  else
    pub="skipped"
  fi

  # one-shot modes (also what `curl | bash -s -- --json` uses)
  if [ "$JSON" = "1" ] || [ "$ONCE" = "1" ]; then
    c="$(tcp_counts)"
    # shellcheck disable=SC2086
    set -- $c; ct=${1:-0}; ce=${2:-0}; cw=${3:-0}; cl=${4:-0}
    b="$(iface_bytes "$IFACE")"
    # shellcheck disable=SC2086
    set -- $b; r0=${1:-0}; t0=${2:-0}
    if [ "$ONCE" = "1" ] && [ "$NO_TOP" = "0" ]; then
      if [ "$OS" = "Darwin" ] && has_cmd nettop; then
        rm -f "$TOP_PREV" "$TOP_CUR" 2>/dev/null || true
        sample_top "$INTERVAL" >/dev/null
      else
        TOP_STATE="fallback"
      fi
    fi
    sleep 1
    b="$(iface_bytes "$IFACE")"
    # shellcheck disable=SC2086
    set -- $b; r1=${1:-0}; t1=${2:-0}
    down="$(human_rate $((r1 - r0)))"; up="$(human_rate $((t1 - t0)))"
    pg="$(ping_ms "$gw")"; p1="$(ping_ms 1.1.1.1)"; p8="$(ping_ms 8.8.8.8)"
    if [ "$ONCE" = "1" ] && [ "$NO_TOP" = "0" ] && [ "$TOP_STATE" = "live" ]; then
      TOP_SAMPLE="$(sample_top "$INTERVAL")"
    fi
    if [ "$JSON" = "1" ]; then
      snapshot_json "$IFACE" "$lip" "$gw" "$dns" "$wifi" "$pub" "$ct" "$ce" "$cw" "$cl" "$pg" "$p1" "$p8" "$down" "$up" "—"
    else
      snapshot_human "$IFACE" "$lip" "$gw" "$dns" "$wifi" "$pub" "$ct" "$ce" "$cw" "$cl" "$down" "$up" "$pg" "$p1" "$p8" "$pg $p1 $p8" "—" "$TOP_SAMPLE" "$TOP_STATE"
    fi
    rm -f "$TOP_PREV" "$TOP_CUR" 2>/dev/null || true
    return 0
  fi

  # live loop
  trap 'rm -f "$TOP_PREV" "$TOP_CUR" 2>/dev/null; printf "\033[?25h\n"; exit 0' INT TERM
  rm -f "$TOP_PREV" "$TOP_CUR" 2>/dev/null || true
  [ "$INTERACTIVE" = "1" ] && printf "\033[?25l"
  local HIST="" LAST_TEST="—" key r0 t0 r1 t1 down up c pg p1 p8 b
  local ct ce cw cl
  b="$(iface_bytes "$IFACE")"
  # shellcheck disable=SC2086
  set -- $b; r0=${1:-0}; t0=${2:-0}
  while true; do
    printf "\033[H\033[2J"
    c="$(tcp_counts)"
    # shellcheck disable=SC2086
    set -- $c; ct=${1:-0}; ce=${2:-0}; cw=${3:-0}; cl=${4:-0}
    b="$(iface_bytes "$IFACE")"
    # shellcheck disable=SC2086
    set -- $b; r1=${1:-0}; t1=${2:-0}
    # deltas can go negative after sleep/wake or counter wrap — clamp
    [ "$r1" -lt "$r0" ] && r0=$r1
    [ "$t1" -lt "$t0" ] && t0=$t1
    down="$(human_rate $(((r1 - r0) / INTERVAL)))"
    up="$(human_rate $(((t1 - t0) / INTERVAL)))"
    r0=$r1; t0=$t1
    pg="$(ping_ms "$gw")"; p1="$(ping_ms 1.1.1.1)"; p8="$(ping_ms 8.8.8.8)"
    if [ "$NO_TOP" = "0" ]; then
      if [ "$OS" = "Darwin" ] && has_cmd nettop; then
        if [ -f "$TOP_PREV" ]; then TOP_STATE="live"; else TOP_STATE="sampling"; fi
        TOP_SAMPLE="$(sample_top "$INTERVAL")"
      else
        TOP_STATE="fallback"; TOP_SAMPLE=""
      fi
    fi
    push_hist HIST "$p1" 30
    snapshot_human "$IFACE" "$lip" "$gw" "$dns" "$wifi" "$pub" "$ct" "$ce" "$cw" "$cl" "$down" "$up" "$pg" "$p1" "$p8" "$HIST" "$LAST_TEST" "$TOP_SAMPLE" "$TOP_STATE"
    # refresh slow-changing fields occasionally (every ~30s)
    if [ $((SECONDS / 30 % 2)) -eq 0 ]; then
      lip="$(local_ip "$IFACE")"; pub="$(public_ip)"
    fi
    key=""
    if [ "$INTERACTIVE" = "1" ]; then
      IFS= read -r -t "$INTERVAL" -n1 key 2>/dev/null || true
      case "$key" in
        q|Q) printf "\033[?25h\n"; exit 0 ;;
        t|T)
          printf "\033[?25h"
          LAST_TEST="$(speed_test_mbps)"
          [ "$INTERACTIVE" = "1" ] && printf "\033[?25l"
          ;;
      esac
    else
      sleep "$INTERVAL"
    fi
  done
}

main "$@"
