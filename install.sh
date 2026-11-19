#!/bin/bash
# ============================================================================
#  install.sh — CMP30HX on Linux 一键安装
#
#  用法（普通用户，会提示输入 sudo 密码）：
#      curl -fsSL -o /tmp/cmp30hx-install.sh     https://raw.githubusercontent.com/<user>/CMP30HX-on-linux/main/install.sh
#      sudo bash /tmp/cmp30hx-install.sh
#
#  或者已经 clone 了仓库：
#      sudo ./install.sh
#
#  它会自动完成：
#     1. 检查环境（x86_64 / root / 内核头文件）
#     2. 从 GitHub 拉取仓库（或使用当前目录这份）
#     3. 安装编译依赖
#     4. 编译 4 个内核模块
#     5. 安装到当前内核并加载验证
#     6. 需要时提示重启
#
#  可用环境变量：
#     REPO_URL=<git 地址>   REPO_BRANCH=main
#     INSTALL_DIR=/opt/CMP30HX-on-linux
#     KVER=<内核版本>  JOBS=<并行数>  SKIP_DEPS=1  FORCE=1
# ============================================================================
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/YOUR_GITHUB_USER/CMP30HX-on-linux.git}
REPO_BRANCH=${REPO_BRANCH:-main}
INSTALL_DIR=${INSTALL_DIR:-/opt/CMP30HX-on-linux}
KVER=${KVER:-$(uname -r)}
SKIP_DEPS=${SKIP_DEPS:-0}
FORCE=${FORCE:-0}
REPO_DIR=""

BLUE='\033[1;34m'; GREEN='\033[1;32m'; RED='\033[1;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { printf "${BLUE}==>${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}  ✓${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}  ! ${NC}%s\n" "$*" >&2; }
die()  { printf "${RED}ERROR:${NC} %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. 以 root 检查 / 自动提权
#
# 注意：不要用 "curl ... | bash" —— curl|bash 会把 stdin 交给脚本，
# sudo 和 apt 的交互提示读不到终端。请先 curl -o 保存，再 sudo bash 运行。
# ---------------------------------------------------------------------------
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
[ -f "$SELF" ] || die "请先把脚本保存到本地再执行：curl -o install.sh <url> && sudo bash install.sh"

if [ "$(id -u)" -ne 0 ]; then
    if [ -t 0 ]; then
        log "需要 root 权限，正在通过 sudo 重新执行"
        exec sudo -E bash "$SELF" "$@"
    fi
    die "请以 root 运行：sudo bash $SELF"
fi

SUDO_USER_="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REPO_OWNER_HOME=$(getent passwd "$SUDO_USER_" | cut -d: -f6)
[ -n "$REPO_OWNER_HOME" ] && [ -d "$REPO_OWNER_HOME" ] || REPO_OWNER_HOME=/root

# ---------------------------------------------------------------------------
# 1. 环境检查
# ---------------------------------------------------------------------------
log "环境检查"
[ "$(uname -m)" = "x86_64" ] || die "仅支持 x86_64，当前是 $(uname -m)"
ok "架构 x86_64"
ok "内核 $KVER（运行中：$(uname -r)）"
[ -f "/usr/src/linux-headers-$KVER/Makefile" ] || {
    log "缺少内核头文件，尝试安装 linux-headers-$KVER"
    apt-get update -qq
    apt-get install -y "linux-headers-$KVER" || die "内核头文件安装失败，请手动: apt install linux-headers-$KVER"
}
ok "内核头文件已就位"

if command -v nvidia-smi >/dev/null 2>&1; then
    ok "已安装 NVIDIA 用户态驱动"
else
    warn "未检测到 nvidia-smi，将随安装一并部署"
fi

# ---------------------------------------------------------------------------
# 2. 拿代码：当前目录有仓库就用它，否则从 GitHub 拉到 INSTALL_DIR
# ---------------------------------------------------------------------------
SELF_DIR=$(dirname "$SELF")
if [ -f "$SELF_DIR/build.sh" ] && [ -f "$SELF_DIR/patches/30hx-mod.patch" ]; then
    REPO_DIR=$SELF_DIR
    log "使用本地仓库：$REPO_DIR"
else
    log "从 GitHub 获取仓库：$REPO_URL"
    command -v git >/dev/null || { apt-get install -y git; }
    if [ -d "$INSTALL_DIR/.git" ]; then
        git -C "$INSTALL_DIR" fetch --depth=1 origin "$REPO_BRANCH"
        git -C "$INSTALL_DIR" reset --hard "origin/$REPO_BRANCH"
    else
        git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
    fi
    REPO_DIR=$INSTALL_DIR
fi
[ -f "$REPO_DIR/build.sh" ] || die "仓库内容不完整：$REPO_DIR"
ok "代码位置 $REPO_DIR"

# ---------------------------------------------------------------------------
# 3. 依赖
# ---------------------------------------------------------------------------
if [ "$SKIP_DEPS" != "1" ]; then
    log "安装编译依赖"
    apt-get install -y -qq \
        build-essential "linux-headers-$KVER" dkms \
        binutils kmod bc bison flex libssl-dev libelf-dev >/dev/null
    # pahole 可选：有就装，让模块带上 BTF
    apt-get install -y -qq pahole >/dev/null 2>&1 && ok "pahole 已安装（模块将包含 BTF）" || warn "pahole 未安装，跳过 BTF（不影响加载）"
    ok "依赖就绪"
else
    warn "SKIP_DEPS=1，跳过依赖安装"
fi

# ---------------------------------------------------------------------------
# 4. 检查是否已安装，避免重复
# ---------------------------------------------------------------------------
INSTALLED_MARK=/lib/modules/$KVER/updates/dkms/nvidia.ko
if [ -f "$INSTALLED_MARK" ] && [ "$FORCE" != "1" ]; then
    if lsmod | grep -q '^nvidia '; then
        ok "驱动已安装并已加载，无需重复安装"
        nvidia-smi 2>/dev/null || true
        echo
        echo "如需重装：FORCE=1 sudo bash $SELF"
        exit 0
    fi
    if ! lsmod | grep -q '^nouveau'; then
        log "模块已安装但未加载（可能还没 modprobe），尝试直接加载"
        modprobe nvidia 2>/dev/null && modprobe nvidia-uvm 2>/dev/null || true
        if lsmod | grep -q '^nvidia '; then
            ok "加载成功"
            nvidia-smi 2>/dev/null || true
            exit 0
        fi
    fi
    warn "模块已存在但未加载，继续执行安装流程"
fi

# ---------------------------------------------------------------------------
# 5. 编译
# ---------------------------------------------------------------------------
log "编译内核模块（目标内核 $KVER）"
cd "$REPO_DIR"
chown -R "$SUDO_USER_:$SUDO_USER_" "$REPO_DIR" 2>/dev/null || true

# 以普通用户编译，避免 root 污染工作目录；失败时回退到 root 编译
if [ "$SUDO_USER_" != "root" ] && command -v sudo >/dev/null; then
    log "以 $SUDO_USER_ 身份编译"
    sudo -u "$SUDO_USER_" env KVER="$KVER" JOBS="${JOBS:-$(nproc)}" ./build.sh || {
        warn "普通用户编译失败，改用 root 重试"
        env KVER="$KVER" ./build.sh
    }
else
    env KVER="$KVER" ./build.sh
fi

# ---------------------------------------------------------------------------
# 6. 安装 + 加载
# ---------------------------------------------------------------------------
log "安装并加载（目标内核 $KVER）"
KVER="$KVER" ./build.sh --install

# ---------------------------------------------------------------------------
# 7. 收尾提示
# ---------------------------------------------------------------------------
echo
printf "${GREEN}============================================================${NC}\n"
printf "${GREEN}  CMP30HX on Linux 安装完成${NC}\n"
printf "${GREEN}============================================================${NC}\n"
echo
if [ "$KVER" != "$(uname -r)" ]; then
    cat <<EOF
模块已为目标内核 $KVER 安装好，但当前运行的是 $(uname -r)。
  1) 重启进入 $KVER：sudo reboot
  2) 重启后执行：sudo modprobe nvidia && sudo modprobe nvidia-uvm && nvidia-smi
EOF
elif ! lsmod | grep -q '^nvidia '; then
    cat <<'EOF'
模块已安装，但尚未加载（nouveau 可能在首次安装时仍占用显卡）。
  1) 重启一次：sudo reboot
  2) 重启后执行：sudo modprobe nvidia && sudo modprobe nvidia-uvm && nvidia-smi
EOF
else
    echo "驱动已加载，验证信息："
    nvidia-smi || true
    echo
    echo "PCIe 链路："
    nvidia-smi -q 2>/dev/null | sed -n '/PCIe Generation/,/Link Width/,+4p' || true
fi

cat <<EOF

后续命令：
  查看状态   : nvidia-smi
  重新编译   : cd $REPO_DIR && sudo ./build.sh --install
  内核升级后 : cd $REPO_DIR && sudo ./install.sh
  卸载       : sudo rm -rf /lib/modules/$KVER/updates/dkms/nvidia*.ko && sudo depmod -a
               sudo rm -f /etc/modprobe.d/nvidia-cmp30hx.conf
               sudo apt purge nvidia-driver 2>/dev/null || true

日志位置：$REPO_DIR/.work/
EOF
