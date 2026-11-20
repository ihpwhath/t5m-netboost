# T5M终极网络优化 v2.4.1

REDMI Turbo 5 Max（2602BRT18C / dash / mt6991 / Android 17 / HyperOS V816）专用网络工具。
作者：ks轨迹。实测数据驱动，不承诺提速，只做可验证的真事。v2.4.1 修复「生成报告」无反应；v2.4 新增流量计量、事件账本、测速历史、一键报告与守护防呆。

## 先说结论（实测，不是推测）

| 项目 | 本机实测 | 含义 |
|---|---|---|
| 载波 | n28 / 30MHz（有时可驻留 n41 / 100MHz） | 带宽决定上限，软件改不了 |
| 单流吞吐 | 约 6.8 Mbps | — |
| 4 流聚合 | 约 6.9 Mbps（≈单流） | **网络侧封顶**，终端参数无法突破 |
| RTT | 90~105 ms | BDP≈0.1MB，16MB 缓冲已是 160 倍余量 |
| PMTU | 1500 全通（1472/1400/1200 皆可） | 不需要改 MTU，改 MTU 是玄学 |
| DNS | 223.5.5.5 / 119.29.29.29 / 运营商 DNS 均 500~1100ms | 是路径 RTT+NAT64 开销，换 DNS 无解 |
| TCP 重传 | TCPLostRetransmit 9093 / TCPOrigDataSent 1212228 ≈ 0.75% | 轻微丢包，单流会被压，多线程可缓解 |

所以本模块**不承诺提速**，它做的是三件真事：把终端侧的参数保持在位、把切网后的参数回收补回来、让真掉线能自动恢复且不误伤。

## v2.4.1 修复（控制台「生成报告」点了没反应）

1. **report 提速 4.5 倍**：`drift_count` 与 sysctl 展示改为单次 awk 读取，去掉 70 多次 fork。status 2.36s → 0.53s，`report` 全量 5.7s → 3.6s，`report fast` 1.25s。KernelSU WebUI 的 `ksu.exec` 是同步调用，命令跑多久页面就哑多久，这是"点了没用"的直接原因。
2. **报告落盘**：写到 `/sdcard/Download/T5M_report_<时间>.txt`（已去 ANSI 转义），副本存 `/data/local/tmp/netboost/report_last.txt`，控制台 toast 直接给出文件名。
3. **重传率段落不再被吞**：旧版 `do_report` 里 `do_health > /dev/null 2>&1` 把 TCP 重传率整段丢掉了，现在正常打印。
4. **`report fast` 快速模式**：跳过 wget 204 探测与 DNS64 查询，WebUI 默认走这条，1.2 秒出结果；终端里 `sh netboost.sh report` 仍是全量。
5. **执行期间停轮询**：长命令跑的时候暂停图表/事件/测速轮询，避免和 `ksu.exec` 抢主线程把点击吃掉。

验证：控制台点「生成报告」→ 1~2 秒出内容 + toast 显示 `已存 Download/T5M_report_xxx.txt`；`adb shell ls -l /sdcard/Download/T5M_report_*.txt` 有新文件；`sh /data/adb/modules/t5m_netboost/bin/netboost.sh report fast` 返回码 0。

## v2.4 新增（每条都可验证）

1. **流量计量**：按数据接口（ccmni）独立计数，今日/本月/实时速率，持久化到模块 data 目录，重启不丢。reconnect 会把接口计数器清零，已做重置检测（新读数 < 旧读数时按新读数从零累加）。验证：控制台「流量与速率」卡，与系统设置里的用量对照应同量级。
2. **事件账本**：掉线（drop）/ 重连结果（recover）/ 高温推迟（temp）/ 链路切换（switch）/ WiFi 跳过（skip）/ 测速（bench）全部记录到 `events.csv`，控制台直接看。连续多日掉线规律、找运营商投诉，凭据就是它。
3. **测速历史**：每次 `bench` 自动落档（时间/规模/Mbps），连着看能识别"达量限速"——白天慢半夜快、或月初快月底慢，就是套餐问题，不是手机问题。
4. **一键报告**：`report` 把设备状态 + 链路质量 + 三通道体检 + 事件 + 流量 + 测速拼成一份纯文本，复制即发。
5. **TCP keepalive 三件套**（time 7200→300、intvl=30、probes=5）：移动网络 NAT 会静默回收空闲 TCP 长连接，默认 2 小时才发首个保活探测，早被回收了。改 300 秒后长连接保持能力显著增强。验证：`cat /proc/sys/net/ipv4/tcp_keepalive_time` 期望 300。
6. **守护 WiFi 防呆**：连着 WiFi 时默认路由走 wlan，此时掉线与蜂窝无关，旧版仍会断蜂窝重连白断 10 秒。现检测默认路由，非蜂窝接口只记事件不动网络。
7. **基带温度进趋势图**：NR-PA 温度曲线与带宽/SINR 同图，过热降速一眼可见（橙色曲线，55C 以上为降功率区）。

## v2.3 修了什么（每条都可复现验证）

1. **体检恒判 IPv6 断链**：Android toybox 的 ping 不认 `-4/-6`（`invalid option`, rc=2），旧版在 `/system/bin/sh` 路径下必判失败。现全部走 busybox ping。
   验证：`sh netboost.sh probe` → 修前必为 `! IPv6 不可达`，修后应为 `+ IPv6 直连可达`。
2. **每 15 分钟误重连**：旧版守护用 `ping -6 || ping -4`，同上必失败，`watch.log` 留下 22 条 900s 等距记录，等于每 15 分钟白断网 10 秒。现改为 ICMP 双栈 + HTTP 204 三通道判活。
3. **32MB 缓冲根本留不住**：HyperOS 切网会回收 `tcp_rmem/wmem` 中间值，旧版只 apply 一次且 README 承诺的"每 5 分钟重刷"没实现。现改为每 5 分钟 `refresh`，只修漂移项，并新增默认路由变化检测（切 ccmni 后立即补写）。
4. **32MB 本身无意义**：实测 BDP≈0.1MB，改 16MB 上限，省内存、减少内存压力丢包。
5. **tcp_ecn 由 1 改回 2（被动）**：实测链路 TCPTimeouts 14345、TCPSynRetrans 10789，在 464XLAT/NAT64 路径上主动协商 ECN 无收益。
6. **新增 tcp_retries2=8**：移动网进电梯/切网后连接僵死，默认要 ~15 分钟才判死，现在约 100 秒重连。这是体感最明显的改动。
7. **新增 `health`**：直接读 `/proc/net/netstat` 算真实重传率，量化链路质量，不再靠"感觉快了"。
8. **备份迁出 /data/local/tmp** 到模块目录，tmp 被清也不丢回滚能力；老备份自动迁移。
9. 数据接口按默认路由取（实测 ccmni2），不再盲取第一个 `ccmni`。
10. 版本号收口到 module.prop，安装提示与包内文件名对齐。

## 明确不做的（玄学项）

- 不改 MTU：PMTU 1500 全通，改了只会引入黑洞风险。
- 不换 DNS / 不开 DoT：三个公共 DNS 与运营商 DNS 延迟一致，加 DoT 只会多一跳 TLS。
- 不锁频段：Android 无公开接口，MTK 工程模式要 UI 手工操作；`band n41` 只做"断开重连触发重选"，最多 3 次，失败如实报"该区域覆盖不足"。
- 不追 32MB/64MB 缓冲、不改 `netdev_max_backlog` 之类对客户端无感的参数（保留默认值）。

## 控制台

KernelSU 管理器 → 模块 → T5M终极网络优化 → 打开。

- 实时 Band / 带宽 / RSRP / RSRQ / SINR / PCI / ARFCN / 基带温度
- 流量与速率（今日/本月/实时速率，独立计量）
- 信号趋势图（带宽 / SINR / RSRP / 基带温度四线）
- 网络事件账本 + 测速历史
- 一键：应用参数 / 刷新参数 / 重连 / 链路体检 / 链路质量 / 测速 / 诊断 / 报告 / APN / 守护开关 / 还原默认

模块页「操作」按钮提供终端菜单版，功能等价。

## 命令

```sh
B=/data/adb/modules/t5m_netboost/bin/netboost.sh
su -c "sh $B status"     # 全量快照（含漂移计数）
su -c "sh $B health"     # 真实重传率 + 判定
su -c "sh $B json"       # 单行 JSON（控制台）
su -c "sh $B apply"      # 应用（自动备份）
su -c "sh $B refresh"    # 只修漂移项
su -c "sh $B restore"    # 回滚（归档带时间戳）
su -c "sh $B reconnect"  # 断开重连 + 自动补写参数
su -c "sh $B bench"      # 单流 5MB
su -c "sh $B diag"       # 空口 + MTU + 单流/多流对照
su -c "sh $B probe"      # IPv6/NAT64/HTTP 三通道
su -c "sh $B band n41"   # 最多 3 次重选试图驻留 n41
su -c "sh $B watch off"  # 停用守护
su -c "sh $B traffic"    # 流量采样 + 今日/本月/速率（JSON）
su -c "sh $B events 20"  # 最近 20 条事件（JSON）
su -c "sh $B benchhist"  # 最近测速历史（JSON）
su -c "sh $B report"     # 一键诊断报告
su -c "sh $B online"; echo $?   # 0=在线 1=离线
```

## 安装

管理器直接刷 zip 即可（本版不再依赖任何外部文件）。

如果管理器装完只剩 `module.prop`（某些 ksud 版本的已知缺陷），用兜底：

```sh
su -c 'sh /path/to/manual-install.sh /storage/emulated/0/模块/t5m定制网络优化-v2.4.1.zip'
```

## 验证

```sh
B=/data/adb/modules/t5m_netboost/bin/netboost.sh
su -c "sh $B probe"                       # 期望看到 + IPv6 直连可达
su -c "sh $B status" | tail -3            # 期望 参数漂移 0 项
su -c "cat /proc/sys/net/ipv4/tcp_retries2"   # 期望 8
su -c "cat /proc/sys/net/ipv4/tcp_ecn"        # 期望 2
su -c "cat /proc/sys/net/ipv4/tcp_keepalive_time"   # 期望 300（v2.4）
su -c "cat /proc/sys/net/ipv4/tcp_keepalive_intvl"  # 期望 30
su -c "cat /proc/sys/net/ipv4/tcp_keepalive_probes" # 期望 5
su -c "cat /proc/sys/net/core/rmem_max"       # 期望 16777216
su -c "pgrep -f t5m_netboost/service.sh"      # 期望 1 个
su -c "tail -5 /data/local/tmp/netboost/service.log"   # 切网补写事件在这里
```

跑满 30 分钟后再看 `watch.log`：不应出现"自动重连"（真断网除外）。若出现，日志里会带三通道失败记录与当时温度。

## 回滚

```sh
su -c 'sh /data/adb/modules/t5m_netboost/bin/netboost.sh restore'
```

备份在 `/data/adb/modules/t5m_netboost/data/backup.conf`，每次 restore 归档为带时间戳的副本。
卸载模块时 `uninstall.sh` 会先 restore 再清运行目录。
