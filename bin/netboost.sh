#!/system/bin/sh
# =====================================================================
#  netboost.sh  —— T5M终极网络优化 · 引擎  v2.4
#  目标机 : REDMI Turbo 5 Max (2602BRT18C / dash / mt6991 / Android 17 / HyperOS V816)
#  运营商 : 中国广电 CHINA BROADNET 46015  NR_SA  n28 30MHz / n41 100MHz
#  用法   : sh netboost.sh {status|json|sig|apply|refresh|restore|reconnect|
#                           bench|benchhist|diag|health|apn|band|watch|sample|
#                           history|probe|events|traffic|report|online}
#  边界   : 运营商侧 QoS / 套餐达量限速 无法本地解除，本脚本只清终端瓶颈。
#
#  v2.4 变更（实测驱动，逐条可验证）
#   1. 新增 traffic：按数据接口独立计量流量（今日/本月/实时速率），
#      持久化到模块 data 目录，处理 reconnect 后计数器清零（重置检测）。
#   2. 新增 events：掉线/重连/温度推迟/链路切换/手动操作全部结构化
#      记账（events.csv），WebUI 可查，运营商投诉有据。
#   3. 新增 benchhist：每次 bench 落档（时间/规模/Mbps），看吞吐趋势、
#      识别达量限速。
#   4. 新增 report：status + health + probe + 事件 + 流量 + 测速 一键汇总。
#   5. EXPECTED 增加 TCP keepalive 三件套：time 7200->300、intvl=30、
#      probes=5，防止长连接被运营商 NAT 静默回收（IM 掉线的常见根因）。
#   6. sample 增加基带温度列，趋势图可见过热与降速的关联。
#   7. 守护防呆：默认路由走 wlan/eth 时不操作蜂窝（连 WiFi 时掉线
#      与蜂窝无关，重连只会白断 10 秒）。
#
#  v2.3 变更（实测驱动，逐条可验证）
#   1. 全部 ICMP 探测改走 busybox ping。Android toybox ping 不认 -4/-6
#      (invalid option, rc=2)，旧版在 /system/bin/sh 路径下恒判"IPv6 不可达"。
#   2. 掉线判定改为 双栈 ICMP + HTTP 204 三通道，任一通即在线；修复每 15 分钟
#      误判一次、白断网 10 秒的问题（v2.2 watch.log 有 22 条 900s 等距记录为证）。
#   3. 收发缓冲上限 32MB -> 16MB：实测 RTT 约 100ms、链路封顶 ~7Mbps，
#      BDP≈0.1MB，16MB 已是 160 倍余量，写 32MB 只会增加内存压力。
#   4. tcp_ecn 1 -> 2（被动）。实测链路 TCPTimeouts 14345、TCPSynRetrans 10789，
#      主动协商 ECN 在 464XLAT/NAT64 路径上无收益。
#   5. 新增 tcp_retries2=15->8：连接僵死后约 100s 判死重连，而非默认 ~15 分钟。
#   6. 新增 refresh：只在参数发生漂移时重写，service.sh 每 5 分钟调用，
#      补上 v2.2 README 承诺却未实现的"自动重刷"。
#   7. 新增 health：从 /proc/net/netstat 计算真实重传率，量化链路质量，
#      不再凭感觉说"优化了"。
#   8. 数据接口改为按默认路由取（ccmni2），不再盲取第一个 LOWER_UP 的 ccmni。
#   9. reconnect 完成后自动 refresh，抵消切网导致的参数回收。
#  10. 备份归档从 /data/local/tmp 迁到模块目录，避免 tmp 被清后失去回滚能力。
# =====================================================================

KS_MOD=/data/adb/modules/t5m_netboost
NB_VER=$(sed -n 's/^version=//p' "$KS_MOD/module.prop" 2>/dev/null | head -1)
[ -n "$NB_VER" ] || NB_VER=v2.4.1

NB_DIR=/data/local/tmp/netboost
BAK_DIR=$KS_MOD/data
BK=$BAK_DIR/backup.conf
LEGACY_BK=$NB_DIR/backup.conf
LOG=$NB_DIR/action.log
HIST=$NB_DIR/history.csv
WLOG=$NB_DIR/watch.log
WOFF=$NB_DIR/watch.off
EVENTS=$NB_DIR/events.csv
BENCH=$BAK_DIR/bench.csv
TRAFFIC=$BAK_DIR/traffic.state
TRAFFIC_HIST=$BAK_DIR/traffic.hist
TEL=$NB_DIR/.tel.tmp
mkdir -p "$NB_DIR" "$BAK_DIR" 2>/dev/null

# 老版本备份迁移到模块目录（只做一次，保留原文件不动）
if [ -s "$LEGACY_BK" ] && [ ! -s "$BK" ]; then
  cp -a "$LEGACY_BK" "$BK" 2>/dev/null
fi

c_r() { printf '\033[31m%s\033[0m\n' "$*"; }
c_g() { printf '\033[32m%s\033[0m\n' "$*"; }
c_y() { printf '\033[33m%s\033[0m\n' "$*"; }
c_b() { printf '\033[36m%s\033[0m\n' "$*"; }
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
warn() { c_y "  ! $*"; log "WARN $*"; }
ok()   { c_g "  + $*"; log "OK $*"; }
die()  { c_r "x $*"; log "FAIL $*"; exit 1; }

[ "$(id -u 2>/dev/null)" = "0" ] || die "需要 Root"

# ---------------------------------------------------------------------
# 外部工具探测：WebUI 与 service.sh 的 PATH 不同，必须绝对路径兜底
# ---------------------------------------------------------------------
BB=""
for c in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/bin/busybox /system/xbin/busybox; do
  [ -x "$c" ] && { BB="$c"; break; }
done
[ -n "$BB" ] || BB=$(command -v busybox 2>/dev/null)

ipc() { if [ -n "$BB" ]; then "$BB" ip "$@"; else ip "$@"; fi; }
# busybox ping 支持 -4/-6；toybox ping 不支持，传了直接 rc=2
pingx() { _f=$1; _h=$2; _n=${3:-1}; _w=${4:-3}
  if [ -n "$BB" ]; then "$BB" ping "$_f" -c "$_n" -W "$_w" "$_h" >/dev/null 2>&1
  else ping -c "$_n" -W "$_w" "$_h" >/dev/null 2>&1; fi; }
ping4() { pingx -4 "$@"; }
ping6() { pingx -6 "$@"; }
pingsz() { if [ -n "$BB" ]; then "$BB" ping -c 2 -W 2 -s "$1" "$2" >/dev/null 2>&1
           else ping -c 2 -W 2 -s "$1" "$2" >/dev/null 2>&1; fi; }

# 数据接口：优先默认路由的 dev（实测为 ccmni2），退回首个 LOWER_UP 的 ccmni
detect_if() {
  i=$(ipc -o route get 223.5.5.5 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
  [ -n "$i" ] && { echo "$i"; return; }
  ipc -o link show 2>/dev/null \
    | awk -F': ' '/LOWER_UP/ && /ccmni/{gsub(/@.*/,"",$2); print $2; exit}'
}
IFACE=$(detect_if)
[ -z "$IFACE" ] && IFACE=ccmni1

CONTENT=/system/bin/content
SVC=/system/bin/svc
WGET_BIN=""
WGET_PRE=""
find_wget() {
  for c in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/bin/busybox /system/xbin/busybox; do
    if [ -x "$c" ]; then WGET_BIN="$c"; WGET_PRE=wget; return 0; fi
  done
  for c in /system/bin/wget /system/xbin/wget /data/adb/ksu/bin/wget; do
    if [ -x "$c" ]; then WGET_BIN="$c"; WGET_PRE=""; return 0; fi
  done
  return 1
}
wget_run() {
  [ -n "$WGET_BIN" ] || return 127
  if [ -n "$WGET_PRE" ]; then "$WGET_BIN" "$WGET_PRE" "$@"; else "$WGET_BIN" "$@"; fi
}

now_ms() { awk '{printf "%d", $1 * 1000}' /proc/uptime 2>/dev/null; }
norm() { set -- $*; printf '%s' "$*"; }

# ---------------------------------------------------------------------
# 连通性判定：ICMP 双栈 + HTTP 204，任一通道通即视为在线
# 旧版只用 ping -6 / ping -4，在 toybox 下恒失败 -> 每 15 分钟误重连
# ---------------------------------------------------------------------
is_online() {
  ping4 223.5.5.5 1 3 && return 0
  ping6 2400:3200::1 1 3 && return 0
  ping4 119.29.29.29 1 3 && return 0
  if find_wget; then
    wget_run -T 6 -q -O /dev/null "https://connectivitycheck.gstatic.com/generate_204" 2>/dev/null && return 0
  fi
  return 1
}

# ---------------------------------------------------------------------
# 参数表（唯一事实源，apply / refresh 共用）
# ---------------------------------------------------------------------
EXPECTED="net.ipv4.tcp_congestion_control=bbr
net.core.default_qdisc=fq
net.ipv4.tcp_rmem=4096 262144 16777216
net.ipv4.tcp_wmem=4096 262144 16777216
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_notsent_lowat=131072
net.ipv4.tcp_autocorking=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_ecn=2
net.ipv4.tcp_sack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_tw_reuse=2
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_retries2=8
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_max_syn_backlog=4096
net.core.somaxconn=4096
net.ipv4.ip_local_port_range=10000 65535
net.core.netdev_max_backlog=50000"

setk() {
  key=$1; val=$2; do_bk=${3:-1}; quiet=${4:-0}
  p="/proc/sys/$(echo "$key" | tr '.' '/')"
  [ -e "$p" ] || { [ "$quiet" = "0" ] && warn "不存在 $key"; return 1; }
  [ -w "$p" ] || { [ "$quiet" = "0" ] && warn "只读   $key"; return 1; }
  cur=$(cat "$p" 2>/dev/null)
  if [ "$(norm "$cur")" = "$(norm "$val")" ]; then
    [ "$quiet" = "0" ] && ok "$key = $(norm "$cur")（无需变更）"
    return 0
  fi
  if [ "$do_bk" = "1" ]; then
    grep -q "^${key}=" "$BK" 2>/dev/null || echo "${key}=${cur}" >> "$BK"
  fi
  echo "$val" > "$p" 2>/dev/null
  now=$(cat "$p" 2>/dev/null)
  if [ "$(norm "$now")" = "$(norm "$val")" ]; then
    [ "$quiet" = "0" ] && ok "$key = $(norm "$now")"
    return 0
  else
    warn "校验不符 $key 期望[$(norm "$val")] 实际[$(norm "$now")]"
    return 1
  fi
}
getk() { cat "/proc/sys/$(echo "$1" | tr '.' '/')" 2>/dev/null; }

# ---------------------------------------------------------------------
# 信号字段提取（status / sig / json 共用）
# ---------------------------------------------------------------------
dump_tel() { dumpsys telephony.registry 2>/dev/null > "$TEL"; }

fld() {
  m=$(grep -o "$1" "$TEL" 2>/dev/null | head -1)
  [ -z "$m" ] && { echo ""; return; }
  if [ "$2" = "raw" ]; then echo "$m"; else echo "${m#*=}" | sed 's/^ //'; fi
}

rat_name() {
  case "$1" in
    20) echo "NR_SA" ;; 14) echo "NR_NSA" ;; 13) echo "LTE" ;;
    11) echo "WCDMA" ;; 3) echo "UMTS" ;; 1|2|16) echo "GSM" ;;
    0|"") echo "UNKNOWN" ;; *) echo "RAT$1" ;;
  esac
}

sig_read() {
  dump_tel
  [ -s "$TEL" ] || return 1
  R_RSRP=$(fld 'ssRsrp = -\{0,1\}[0-9]\{1,\}')
  R_RSRQ=$(fld 'ssRsrq = -\{0,1\}[0-9]\{1,\}')
  R_SINR=$(fld 'ssSinr = -\{0,1\}[0-9]\{1,\}')
  R_LVL=$(fld 'miuiLevel = [0-9]\{1,\}')
  R_BAND=$(fld 'mBand=[0-9]\{1,\}')
  R_BW=$(fld 'mCellBandwidthDownlinkKhz=[0-9]\{1,\}')
  R_PCI=$(fld 'mPhysicalCellId=[0-9]\{1,\}')
  R_ARFCN=$(fld 'mDownlinkChannelNumber=[0-9]\{1,\}')
  R_RAT=$(rat_name "$(fld 'getRilDataRadioTechnology=[0-9]\{1,\}')")
  R_OPR=$(fld 'mOperatorAlphaLong=[^,}]*')
  # 无效哨兵过滤（正数超过 100 的 RSRP/RSRQ/SINR 不是真值）
  for v in R_RSRP R_RSRQ R_SINR; do
    eval "x=\$$v"
    [ -n "$x" ] && [ "$x" -gt 100 ] 2>/dev/null && eval "$v=''"
  done
  [ -z "$R_BW" ] && R_BW=$(grep -o 'mCellBandwidths=\[[0-9]\{1,\}' "$TEL" 2>/dev/null | head -1 | grep -o '[0-9]\{1,\}$')
  [ -z "$R_BW" ] && R_BW=0
  [ -z "$R_BAND" ] && R_BAND="NA"
  R_BWMHZ=$((R_BW / 1000))
  R_T56=$(cat /sys/class/thermal/thermal_zone56/temp 2>/dev/null)
  R_T57=$(cat /sys/class/thermal/thermal_zone57/temp 2>/dev/null)
  return 0
}

show_sig() {
  sig_read || { warn "telephony.registry 读取失败"; return 1; }
  bstr="n$R_BAND"; [ "$R_BAND" = "NA" ] && bstr="未知(reconnect 后复测)"
  printf '  运营商   %s\n' "${R_OPR:-NA}"
  printf '  制式     %s  Band %s  %sMHz  PCI %s  ARFCN %s\n' "$R_RAT" "$bstr" "$R_BWMHZ" "${R_PCI:-NA}" "${R_ARFCN:-NA}"
  printf '  无线质量 RSRP %s dBm   RSRQ %s dB   SINR %s dB   UI格 %s/5\n' "${R_RSRP:-NA}" "${R_RSRQ:-NA}" "${R_SINR:-NA}" "${R_LVL:-NA}"
  if [ -n "$R_SINR" ] && [ "$R_SINR" -ge 20 ] 2>/dev/null; then q="优"; elif [ -n "$R_SINR" ] && [ "$R_SINR" -ge 13 ] 2>/dev/null; then q="良好"; elif [ -n "$R_SINR" ] && [ "$R_SINR" -ge 0 ] 2>/dev/null; then q="一般"; else q="差"; fi
  if [ -n "$R_RSRP" ] && [ "$R_RSRP" -ge -85 ] 2>/dev/null; then p="优"; elif [ -n "$R_RSRP" ] && [ "$R_RSRP" -ge -95 ] 2>/dev/null; then p="良好"; elif [ -n "$R_RSRP" ] && [ "$R_RSRP" -ge -105 ] 2>/dev/null; then p="一般"; else p="弱"; fi
  c_b "  综合判定 强度$p / 质量$q"
  if [ -n "$R_T57" ]; then
    printf '  基带温度 NR-PA %sC   MDPA %sC\n' \
      "$(awk -v t=$R_T57 'BEGIN{printf "%.1f",t/1000}')" \
      "$(awk -v t=$R_T56 'BEGIN{printf "%.1f",t/1000}')"
    [ "$R_T57" -ge 55000 ] 2>/dev/null && warn "NR-PA ≥55C，基带降功率中"
  fi
  echo "  建议"
  case "$R_BWMHZ" in
    100) echo "    - 已占 100MHz 满带宽载波（n41），带宽侧无优化空间" ;;
    60|70|80|90) echo "    - 载波 ${R_BWMHZ}MHz 非满配，可重选到 100MHz 小区" ;;
    20|25|30|40|50) echo "    - 载波仅 ${R_BWMHZ}MHz（n28 窄带），重选到 n41 100MHz 可显著提速" ;;
    *) echo "    - 载波带宽未取到，先执行 reconnect" ;;
  esac
  [ -n "$R_SINR" ] && [ "$R_SINR" -lt 6 ] 2>/dev/null && echo "    - SINR ${R_SINR}dB 偏低：空口误块率高，单流会被压死，优先换点位"
  [ -n "$R_RSRP" ] && [ "$R_RSRP" -lt -105 ] 2>/dev/null && echo "    - RSRP<-105 弱场，软件优化收益有限"
  return 0
}

# ---------------------------------------------------------------------
# json：给 WebUI 控制台用，单行输出（字段只增不改，保持旧前端兼容）
# ---------------------------------------------------------------------
jn() { if [ -z "$1" ]; then echo null; else echo "$1"; fi; }
jt() { v=$(echo "$1" | tr -d '"\\'); if [ -z "$v" ]; then echo '""'; else printf '"%s"' "$v"; fi; }
jc() { [ -n "$1" ] && awk -v t="$1" 'BEGIN{printf "%.1f", t/1000}' || echo null; }

# ---------------------------------------------------------------------
# 流量计量：按数据接口独立计数，持久化到模块 data 目录。
# state 行: date today_rx today_tx last_raw_rx last_raw_tx last_ts rx_rate tx_rate
# hist  行: date rx tx（每天一行，供月度汇总）
# 关键点：reconnect 会把接口计数器清零，新读数 < 旧读数即判定重置，
#         增量按新读数从零累加，不能让当日累计出现负数。
# ---------------------------------------------------------------------
traffic_sample() {
  _if=$(detect_if)
  [ -n "$_if" ] || return 1
  set -- $(awk -v i="$_if:" '$1==i{print $2" "$10}' /proc/net/dev 2>/dev/null)
  [ -n "$1" ] && [ -n "$2" ] || return 1
  nrx=$1; ntx=$2
  today=$(date +%F)
  drx=$nrx; dtx=$ntx; lrx=$nrx; ltx=$ntx
  rrx=0; rtx=0
  nowts=$(date +%s)
  if [ -s "$TRAFFIC" ]; then
    read _d _drx _dtx _lrx _ltx _lts _rrx _rtx < "$TRAFFIC"
    [ "$_d" = "$today" ] || {
      [ -n "$_d" ] && echo "$_d ${_drx:-0} ${_dtx:-0}" >> "$TRAFFIC_HIST"
      tail -200 "$TRAFFIC_HIST" > "$TRAFFIC_HIST.t" 2>/dev/null && mv "$TRAFFIC_HIST.t" "$TRAFFIC_HIST"
      _drx=0; _dtx=0
    }
    case "$nrx" in ''|*[!0-9]*) return 1 ;; esac
    case "$ntx" in ''|*[!0-9]*) return 1 ;; esac
    case "$_lrx" in ''|*[!0-9]*) _lrx=$nrx ;; esac
    case "$_ltx" in ''|*[!0-9]*) _ltx=$ntx ;; esac
    if [ "$nrx" -ge "$_lrx" ]; then drx=$((nrx - _lrx)); else drx=$nrx; fi
    if [ "$ntx" -ge "$_ltx" ]; then dtx=$((ntx - _ltx)); else dtx=$ntx; fi
    _dt=$((nowts - _lts)); [ "$_dt" -lt 1 ] && _dt=1
    [ "$_dt" -gt 3600 ] && _dt=0            # 采样间隔过大，速率无参考意义
    if [ "$_dt" -gt 0 ] && [ "$nrx" -ge "$_lrx" ]; then rrx=$(( (nrx - _lrx) / _dt )); fi
    if [ "$_dt" -gt 0 ] && [ "$ntx" -ge "$_ltx" ]; then rtx=$(( (ntx - _ltx) / _dt )); fi
    drx=$((drx + ${_drx:-0})); dtx=$((dtx + ${_dtx:-0}))
  fi
  echo "$today $drx $dtx $nrx $ntx $nowts $rrx $rtx" > "$TRAFFIC"
  chmod 664 "$TRAFFIC" 2>/dev/null
  return 0
}

do_traffic() {
  if ! traffic_sample; then
    echo '{"ok":0}'
    return 1
  fi
  read _d _drx _dtx _nrx _ntx _nts _rrx _rtx < "$TRAFFIC"
  ym=$(date +%Y-%m)
  set -- $(awk -v ym="$ym-" '$1 ~ ym{r+=$2; t+=$3} END{print r+0" "t+0}' "$TRAFFIC_HIST" 2>/dev/null)
  mrx=$(( ${1:-0} + _drx )); mtx=$(( ${2:-0} + _dtx ))
  awk -v d1=$_drx -v d2=$_dtx -v m1=$mrx -v m2=$mtx -v r1=$_rrx -v r2=$_rtx 'BEGIN{
    printf "{\"ok\":1,\"todayRx\":%d,\"todayTx\":%d,\"monRx\":%d,\"monTx\":%d,\"rxK\":%d,\"txK\":%d}", d1,d2,m1,m2,r1,r2 }'
  echo
}

# ---------------------------------------------------------------------
# 事件记账：掉线 / 重连 / 温度推迟 / 链路切换 / 手动操作
# 描述字段由模块生成，只使用安全字符，不含逗号
# ---------------------------------------------------------------------
add_event() {
  echo "$(date +%s),$1,$2" >> "$EVENTS"
  if [ "$(wc -l < "$EVENTS" 2>/dev/null)" -gt 500 ]; then
    tail -300 "$EVENTS" > "$EVENTS.t" 2>/dev/null && mv "$EVENTS.t" "$EVENTS"
  fi
}

do_events() {
  n=${1:-20}
  case "$n" in *[!0-9]*) n=20 ;; esac
  [ "$n" -gt 100 ] && n=100
  if [ ! -s "$EVENTS" ]; then echo '[]'; return 0; fi
  tail -n "$n" "$EVENTS" | awk -F, '
    { printf "%s{\"t\":%s,\"ty\":\"%s\",\"d\":\"%s\"}", (NR>1?",":""), $1, $2, $3 }
    END { print "" }' | sed 's/^/[/; s/$/]/'
  echo
}

do_benchhist() {
  n=${1:-10}
  case "$n" in *[!0-9]*) n=10 ;; esac
  [ "$n" -gt 60 ] && n=60
  if [ ! -s "$BENCH" ]; then echo '[]'; return 0; fi
  tail -n "$n" "$BENCH" | awk -F, '
    { printf "%s{\"t\":%s,\"mb\":%s,\"mbps\":%s}", (NR>1?",":""), $1, $2, $3 }
    END { print "" }' | sed 's/^/[/; s/$/]/'
  echo
}

do_json() {
  if ! sig_read; then
    echo '{"ok":0,"err":"telephony_unavailable","ver":"'"$NB_VER"'"}'
    return 1
  fi
  cc=$(getk net.ipv4.tcp_congestion_control)
  qd=$(getk net.core.default_qdisc)
  en=1; [ -f "$KS_MOD/disable" ] && en=0
  bk=0; [ -s "$BK" ] && bk=1
  wt=1; [ -f "$WOFF" ] && wt=0
  drift=$(drift_count)
  # traffic fields: read state only (maintained by service.sh traffic sample)
  if [ -s "$TRAFFIC" ]; then
    read _td _tdr _tdt _tnr _tnt _tts _trr _trt < "$TRAFFIC"
    _ym=$(date +%Y-%m)
    set -- $(awk -v ym="$_ym-" '$1 ~ ym{r+=$2; t+=$3} END{print r+0" "t+0}' "$TRAFFIC_HIST" 2>/dev/null)
    _tmr=$(( ${1:-0} + _tdr )); _tmt=$(( ${2:-0} + _tdt ))
  else
    _tdr=0; _tdt=0; _tmr=0; _tmt=0; _trr=0; _trt=0
  fi
  printf '{"ok":1,"ver":"%s","iface":"%s","mtu":%s,"rat":"%s","opr":%s,"band":%s,"bw_mhz":%s,"pci":%s,"arfcn":%s,"rsrp":%s,"rsrq":%s,"sinr":%s,"lvl":%s,"t_nrpa":%s,"t_mdpa":%s,"cc":"%s","qdisc":"%s","rmem_max":%s,"wmem_max":%s,"ecn":%s,"lowat":%s,"tfo":%s,"mod":%s,"backup":%s,"watch":%s,"drift":%s,"todayRx":%d,"todayTx":%d,"monRx":%d,"monTx":%d,"rxK":%d,"txK":%d}\n' \
    "$NB_VER" "$IFACE" "$(jn "$(cat /sys/class/net/$IFACE/mtu 2>/dev/null)")" \
    "$R_RAT" "$(jt "$R_OPR")" \
    "$(if [ "$R_BAND" = "NA" ]; then echo null; else echo "$R_BAND"; fi)" \
    "$(jn "$R_BWMHZ")" "$(jn "$R_PCI")" "$(jn "$R_ARFCN")" \
    "$(jn "$R_RSRP")" "$(jn "$R_RSRQ")" "$(jn "$R_SINR")" "$(jn "$R_LVL")" \
    "$(jc "$R_T57")" "$(jc "$R_T56")" \
    "$cc" "$qd" "$(jn "$(getk net.core.rmem_max)")" "$(jn "$(getk net.core.wmem_max)")" \
    "$(jn "$(getk net.ipv4.tcp_ecn)")" "$(jn "$(getk net.ipv4.tcp_notsent_lowat)")" \
    "$(jn "$(getk net.ipv4.tcp_fastopen)")" "$en" "$bk" "$wt" "$(jn "$drift")" \
    "$_tdr" "$_tdt" "$_tmr" "$_tmt" "$_trr" "$_trt"
}

# ---------------------------------------------------------------------
# 参数漂移检测 / 重刷
# ---------------------------------------------------------------------
drift_count() {
  printf '%s\n' "$EXPECTED" | awk -F= '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/,"",s); gsub(/[ \t]+/," ",s); return s }
    NF {
      k=$1; v=$0; sub(/^[^=]*=/,"",v); gsub(/\./,"/",k);
      p="/proc/sys/" k;
      if ((getline cur < p) > 0) { if (trim(cur) != trim(v)) n++ } else n++
      close(p)
    }
    END { print n+0 }'
}

do_refresh() {
  quiet=${1:-}
  n=0; bad=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    k=${line%%=*}; v=${line#*=}
    p="/proc/sys/$(echo "$k" | tr '.' '/')"
    [ -w "$p" ] || continue
    cur=$(cat "$p" 2>/dev/null)
    [ "$(norm "$cur")" = "$(norm "$v")" ] && continue
    echo "$v" > "$p" 2>/dev/null
    after=$(cat "$p" 2>/dev/null)
    [ "$(norm "$after")" = "$(norm "$v")" ] && { n=$((n + 1)); bad="$bad $k"; }
  done <<EOF
$EXPECTED
EOF
  if [ "$n" -gt 0 ]; then
    log "refresh 修正 $n 项:$bad"
    [ "$quiet" = "quiet" ] || c_g "  已重刷 $n 项:$bad"
  else
    [ "$quiet" = "quiet" ] || c_y "  无漂移，全部参数在位"
  fi
  return 0
}

do_apply() {
  c_b "== apply  $(date '+%F %T')  iface=$IFACE =="
  [ -s "$BK" ] || { : > "$BK"; ok "创建备份 $BK"; }
  bad=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    k=${line%%=*}; v=${line#*=}
    setk "$k" "$v" 1 0 || bad=$((bad + 1))
  done <<EOF
$EXPECTED
EOF
  echo
  if [ "$bad" -gt 0 ]; then
    c_y "  有 $bad 项未能写入或校验不符（内核不支持或只读），其余已生效"
  fi
  c_y "  参数对新建连接生效，已有连接需 reconnect"
  c_y "  缓冲上限改为 16MB：实测 BDP≈0.1MB，16MB 已是 160 倍余量"
  log "apply done iface=$IFACE bad=$bad"
}

do_restore() {
  [ -s "$BK" ] || [ -s "$LEGACY_BK" ] || die "无备份（未执行过 apply）"
  [ -s "$BK" ] || BK="$LEGACY_BK"
  c_b "== restore =="
  while IFS='=' read -r k v; do
    [ -z "$k" ] && continue
    p="/proc/sys/$(echo "$k" | tr '.' '/')"
    [ -w "$p" ] || { warn "跳过 $k（只读）"; continue; }
    echo "$v" > "$p" 2>/dev/null
    printf '  - %-38s -> %s\n' "$k" "$(norm "$(cat "$p" 2>/dev/null)")"
  done < "$BK"
  mv "$BK" "$BK.restored.$(date '+%Y%m%d%H%M%S')" 2>/dev/null
  ok "已回滚，备份归档"
  log "restore done"
}

do_status() {
  c_b "== 设备 =="
  printf '  型号 %s (%s)  %s  Android %s  HyperOS %s\n' \
    "$(getprop ro.product.marketname)" "$(getprop ro.product.device)" \
    "$(getprop ro.board.platform)" "$(getprop ro.build.version.release)" "$(getprop ro.miui.ui.version.name)"
  printf '  内核 %s\n' "$(uname -r)"
  printf '  基带 %s\n' "$(getprop gsm.version.baseband)"

  c_b "== 链路 =="
  printf '  数据接口 %s  MTU %s  qdisc %s\n' "$IFACE" \
    "$(cat /sys/class/net/$IFACE/mtu 2>/dev/null)" \
    "$(ipc -o link show "$IFACE" 2>/dev/null | sed -n 's/.*qdisc \([a-z_]*\).*/\1/p')"
  ipc -o addr show "$IFACE" 2>/dev/null | awk '{print "  "$4" "$6}'
  [ -z "$(ipc -o addr show "$IFACE" 2>/dev/null | grep 'inet ')" ] && \
    c_y "  仅 IPv6 地址（广电 IPv6-only + NAT64/464XLAT）"

  c_b "== 信号 =="
  show_sig

  c_b "== 关键 sysctl =="
  printf '%s\n' net.ipv4.tcp_congestion_control net.core.default_qdisc \
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.core.rmem_max net.core.wmem_max \
    net.ipv4.tcp_notsent_lowat net.ipv4.tcp_no_metrics_save \
    net.ipv4.tcp_mtu_probing net.ipv4.tcp_ecn net.ipv4.tcp_autocorking \
    net.ipv4.tcp_retries2 net.ipv4.tcp_tw_reuse net.ipv4.ip_local_port_range \
  | awk '{
      k=$0; p="/proc/sys/" k; gsub(/\./,"/",p);
      if ((getline v < p) > 0) { gsub(/^[ \t]+|[ \t]+$/,"",v); gsub(/[ \t]+/," ",v) } else v="-"
      printf "  %-40s %s\n", k, v
      close(p)
    }'
  d=$(drift_count)
  if [ "$d" = "0" ]; then c_g "  参数漂移 0 项（全部在位）"; else c_y "  参数漂移 $d 项，执行 refresh 修复"; fi
  if [ -s "$BK" ]; then c_y "  备份存在：$BK（$(wc -l < "$BK") 项）"; else c_y "  未备份（尚未 apply）"; fi
}

do_reconnect() {
  c_b "== reconnect =="
  c_y "  断开数据 -> 3s -> 重连"
  $SVC data disable 2>/dev/null || cmd phone data disable 2>/dev/null
  sleep 3
  $SVC data enable 2>/dev/null || cmd phone data enable 2>/dev/null
  _rc=0
  while [ $_rc -lt 20 ]; do
    sleep 1; _rc=$((_rc + 1))
    st=$(dumpsys telephony.registry 2>/dev/null | grep -m1 -o 'mDataConnectionState=[0-9-]*')
    [ "$st" = "mDataConnectionState=2" ] && break
  done
  case "$st" in
    *=2) ok "数据已重连（耗时 ${_rc}s）" ;;
    *)   warn "20s 未回到 CONNECTED，当前 $st" ;;
  esac
  # 切网会导致内核回收部分参数，回来立刻补写
  do_refresh quiet
  show_sig
}

do_bench() {
  find_wget || die "未找到 wget（busybox 与 wget 均不可用），无法测速"
  SZ=${1:-5242880}
  case "$SZ" in *[!0-9]*) SZ=5242880 ;; esac
  c_b "== bench $((SZ / 1048576))MB 单流 =="
  t0=$(now_ms)
  wget_run -T 30 -q -O /dev/null "https://speed.cloudflare.com/__down?bytes=$SZ" 2>"$NB_DIR/.wget.err"
  rc=$?
  t1=$(now_ms)
  if [ $rc -ne 0 ]; then
    warn "https 失败(rc=$rc)，降级 http"
    t0=$(now_ms)
    wget_run -T 30 -q -O /dev/null "http://speed.cloudflare.com/__down?bytes=$SZ" || {
      warn "测速失败：$(tail -1 "$NB_DIR/.wget.err" 2>/dev/null)"; return 1; }
    t1=$(now_ms)
  fi
  ms=$((t1 - t0)); [ $ms -le 0 ] && ms=1
  mbps=$(awk -v b=$SZ -v m=$ms 'BEGIN{printf "%.1f", b*8/m/1000}')
  mbs=$(awk -v b=$SZ -v m=$ms 'BEGIN{printf "%.2f", b/1048576/(m/1000)}')
  echo "$(date +%s),$((SZ / 1048576)),$mbps" >> "$BENCH"
  if [ "$(wc -l < "$BENCH" 2>/dev/null)" -gt 120 ]; then
    tail -60 "$BENCH" > "$BENCH.t" 2>/dev/null && mv "$BENCH.t" "$BENCH"
  fi
  add_event bench "single_${SZ}_bytes=${mbps}Mbps"
  printf '  耗时 %s ms   平均 %s Mbps (%s MB/s)\n' "$ms" "$mbps" "$mbs"
  c_y "  单流结果；多流对比用 diag，多线程下载用 aria2c -x8 -s8"
  c_y "  目标为境外节点（cloudflare），跨境链路会偏低；看相对变化，不看绝对值"
}

do_diag() {
  find_wget || die "未找到 wget（busybox 与 wget 均不可用），无法测速"
  c_b "== diag =="
  show_sig
  echo
  do_probe
  echo
  c_b "== 路径 MTU =="
  for s in 1472 1400 1200; do
    if pingsz "$s" 223.5.5.5; then
      ok "payload $s 通（$((s + 28)) 字节 IP 包）"
    else
      warn "payload $s 不通，疑似 PMTU 黑洞"
    fi
  done
  echo
  c_b "== 抖动（20 包） =="
  if [ -n "$BB" ]; then "$BB" ping -c 20 -i 0.2 -W 2 223.5.5.5 2>&1 | tail -2 | sed 's/^/  /'
  else ping -c 20 -i 0.2 -W 2 223.5.5.5 2>&1 | tail -2 | sed 's/^/  /'; fi
  echo
  c_b "== 单流 4MB =="
  _t0=$(now_ms)
  wget_run -T 40 -q -O /dev/null "https://speed.cloudflare.com/__down?bytes=4194304" 2>/dev/null
  _t1=$(now_ms)
  _ms=$((_t1 - _t0)); [ $_ms -le 0 ] && _ms=1
  S=$(awk -v m=$_ms 'BEGIN{printf "%.1f", 4194304*8/m/1000}')
  printf '  %d ms   %s Mbps\n' "$_ms" "$S"
  echo
  c_b "== 4 流并行 4x1MB =="
  _t0=$(now_ms)
  for i in 1 2 3 4; do
    wget_run -T 40 -q -O /dev/null "https://speed.cloudflare.com/__down?bytes=1048576" 2>/dev/null &
  done
  wait
  _t1=$(now_ms)
  _ms=$((_t1 - _t0)); [ $_ms -le 0 ] && _ms=1
  A=$(awk -v m=$_ms 'BEGIN{printf "%.1f", 4194304*8/m/1000}')
  printf '  %d ms   聚合 %s Mbps\n' "$_ms" "$A"
  echo
  c_b "== 判定 =="
  awk -v s="$S" -v a="$A" 'BEGIN{
    if (a < s*1.3) print "  - 多流≈单流：总带宽被网络侧限制（达量限速/拥塞/QOS），本机无法突破";
    else print "  - 多流>>单流：单流受丢包与窗口限制，用多线程下载器可吃满";
  }'
  echo "  - SINR 低 + 抖动大：优先改善无线环境，参数收益次要"
}

# ---------------------------------------------------------------------
# health：从 /proc/net/netstat 算真实重传率（量化，不靠感觉）
# ---------------------------------------------------------------------
getstat() {
  awk -v want="$1" '
    { line=$0; gsub(/:/," ",line); n=split(line,f," ")
      if (f[1]=="TcpExt" || f[1]=="Ip" || f[1]=="IpExt") {
        if (f[2] ~ /^[0-9]+$/) {                     # 数值行
          for(i=1;i<=c;i++) if(h[i]==want){ print f[i]; exit }
        } else {                                     # 表头行
          for(i=1;i<=n;i++) h[i]=f[i]; c=n
        }
        next
      } }
  ' /proc/net/netstat 2>/dev/null
}

do_health() {
  c_b "== TCP 链路质量（自开机累计） =="
  sent=$(getstat TCPOrigDataSent)
  lost=$(getstat TCPLostRetransmit)
  tout=$(getstat TCPTimeouts)
  synr=$(getstat TCPSynRetrans)
  probe=$(getstat TCPLossProbes)
  [ -z "$sent" ] && { warn "/proc/net/netstat 读取失败"; return 1; }
  awk -v s="$sent" -v l="$lost" -v t="$tout" -v y="$synr" -v p="$probe" 'BEGIN{
    r = (s>0)? l*100/s : 0
    printf "  已发送段 %d   丢失重传 %d   重传率 %.2f%%\n", s, l, r
    printf "  超时(Timeouts) %d   SYN 重传 %d   丢失探测 %d\n", t, y, p
    if (r < 0.3) q="优（<0.3%）";
    else if (r < 1.5) q="一般（0.3~1.5%）";
    else q="差（>1.5%）";
    printf "  判定 重传率%s\n", q
    if (r >= 1.5) print "  - 建议：换点位或等 SINR 回升；此时任何 sysctl 都补不回来"
    else if (r >= 0.3) print "  - 轻微丢包：单流会被压，走多线程可缓解"
    else print "  - 链路干净：瓶颈在运营商侧或空口带宽，不是终端参数"
  }'
  echo
  c_b "== 当前参数漂移 =="
  d=$(drift_count)
  if [ "$d" = "0" ]; then c_g "  0 项漂移，参数在位"; else c_y "  $d 项漂移（切网后常见），执行 refresh 修复"; fi
  echo
  c_b "== 实测基准（本机历史） =="
  c_y "  n41 100MHz 单流约 6.8Mbps、4 流约 6.9Mbps -> 网络侧封顶，与终端参数无关"
  c_y "  DNS 解析 500~1100ms（223.5.5.5 / 119.29.29.29 / 运营商 DNS 均如此）-> 路径 RTT 与 NAT64 转换开销，换 DNS 无解"
  c_y "  PMTU 1500 全通，无黑洞 -> 不需要改 MTU"
}

do_apn() {
  c_b "== APN =="
  raw=$($CONTENT query --uri content://telephony/carriers/preferapn 2>/dev/null)
  id=""
  if [ -n "$raw" ]; then
    echo "$raw" | tr ',' '\n' | grep -E '^ *(name|apn|type|protocol|roaming_protocol|proxy|port|user|bearer|current)=' | sed 's/^ */  /'
    id=$(echo "$raw" | tr ',' '\n' | sed -n 's/^ *_id=\([0-9]*\).*/\1/p')
    case "$raw" in
      *"apn=cbnet"*) ok "APN=cbnet（广电标准）" ;;
      *) warn "APN 非 cbnet" ;;
    esac
    if echo "$raw" | grep -q 'proxy=[^,]'; then warn "APN 配置了代理，会串行化流量"; else ok "无 APN 代理"; fi
  else
    warn "content 查询不可用（环境受限），改用 dumpsys 解析"
    seg=$(dumpsys telephony.registry 2>/dev/null | grep -m1 -o 'APN Setting: \[ApnSetting\][^}]*' | sed 's/ state:.*//')
    if [ -z "$seg" ]; then
      warn "dumpsys 中也无 APN 记录"
      return 1
    fi
    echo "$seg" | awk -F', ' '{
      sub(/^APN Setting: /,"",$1);
      gsub(/\[ApnSetting\] /,"",$1);
      printf "  APN 名  %s\n  行 ID   %s\n  运营商  %s\n  APN     %s\n  类型    %s\n  协议    %s / %s\n", $1,$2,$3,$4,$11,$12,$13;
      if ($4=="cbnet") print "  + APN=cbnet（广电标准）"; else print "  ! APN 非 cbnet";
    }'
  fi
  if [ "$1" = "--fix" ]; then
    if [ -z "$id" ]; then
      warn "写操作需 content 可用，当前环境取不到行 id，未写入"
      return 1
    fi
    echo "$raw" > "$NB_DIR/apn.backup.$id"
    $CONTENT update --uri "content://telephony/carriers/$id" \
      --bind protocol:s:IPV4V6 --bind roaming_protocol:s:IPV4V6 \
      --bind apn:s:cbnet --bind type:s:default,supl 2>/dev/null
    after=$($CONTENT query --uri content://telephony/carriers/preferapn 2>/dev/null)
    case "$after" in
      *"apn=cbnet"*) ok "已写入并读回确认（原值存 $NB_DIR/apn.backup.$id）" ;;
      *) warn "写入后读回不符，可能被运营商配置覆盖" ;;
    esac
    c_y "改动需 reconnect 或飞行模式生效"
  fi
}

do_band() {
  target=$1
  sig_read
  cur=$R_BAND
  c_b "== 频段 =="
  if [ "$cur" = "NA" ]; then
    printf '  当前 频段未知  带宽 %sMHz  RSRP %s dBm  SINR %s dB\n' "$R_BWMHZ" "${R_RSRP:-NA}" "${R_SINR:-NA}"
  else
    printf '  当前 n%s  %sMHz  RSRP %s dBm  SINR %s dB  PCI %s\n' "$cur" "$R_BWMHZ" "${R_RSRP:-NA}" "${R_SINR:-NA}" "${R_PCI:-NA}"
  fi
  if [ -z "$target" ]; then
    echo "  n28 = 700MHz 广覆盖/强穿透，带宽仅 30MHz"
    echo "  n41 = 2.6GHz 大带宽 100MHz，覆盖与穿透弱"
    echo "  锁定频段需 MTK 工程模式或 NV 写入，本机无公开接口；本命令只能触发重选"
    return 0
  fi
  t=${target#n}
  case "$t" in
    28|41|78|79) ;;
    *) warn "只支持 n28 / n41 / n78 / n79"; return 1 ;;
  esac
  if [ "$cur" = "$t" ]; then ok "已经在 n$t，无需重选"; return 0; fi
  _bn=0
  while [ $_bn -lt 3 ]; do
    _bn=$((_bn + 1))
    c_y "  第 $_bn/3 次重选…"
    do_reconnect >/dev/null 2>&1
    sleep 3
    sig_read
    if [ "$R_BAND" = "$t" ]; then
      ok "已驻留 n$t  ${R_BWMHZ}MHz  RSRP ${R_RSRP} dBm  SINR ${R_SINR} dB"
      return 0
    fi
  done
  warn "3 次后仍驻留 n$R_BAND；该区域 n$t 覆盖不足或网络不释放"
  return 1
}

# ---------------------------------------------------------------------
# 采样 / 历史 / 掉线守护
# ---------------------------------------------------------------------
nz() {
  case "$1" in
    ""|-|--|NA|na|*[!0-9-]*) echo 0 ;;
    *) echo "$1" ;;
  esac
}

do_sample() {
  sig_read
  case "$R_BAND" in ""|NA|na|*[!0-9]*) return 1 ;; esac
  echo "$(date +%s),$R_BAND,$(nz "$R_BWMHZ"),$(nz "$R_RSRP"),$(nz "$R_RSRQ"),$(nz "$R_SINR"),$(nz "$R_PCI"),$(nz "$R_T57")" >> "$HIST"
  if [ "$(wc -l < "$HIST" 2>/dev/null)" -gt 2880 ]; then
    tail -1440 "$HIST" > "$HIST.t" && mv "$HIST.t" "$HIST"
  fi
  return 0
}

do_history() {
  n=${1:-120}
  case "$n" in *[!0-9]*) n=120 ;; esac
  [ "$n" -gt 2880 ] && n=2880
  if [ ! -s "$HIST" ]; then echo '[]'; return 0; fi
  tail -n "$n" "$HIST" | awk -F, '
    function num(x){ return (x ~ /^-?[0-9]+$/ ? x : 0) }
    {
      printf "%s{\"t\":%s,\"band\":%s,\"bw\":%s,\"rsrp\":%s,\"rsrq\":%s,\"sinr\":%s,\"pci\":%s,\"temp\":%s}",
        (NR>1?",":""), num($1), num($2), num($3), num($4), num($5), num($6), num($7), num($8)
    }
    END { print "" }' | sed 's/^/[/; s/$/]/'
}

do_watch() {
  a=$1
  case "$a" in
    on)
      rm -f "$WOFF"
      ok "掉线守护已开启（60s 三通道体检，连续 3 次失败才重连，冷却 15 分钟）"
      ;;
    off)
      touch "$WOFF"
      ok "掉线守护已关闭"
      ;;
    status|"")
      if [ -f "$WOFF" ]; then c_y "  守护状态：已关闭"; else c_g "  守护状态：运行中"; fi
      if is_online; then c_g "  当前判活：在线"; else c_r "  当前判活：离线"; fi
      if [ -s "$WLOG" ]; then c_b "  最近事件："; tail -6 "$WLOG" | sed 's/^/    /'; else echo "  尚无事件记录"; fi
      if [ -s "$EVENTS" ]; then c_b "  事件账本（events.csv 最近 3 条）："; tail -3 "$EVENTS" | sed 's/^/    /'; fi
      ;;
    *) c_r "用法：watch on|off|status"; return 1 ;;
  esac
  return 0
}

probe_link() {
  _mode=${1:-full}
  v6=0; v4=0; http=-1
  ping6 2400:3200::1 1 3 && v6=1
  ping4 223.5.5.5 1 3 && v4=1
  if [ "$_mode" != "fast" ]; then
    http=0
    if find_wget; then
      wget_run -T 6 -q -O /dev/null "https://connectivitycheck.gstatic.com/generate_204" 2>/dev/null && http=1
    fi
  fi
  echo "$v6 $v4 $http"
}

do_probe() {
  _pm=${1:-full}
  c_b "== IPv6 / NAT64 链路体检 =="
  set -- $(probe_link "$_pm")
  v6=$1; v4=$2; http=$3
  [ "$v6" = "1" ] && ok "IPv6 直连可达（2400:3200::1）" || warn "IPv6 不可达"
  [ "$v4" = "1" ] && ok "IPv4 可达（CLAT/NAT64 正常）" || warn "IPv4 不可达（CLAT/NAT64 异常）"
  if [ "$http" = "-1" ]; then
    c_y "  - HTTP 204 应用层探测：快速模式已跳过"
  else
    [ "$http" = "1" ] && ok "HTTP 204 探测通过（应用层可出网）" || warn "HTTP 204 探测失败"
  fi
  if [ "$_pm" = "fast" ]; then
    c_y "  - DNS64 前缀检测：快速模式已跳过"
  else
  n64=$(nslookup ipv4only.arpa 2>/dev/null | awk '/^Address/ {v=$NF; gsub(/#.*$/,"",v); if (v ~ /^[0-9a-fA-F:]+$/ && v ~ /:/) {print v; exit}}')
  if [ -n "$n64" ]; then
    ok "DNS64 前缀：$(echo "$n64" | cut -c1-24)…"
  else
    c_y "  - 未检出 DNS64 合成记录（CLAT 模式或解析器不支持）"
  fi
  fi
  if [ "$v6" = "0" ] && [ "$v4" = "0" ] && [ "$http" = "0" ]; then
    c_r "  - 判定：三通道全失败，确实掉线，可 reconnect"
  elif [ "$v6" = "0" ] && [ "$v4" = "1" ]; then
    c_y "  - 判定：IPv4 可用、IPv6 直连不可达；应用不受影响，无需重连"
  elif [ "$v6" = "1" ] && [ "$v4" = "0" ]; then
    c_y "  - 判定：NAT64/CLAT 异常，部分应用打不开，可尝试 reconnect"
  fi
}

do_report() {
  _pm=full; _save=1
  for _a in "$@"; do
    case "$_a" in
      fast) _pm=fast ;;
      nosave) _save=0 ;;
    esac
  done

  _rep() {
    c_b "================ T5M 网络诊断报告 ================"
    printf '  生成时间 %s\n  引擎版本 %s\n\n' "$(date '+%F %T')" "$NB_VER"
    do_status
    echo
    c_b "== TCP 链路质量（自开机累计）=="
    do_health
    echo
    do_probe "$_pm"
    echo
    c_b "== 流量 =="
    do_traffic | awk -F"[,:}]" '{
      for(i=1;i<=NF;i++){
        if($i ~ /todayRx/) tr=$(i+1); if($i ~ /todayTx/) tt=$(i+1);
        if($i ~ /monRx/) mr=$(i+1); if($i ~ /monTx/) mt=$(i+1);
      }
      printf "  今日      接收 %.2f GB   发送 %.2f GB\n", tr/1073741824, tt/1073741824
      printf "  本月      接收 %.2f GB   发送 %.2f GB\n", mr/1073741824, mt/1073741824
    }'
    echo
    c_b "== 最近事件（最多 5 条）=="
    if [ -s "$EVENTS" ]; then tail -5 "$EVENTS" | while IFS=, read -r ts ty td; do
      printf '  %s [%s] %s\n' "$(date -d @${ts:-0} '+%m-%d %H:%M' 2>/dev/null || date '+%m-%d %H:%M')" "$ty" "$td"
    done; else echo "  无"; fi
    echo
    c_b "== 最近测速（最多 5 次）=="
    if [ -s "$BENCH" ]; then tail -5 "$BENCH" | while IFS=, read -r ts mb mbps; do
      printf '  %s  %sMB  %s Mbps\n' "$(date -d @${ts:-0} '+%m-%d %H:%M' 2>/dev/null || date '+%m-%d %H:%M')" "$mb" "$mbps"
    done; else echo "  无"; fi
    echo
    c_b "运营商侧 QoS / 达量限速无法本地解除；如多时段测速均封顶，"
    c_b "且换设备同卡复现，可凭本报告向运营商申诉。"
  }

  if [ "$_save" = "1" ]; then
    _stamp=$(date +%Y%m%d_%H%M%S)
    _f="/sdcard/Download/T5M_report_${_stamp}.txt"
    if _rep > "$_f" 2>&1; then
      awk '{ gsub(/\033\[[0-9;]*m/,""); print }' "$_f" > "$_f.t" 2>/dev/null && mv -f "$_f.t" "$_f"
      cp -f "$_f" "$NB_DIR/report_last.txt" 2>/dev/null
      cat "$_f"
      echo
      c_g "== 报告已保存 =="
      echo "  $_f"
      c_y "  同内容副本：$NB_DIR/report_last.txt"
      return 0
    fi
    warn "写入 $_f 失败，改为直接输出"
  fi
  _rep
}

do_help() {
cat <<'EOS'
netboost.sh v2.4.1 —— T5M终极网络优化 · 引擎

  status      设备/链路/信号/温度/参数漂移 全量快照
  json        单行 JSON（WebUI 控制台使用）
  sig         只读信号与建议
  apply       应用网络栈调优（自动备份）
  refresh     只修漂移项（切网后自动调用）
  restore     按备份回滚（归档带时间戳）
  reconnect   断开重连，触发小区重选；完成后自动 refresh
  bench [字节] 单流测速，默认 5MB
  diag        空口 + MTU + 单流/多流对照
  health      从 /proc/net/netstat 算真实重传率，量化链路质量
  apn [--fix] 校验/修正 APN
  band [n28|n41] 查看频段；带参数则最多 3 次重选尝试驻留
  watch on|off|status 掉线守护开关与状态
  sample      采样一条到 history.csv（含基带温度）
  history [n] 最近 n 条采样（JSON，含 temp）
  probe       IPv6/NAT64/HTTP 三通道体检
  events [n]  最近 n 条事件账本（JSON）
  traffic     采样并输出流量统计（今日/本月/速率，JSON）
  benchhist [n] 最近 n 次测速历史（JSON）
  report      一键生成诊断报告（状态+质量+体检+事件+流量+测速）
  online      判活（0=在线，1=离线），供 service.sh 使用
EOS
}

case "$1" in
  status)    do_status ;;
  json)      do_json ;;
  sig)       show_sig ;;
  apply)     do_apply ;;
  refresh)   do_refresh ;;
  restore)   do_restore ;;
  reconnect) do_reconnect ;;
  bench)     shift; do_bench "$1" ;;
  diag)      do_diag ;;
  health)    do_health ;;
  apn)       shift; do_apn "$@" ;;
  band)      shift; do_band "$1" ;;
  watch)     shift; do_watch "$1" ;;
  sample)    do_sample ;;
  history)   shift; do_history "$1" ;;
  probe)     shift; do_probe "$1" ;;
  events)    shift; do_events "$1" ;;
  traffic)   do_traffic ;;
  benchhist) shift; do_benchhist "$1" ;;
  report)    shift; do_report "$@" ;;
  online)    is_online; exit $? ;;
  ""|help|-h|--help) do_help ;;
  *) c_r "未知子命令：$1"; do_help; exit 1 ;;
esac
