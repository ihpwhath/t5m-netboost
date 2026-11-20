#!/system/bin/sh
# 卸载：先还原参数，再结束常驻循环，最后清运行目录
MODDIR=${0%/*}
NBDIR=/data/local/tmp/netboost

if [ -f "$NBDIR/hold.pid" ]; then
    kill "$(cat "$NBDIR/hold.pid" 2>/dev/null)" 2>/dev/null
fi

# 备份在模块目录（$MODDIR/data/backup.conf），老版本在 /data/local/tmp/netboost
if [ -f "$MODDIR/bin/netboost.sh" ] && \
   { [ -f "$MODDIR/data/backup.conf" ] || [ -f "$NBDIR/backup.conf" ]; }; then
    sh "$MODDIR/bin/netboost.sh" restore > /dev/null 2>&1
fi

rm -rf "$NBDIR"
