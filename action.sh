#!/system/bin/sh
# T5M终极网络优化 —— 模块页「操作」按钮入口  v2.4.1
MODDIR=${0%/*}
BIN="$MODDIR/bin/netboost.sh"

if [ ! -x "$BIN" ]; then
    echo "x 模块不完整：$BIN 缺失或不可执行"
    echo "  修复：su -c 'sh /path/to/manual-install.sh /storage/emulated/0/模块/t5m定制网络优化-v2.4.1.zip'"
    exit 1
fi

banner() {
    VER=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
    echo "  ┌──────────────────────────────────────┐"
    echo "  │  T5M终极网络优化  ${VER:-v2.4.1}   ks轨迹      │"
    echo "  │  REDMI Turbo 5 Max · 中国广电 46015  │"
    echo "  └──────────────────────────────────────┘"
}

# 无 TTY（管理器一次性执行）时只输出摘要
if [ ! -t 0 ]; then
    banner
    echo
    sh "$BIN" status
    echo
    echo "图形控制台：模块页面点「打开」"
    exit 0
fi

while :; do
    clear 2>/dev/null
    banner
    echo
    sh "$BIN" sig
    echo
    echo "   1) 应用参数        2) 重连信号"
    echo "   3) 单流测速        4) 完整诊断"
    echo "   5) APN 校验        6) 链路质量"
    echo "   7) 刷新参数        8) 还原默认"
    echo "   9) 全量状态       10) 流量统计"
    echo "  11) 事件账本       12) 测速历史"
    echo "  13) 诊断报告        0) 退出"
    printf "\n  选择 > "
    read -r c || exit 0
    echo
    case "$c" in
        1) sh "$BIN" apply ;;
        2) sh "$BIN" reconnect ;;
        3) sh "$BIN" bench ;;
        4) sh "$BIN" diag ;;
        5) sh "$BIN" apn ;;
        6) sh "$BIN" health ;;
        7) sh "$BIN" refresh ;;
        8)
            printf "  确认回滚到系统默认？(y/N) "
            read -r y
            [ "$y" = "y" ] || [ "$y" = "Y" ] && sh "$BIN" restore || echo "  已取消"
            ;;
        9) sh "$BIN" status ;;
       10) sh "$BIN" traffic ;;
       11) sh "$BIN" events 20 ;;
       12) sh "$BIN" benchhist ;;
       13) sh "$BIN" report ;;
        0|q|Q|"") exit 0 ;;
        *) echo "  无效选项" ;;
    esac
    printf "\n  回车继续…"
    read -r _ || exit 0
done
