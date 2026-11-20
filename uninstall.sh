#!/bin/bash
# ============================================================================
#  uninstall.sh — 卸载 CMP30HX on Linux 安装的驱动
#
#  用法：sudo ./uninstall.sh
#        sudo ./uninstall.sh --keep-userspace   # 只卸内核模块，保留 nvidia-smi 等
#        sudo ./uninstall.sh --restore-grub     # 同时还原内核命令行（恢复 nouveau）
# ============================================================================
set -uo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KVER=${KVER:-$(uname -r)}
KEEP_USER=0
RESTORE_GRUB=0
for a in "$@"; do
    case "$a" in
        --keep-userspace) KEEP_USER=1 ;;
        --restore-grub) RESTORE_GRUB=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "未知参数：$a" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行：sudo $REPO_DIR/uninstall.sh" >&2; exit 1; }

echo "==> 卸载内核模块（$KVER）"
rm -f /lib/modules/"$KVER"/updates/dkms/nvidia*.ko
depmod -a "$KVER" 2>/dev/null || true

echo "==> 移除 nouveau 屏蔽"
rm -f /etc/modprobe.d/nvidia-cmp30hx.conf
rm -f /etc/modprobe.d/nvidia-30hx-mod.conf

if command -v lsmod >/dev/null 2>&1 && lsmod | grep -q '^nvidia '; then
    modprobe -r nvidia_uvm 2>/dev/null || true
    modprobe -r nvidia_drm 2>/dev/null || true
    modprobe -r nvidia_modeset 2>/dev/null || true
    modprobe -r nvidia 2>/dev/null || true
fi

if [ "$RESTORE_GRUB" -eq 1 ] && [ -f /etc/default/grub ]; then
    echo "==> 还原内核命令行"
    cp -f /etc/default/grub /etc/default/grub.bak.uninstall.$(date +%s)
    sed -i 's/ *nouveau\.modeset=0//g; s/ *rd\.driver\.blacklist=nouveau//g' /etc/default/grub
    command -v update-grub >/dev/null && update-grub >/dev/null
fi

if [ "$KEEP_USER" -eq 0 ]; then
    echo "==> 卸载用户态驱动（可选，按需确认）"
    if command -v nvidia-uninstall >/dev/null 2>&1; then
        nvidia-uninstall --silent || echo "  nvidia-uninstall 未完成，可忽略"
    else
        echo "  未找到 nvidia-uninstall（可能是发行版包安装的），手动清理：apt purge 'nvidia-*'"
    fi
fi

echo "==> 重建 initramfs（让 nouveau 重新在启动时可加载）"
if [ -d /etc/initramfs-tools ]; then
    update-initramfs -u -k "$KVER" >/dev/null 2>&1 || true
elif command -v dracut >/dev/null 2>&1; then
    dracut --force >/dev/null 2>&1 || true
fi

echo
echo "完成。重启后恢复 open 驱动（nouveau）：sudo reboot"
