#!/system/bin/sh
# T5M终极网络优化 —— late_start service  v2.3
# 职责：开机应用参数 / 60s 采样 / 5 分钟漂移重刷 / 切网自动补写 / 真掉线守护
#
# v2.3 关键修复：
#   - 判活改用引擎的 online 子命令（busybox ping 双栈 + HTTP 204 三通道），
#     不再直接用 ping -6 / ping -4：toybox ping 不认 -4/-6，旧版会每 15 分钟
#     误判一次并强制断网重连（v2.2 watch.log 有 22 条 900s 等距记录）。
#   - 新增每 5 分钟 refresh：HyperOS 切网会回收 tcp_rmem/wmem，v2.2 只 apply
#     一次，回落后再不恢复，README 承诺的"重刷"实际没实现。
#   - 新增默认路由变化检测：切 ccmni / CLAT 重建后立即补写参数。
#   - 重连前检查基带温度，≥55C（降功率中）不折腾网络，推迟 10 分钟。

MODDIR=${0%/*}
NBDIR=/data/local/tmp/netboost
PIDF=$NBDIR/hold.pid
NB=$MODDIR/bin/netboost.sh
WLOG=$NBDIR/watch.log
EVENTS=$NBDIR/events.csv
mkdir -p "$NBDIR" 2>/dev/null

# v2.4：事件账本（引擎与守护共用格式：时间戳,类型,描述）
add_event() {
  echo "$(date +%s),$1,$2" >> "$EVENTS"
  if [ "$(wc -l < "$EVENTS" 2>/dev/null)" -gt 500 ]; then
    tail -300 "$EVENTS" > "$EVENTS.t" 2>/dev/null && mv "$EVENTS.t" "$EVENTS"
  fi
}

BB=""
for c in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/bin/busybox; do
  [ -x "$c" ] && { BB="$c"; break; }
done

cur_if() {
  if [ -n "$BB" ]; then "$BB" ip -o route get 223.5.5.5 2>/dev/null
  else ip -o route get 223.5.5.5 2>/dev/null; fi \
    | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1
}

rotate_log() {
  [ -f "$WLOG" ] || return 0
  [ "$(wc -c < "$WLOG" 2>/dev/null)" -gt 204800 ] || return 0
  tail -500 "$WLOG" > "$WLOG.t" 2>/dev/null && mv "$WLOG.t" "$WLOG"
}

# ---- 防重入：pid 存活且确实是本服务的循环 ----
if [ -f "$PIDF" ]; then
  op=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$op" ] && kill -0 "$op" 2>/dev/null; then
    if grep -q "t5m_netboost" "/proc/$op/cmdline" 2>/dev/null; then
      exit 0
    fi
  fi
fi
echo $$ > "$PIDF"

i=0
while [ $i -lt 180 ]; do
  [ "$(getprop sys.boot_completed)" = "1" ] && break
  sleep 1
  i=$((i + 1))
done
sleep 20

chmod 755 "$NB" 2>/dev/null
sh "$NB" apply > "$NBDIR/boot.log" 2>&1
LAST_IF=$(cur_if)
echo "[$(date '+%F %T')] service start pid=$$ iface=$LAST_IF" >> "$NBDIR/service.log"

# ---- 主循环 ----
fail=0
last_rc=0
tick=0
while true; do
  sleep 60
  tick=$((tick + 1))

  # 1) 信号采样（60s）+ 流量采样（60s，今日/本月/速率由它维护）
  sh "$NB" sample >/dev/null 2>&1
  sh "$NB" traffic >/dev/null 2>&1

  # 2) 参数漂移修复（每 5 分钟）：切网后的回收值在这里被补回
  if [ $((tick % 5)) -eq 0 ]; then
    sh "$NB" refresh quiet >/dev/null 2>&1
    rotate_log
  fi

  # 3) 默认路由变化（切 ccmni / CLAT 重建）→ 等链路稳定后补写
  now_if=$(cur_if)
  if [ -n "$now_if" ] && [ "$now_if" != "$LAST_IF" ]; then
    echo "[$(date '+%F %T')] 链路切换 $LAST_IF -> $now_if，补写参数" >> "$NBDIR/service.log"
    add_event switch "route_${LAST_IF}_to_${now_if}"
    LAST_IF=$now_if
    sleep 10
    sh "$NB" refresh quiet >> "$NBDIR/service.log" 2>&1
    continue
  fi

  # 4) 掉线守护
  [ -f "$NBDIR/watch.off" ] && continue
  if sh "$NB" online >/dev/null 2>&1; then
    fail=0
    continue
  fi

  fail=$((fail + 1))
  now=$(date +%s)
  [ $fail -ge 3 ] || continue
  [ $((now - last_rc)) -ge 900 ] || continue

  # v2.4 防呆：默认路由走 WiFi/以太网时，掉线与蜂窝无关，不操作数据连接
  case "$(cur_if)" in
    wlan*|eth*|ap*)
      [ $fail -eq 3 ] && add_event skip "default_route_$(cur_if)_not_cellular"
      continue
    ;;
  esac

  # 基带降功率时不折腾网络（温度高时重连只会更慢）
  t=$(cat /sys/class/thermal/thermal_zone57/temp 2>/dev/null)
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  if [ "$t" -ge 55000 ]; then
    echo "[$(date '+%F %T')] 判活失败 $fail 次，但 NR-PA $((t / 1000))C 降功率中，推迟重连" >> "$WLOG"
    add_event temp "hold_at_nrpa_$((t / 1000))C_fail_$fail"
    last_rc=$((now - 300))
    continue
  fi

  add_event drop "offline_${fail}_probes_iface_${LAST_IF:-none}"
  echo "[$(date '+%F %T')] 连续 $fail 次判活失败（三通道），自动重连" >> "$WLOG"
  sh "$NB" reconnect >> "$WLOG" 2>&1
  if sh "$NB" online >/dev/null 2>&1; then
    add_event recover "reconnect_ok_in_$(( $(date +%s) - now ))s"
  else
    add_event recover "reconnect_failed_or_slow"
  fi
  last_rc=$now
  fail=0
done
