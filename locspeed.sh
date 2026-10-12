#!/usr/bin/env bash
#
# locspeed.sh — live local-network connections + speed monitor
# Single-file, zero-dependency (curl/awk/netstat/ping only), bash 3.2 compatible.
#
# Local run:   bash locspeed.sh [--interval 2] [--once] [--json] [--no-color]
# Remote run:  bash <(curl -fsSL https://raw.githubusercontent.com/organicnz/locspeedtest/HEAD/locspeed.sh)
# Pipe mode:   curl -fsSL .../locspeed.sh | bash -s -- --once
#
# No sudo, no writes outside ${TMPDIR:-/tmp}, HTTPS only.
#
set -euo pipefail
IFS=$' \t\n'
umask 022

VERSION="1.4.0"
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
  bash <(curl -fsSL https://raw.githubusercontent.com/organicnz/locspeedtest/HEAD/locspeed.sh) [options]
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

# ---------------------------------------------------------------- table ui
# Inner table width, derived from the terminal so borders always align.
# ANSI escapes are zero-width, so every cell is built from its PLAIN text
# length and colored afterwards — that is what keeps the columns straight.
TW=78
if [ -t 1 ]; then
  _cols="$(tput cols 2>/dev/null || echo 80)"
  case "$_cols" in ''|*[!0-9]*) _cols=80;; esac
  [ "$_cols" -gt 78 ] && _cols=78
  [ "$_cols" -lt 56 ] && _cols=56
  TW=$((_cols - 2))
  unset _cols
fi

fill_char() { # repeat $2 as char $1 times
  printf "%-*s" "$1" "" | tr ' ' "$2"
}

padstr() { # left-justify $1 in $2 columns
  printf "%-*s" "$2" "$1"
}

ttop() { # ttop PLAINTEXT COLOR
  printf '┌─ %s%s%s %s┐\n' "$2" "$1" "$C_RST" "$(fill_char $(( TW - ${#1} - 5 )) '─')"
}

tline() {
  printf '├%s┤\n' "$(fill_char "$TW" '─')"
}

tsec() { # tsec TITLE
  printf '├─ %s%s %s┤\n' "$C_DIM$1$C_RST" "" "$(fill_char $(( TW - ${#1} - 5 )) '─')"
}

# Token row with automatic wrapping: each COLORED/PLAIN pair is kept whole and
# moved to the next line when it would overflow, so nothing is ever truncated.
# COLORED may contain ANSI escapes; PLAIN is its visible text (for width math).
trowt() { # trowt COLORED PLAIN [COLORED PLAIN ...]
  local avail=$(( TW - 3 ))
  local -a cs=() ps=()
  while [ $# -ge 2 ]; do
    cs[${#cs[@]}]="$1"; ps[${#ps[@]}]="$2"; shift 2
  done
  local n=${#ps[@]} i l="" ll=0
  for ((i=0; i<n; i++)); do
    if [ $(( ll + ${#ps[i]} )) -gt "$avail" ] && [ "$ll" -gt 0 ]; then
      printf '│ %s%*s│\n' "$l" "$(( avail - ll ))" ""
      l=""; ll=0
    fi
    l="${l}${cs[i]:-${ps[i]}}"
    ll=$(( ll + ${#ps[i]} ))
  done
  [ "$ll" -gt 0 ] && printf '│ %s%*s│\n' "$l" "$(( avail - ll ))" ""
  return 0
}

# sep — a plain gap between tokens on a row
SEP="    "

tbot() { # tbot HINT (empty hint = solid bottom rule)
  local h="$1"
  if [ -z "$h" ]; then
    printf '└%s┘\n' "$(fill_char $(( TW - 2 )) '─')"
  else
    printf '└── %s %s┘\n' "$h" "$(fill_char $(( TW - ${#h} - 6 )) '─')"
  fi
}

# host_pairs "count<TAB>host" lines for the connections panel
host_pairs() {
  netstat -an 2>/dev/null | grep -E '^tcp' | grep ESTABLISHED | awk '{print $5}' \
    | sed 's/\.[0-9][0-9]*$//' | sort | uniq -c | sort -rn | head -6 \
    | awk -F' ' '{printf "%s\t%s\n", $1, $2}'
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
  # top-process table columns (narrowed when the terminal is small)
  local cn=18 cd=10 cu=10 cb=10
  local cg c1 c8 now
  cg="$(color_for_ms "$pg")"; c1="$(color_for_ms "$p1")"; c8="$(color_for_ms "$p8")"
  now="$(date '+%H:%M:%S' 2>/dev/null || echo "??:??:??")"

  # ---------- header ----------
  ttop "locspeed v${VERSION}  │  iface ${ifx}  │  ${now}" "$C_BLD$C_CYN"

  # ---------- speed ----------
  tsec "SPEED"
  if [ -n "$lt" ] && [ "$lt" != "—" ]; then
    trowt "${C_GRN}down ${down}${C_RST}" "down ${down}" "" "$SEP" \
          "${C_GRN}up ${up}${C_RST}" "up ${up}" "" "$SEP" \
          "${C_BLD}full-test ${lt} Mb/s${C_RST}" "full-test ${lt} Mb/s"
  else
    trowt "${C_GRN}down ${down}${C_RST}" "down ${down}" "" "$SEP" \
          "${C_GRN}up ${up}${C_RST}" "up ${up}"
  fi

  # ---------- local ----------
  tsec "LOCAL"
  trowt "${C_DIM}ip${C_RST} ${lip}" "ip ${lip}" "" "$SEP" \
        "${C_DIM}gateway${C_RST} ${gw}" "gateway ${gw}" "" "$SEP" \
        "${C_DIM}dns${C_RST} ${dns}" "dns ${dns}"
  trowt "${C_DIM}wifi${C_RST} ${wifi}" "wifi ${wifi}"
  tsec "PUBLIC"
  trowt "${C_BLU}${pub}${C_RST}" "$pub"

  # ---------- connections ----------
  tsec "CONNECTIONS"
  trowt "${C_DIM}total${C_RST} ${C_BLD}${t}${C_RST}" "total ${t}" "" "$SEP" \
        "${C_DIM}established${C_RST} ${C_GRN}${e}${C_RST}" "established ${e}" "" "$SEP" \
        "${C_DIM}time-wait${C_RST} ${w}" "time-wait ${w}" "" "$SEP" \
        "${C_DIM}listen${C_RST} ${l}" "listen ${l}"
  local -a htoks=()
  while IFS=$'\t' read -r hc ha; do
    [ -z "${ha:-}" ] && continue
    htoks[${#htoks[@]}]="${C_DIM}· ${hc}x ${ha}${C_RST}"
    htoks[${#htoks[@]}]="· ${hc}x ${ha}"
    htoks[${#htoks[@]}]=""
    htoks[${#htoks[@]}]="$SEP"
  done < <(host_pairs)
  if [ ${#htoks[@]} -gt 0 ]; then
    unset "htoks[${#htoks[@]}-1]"
    trowt "${htoks[@]}"
  fi

  # ---------- top processes ----------
  if [ "$NO_TOP" = "0" ]; then
    case "$topstate" in
      fallback)
        tsec "TOP BY CONNECTIONS"
        trowt "${C_DIM}(no per-process counters on this OS)${C_RST}" "(no per-process counters on this OS)"
        local -a ftoks=()
        while IFS=$'\t' read -r hc ha; do
          [ -z "${ha:-}" ] && continue
          ftoks[${#ftoks[@]}]="${C_DIM}· ${hc}x ${ha}${C_RST}"
          ftoks[${#ftoks[@]}]="· ${hc}x ${ha}"
          ftoks[${#ftoks[@]}]=""
          ftoks[${#ftoks[@]}]="$SEP"
        done < <(host_pairs)
        if [ ${#ftoks[@]} -gt 0 ]; then
          unset "ftoks[${#ftoks[@]}-1]"
          trowt "${ftoks[@]}"
        fi
        ;;
      live)
        tsec "TOP PROCESSES"
        trowt "${C_DIM}$(printf '%-*s' "$cn" "PROCESS")${C_RST}" "$(printf '%-*s' "$cn" "PROCESS")" "" " " \
              "${C_DIM}$(printf '%-*s' "$cd" "DOWN")${C_RST}" "$(printf '%-*s' "$cd" "DOWN")" "" " " \
              "${C_DIM}$(printf '%-*s' "$cu" "UP")${C_RST}" "$(printf '%-*s' "$cu" "UP")" "" " " \
              "${C_DIM}$(printf '%-*s' "$cb" "SHARE")${C_RST}" "$(printf '%-*s' "$cb" "SHARE")"
        top_total="$(printf "%s\n" "$topsample" | head -n1 | cut -f1)"
        case "$top_total" in ''|*[!0-9]*) top_total=0;; esac
        while IFS=$'\t' read -r stotal sname sin sout; do
          [ -z "${sname:-}" ] && continue
          if [ "$top_total" -gt 0 ]; then pct=$(( stotal * 100 / top_total )); else pct=0; fi
          trowt "${C_BLD}$(printf '%-*s' "$cn" "${sname:0:cn}")${C_RST}" "$(printf '%-*s' "$cn" "${sname:0:cn}")" "" " " \
                "${C_GRN}$(printf '%-*s' "$cd" "$(human_rate "${sin:-0}")")${C_RST}" "$(printf '%-*s' "$cd" "$(human_rate "${sin:-0}")")" "" " " \
                "${C_GRN}$(printf '%-*s' "$cu" "$(human_rate "${sout:-0}")")${C_RST}" "$(printf '%-*s' "$cu" "$(human_rate "${sout:-0}")")" "" " " \
                "${C_DIM}$(printf '%-*s' "$cb" "$(bar "$pct" "$cb")")${C_RST}" "$(printf '%-*s' "$cb" "$(bar "$pct" "$cb")")"
        done < <(printf "%s\n" "$topsample")
        ;;
      sampling)
        tsec "TOP PROCESSES"
        trowt "${C_DIM}(sampling…)${C_RST}" "(sampling…)"
        ;;
      *)
        tsec "TOP PROCESSES"
        trowt "${C_DIM}(idle — no process traffic this interval)${C_RST}" "(idle — no process traffic this interval)"
        ;;
    esac
  fi

  # ---------- ping ----------
  tsec "PING"
  trowt "${C_DIM}gateway${C_RST} $cg${pg} ms${C_RST}" "gateway ${pg} ms" "" "$SEP" \
        "${C_DIM}1.1.1.1${C_RST} $c1${p1} ms${C_RST}" "1.1.1.1 ${p1} ms" "" "$SEP" \
        "${C_DIM}8.8.8.8${C_RST} $c8${p8} ms${C_RST}" "8.8.8.8 ${p8} ms"
  trowt "${C_DIM}trend${C_RST} $C_CYN$(spark "$hist")${C_RST}" "trend $(spark "$hist")"

  # ---------- footer ----------
  if [ "$INTERACTIVE" = "1" ]; then
    tbot "[t] speed test   [q] quit"
  else
    tbot ""
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
