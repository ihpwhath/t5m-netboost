#!/system/bin/sh
# T5M终极网络优化 — 安装器入口
# 唯一职责：补权限。不读 zip、不查外部文件、任何分支都 exit 0，
# 保证 KernelSU / Magisk 刷入必定成功。
# 注意：包内不得存在 install.sh，否则会被当成安装器执行。

MP="${MODPATH:-}"
if [ -z "$MP" ] || [ ! -f "$MP/module.prop" ]; then
    MP=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
fi
if [ -z "$MP" ] || [ ! -f "$MP/module.prop" ]; then
    MP=$(pwd)
fi

if [ -n "$MP" ] && [ -f "$MP/module.prop" ]; then
    chmod 755 "$MP/bin/netboost.sh"  2>/dev/null
    chmod 755 "$MP/service.sh"       2>/dev/null
    chmod 755 "$MP/uninstall.sh"     2>/dev/null
    chmod 755 "$MP/action.sh"        2>/dev/null
    chmod 755 "$MP/manual-install.sh" 2>/dev/null
    chmod 644 "$MP/module.prop"      2>/dev/null
    chmod 644 "$MP/webroot/index.html" 2>/dev/null
    chmod 644 "$MP/README.md"        2>/dev/null
    chown -R 0:0 "$MP"               2>/dev/null
    rm -f "$MP/update"               2>/dev/null
    echo "+ 权限已设置"
else
    echo "+ 权限沿用打包值，无需调整"
fi

echo "+ 安装完成，重启后生效；也可直接进入模块页控制台"
exit 0
