#!/system/bin/sh
# T5M终极网络优化 — 双模安装脚本
#
# A 管理器安装器模式：KernelSU/Magisk 解压后自动调用本脚本，
#   此时文件已在 /data/adb/modules_update/<id>，只需补权限，直接成功退出。
# B 手动兜底模式：su -c 'sh manual-install.sh [zip路径]'
#   用于绕过 ksud 只复制 module.prop 的缺陷。

MODID=t5m_netboost
DST=/data/adb/modules/$MODID
RUN=/data/local/tmp/netboost

fix_perm() {
    _d=$1
    chmod 755 "$_d/service.sh" "$_d/uninstall.sh" "$_d/customize.sh" \
              "$_d/action.sh" "$_d/manual-install.sh" 2>/dev/null
    chmod 755 "$_d/bin/netboost.sh" 2>/dev/null
    chmod 644 "$_d/module.prop" "$_d/README.md" "$_d/webroot/index.html" 2>/dev/null
    chown -R 0:0 "$_d" 2>/dev/null
    rm -f "$_d/update" 2>/dev/null
}

# ---------- A 管理器安装器模式 ----------
SRC="${MODPATH:-}"
[ -n "$SRC" ] || SRC=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
if [ -n "$SRC" ] && [ -f "$SRC/module.prop" ]; then
    case "$SRC" in
        /data/adb/modules_update/*|/data/adb/modules/*)
            fix_perm "$SRC"
            echo "+ 安装器模式：权限已设置（$SRC）"
            echo "- 重启后生效；也可直接通过模块页控制台使用"
            exit 0
            ;;
    esac
fi

# ---------- B 手动兜底模式 ----------
[ "$(id -u)" = "0" ] || { echo "x 需要 Root：su -c 'sh manual-install.sh'"; exit 1; }

install_from_dir() {
    _s=$1
    if [ -f "$DST/bin/netboost.sh" ] && [ -f "$RUN/backup.conf" ]; then
        sh "$DST/bin/netboost.sh" restore >/dev/null 2>&1 && echo "+ 已还原旧版本参数"
    fi
    rm -rf "$DST"
    mkdir -p "$DST"
    cp -a "$_s"/. "$DST"/ 2>/dev/null || { echo "x 复制失败：$_s"; return 1; }
    fix_perm "$DST"
    echo "+ 已安装到 $DST（$(find "$DST" -type f 2>/dev/null | wc -l) 个文件）"
    sh "$DST/bin/netboost.sh" apply
    echo
    echo "+ 完成。模块页可打开图形控制台；重启后自动应用并每 300s 重刷。"
}

# B1 显式传入 zip 优先
ZIP="${1:-}"
if [ -n "$ZIP" ] && [ -f "$ZIP" ]; then
    if [ -f "$DST/bin/netboost.sh" ] && [ -f "$RUN/backup.conf" ]; then
        sh "$DST/bin/netboost.sh" restore >/dev/null 2>&1 && echo "+ 已还原旧版本参数"
    fi
    rm -rf "$DST"
    mkdir -p "$DST"
    unzip -o "$ZIP" -d "$DST" >/dev/null 2>&1 || { echo "x 解压失败，zip 可能损坏：$ZIP"; exit 1; }
    fix_perm "$DST"
    echo "+ 已安装到 $DST（$(find "$DST" -type f 2>/dev/null | wc -l) 个文件）"
    sh "$DST/bin/netboost.sh" apply
    echo
    echo "+ 完成。模块页可打开图形控制台；重启后自动应用并每 300s 重刷。"
    exit $?
fi

# B2 从包内目录就地安装（用户在 Download 解压后直接跑本脚本）
if [ -n "$SRC" ] && [ -f "$SRC/module.prop" ] && [ -f "$SRC/bin/netboost.sh" ] \
   && [ "$SRC" != "$DST" ]; then
    install_from_dir "$SRC"
    exit $?
fi

# B3 自动探测 Download 目录里的最新包
ZIP=""
for _c in /storage/emulated/0/模块/t5m定制网络优化-v2.4.1.zip /storage/emulated/0/模块/t5m定制网络优化-*.zip; do
    [ -f "$_c" ] && ZIP="$_c" && break
done
if [ -z "$ZIP" ] || [ ! -f "$ZIP" ]; then
    echo "x 找不到模块 zip"
    echo "  用法：su -c 'sh /path/to/manual-install.sh /storage/emulated/0/模块/t5m定制网络优化-v2.4.1.zip'"
    echo "  或把 zip 放到 /sdcard/Download 后直接执行本脚本"
    exit 1
fi

if [ -f "$DST/bin/netboost.sh" ] && [ -f "$RUN/backup.conf" ]; then
    sh "$DST/bin/netboost.sh" restore >/dev/null 2>&1 && echo "+ 已还原旧版本参数"
fi
rm -rf "$DST"
mkdir -p "$DST"
unzip -o "$ZIP" -d "$DST" >/dev/null 2>&1 || { echo "x 解压失败，zip 可能损坏：$ZIP"; exit 1; }
fix_perm "$DST"
echo "+ 已安装到 $DST（$(find "$DST" -type f 2>/dev/null | wc -l) 个文件）"
sh "$DST/bin/netboost.sh" apply
echo
echo "+ 完成。模块页可打开图形控制台；重启后自动应用并每 300s 重刷。"
