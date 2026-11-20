#!/bin/bash
# ============================================================================
#  install.sh — CMP30HX on Linux 一键安装（以 root 在仓库目录里运行）
#
#  推荐用法：
#      git clone https://github.com/YOUR_GITHUB_USER/CMP30HX-on-linux.git
#      cd CMP30HX-on-linux
#      sudo ./install.sh            # 或者直接 sudo bash install.sh
#
#  脚本会自己：
#     [1] 检测发行版 / 包管理器 / 架构 / 内核
#     [2] 检测并安装缺失的构建依赖（apt / dnf / pacman / zypper / apk）
#     [3] 检测并安装内核头文件（多种包名 / 多发行版 / 已解包的头文件目录）
#     [4] 拉取 NVIDIA 615.78.08 官方包（支持离线：把 .run 放到仓库根目录）
#     [5] 打 CMP 30HX 补丁并编译内核模块
#     [6] 安装用户态库 + 内核模块，屏蔽 nouveau（含 initramfs 和 grub）
#     [7] 加载并验证（能加载就立即验证，需要重启就明确告诉用户）
#
#  可选环境变量（一般不用设）：
#      KVER=<内核版本>      目标内核，默认当前运行内核
#      JOBS=<并行数>        默认 nproc
#      FORCE=1              已装也强制重装
#      SKIP_DEPS=1          不自动安装依赖
#      NO_NEWVOUX=1         不改内核命令行 / 不重建 initramfs
#      REBOOT=1             需要重启时自动重启（默认只是提示）
#      NO_COLOR=1           关闭彩色输出
# ============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# 全局
# ---------------------------------------------------------------------------
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KVER=${KVER:-$(uname -r)}
JOBS=${JOBS:-$(nproc)}
FORCE=${FORCE:-0}
SKIP_DEPS=${SKIP_DEPS:-0}
NO_NEWVOUX=${NO_NEWVOUX:-0}
REBOOT=${REBOOT:-0}
LOG=$REPO_DIR/.work/install.log
NEED_REBOOT=0
STEP=0
TOTAL=7

if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    B=''; G=''; R=''; Y=''; C=''; N=''
else
    B=$'\033[1;34m'; G=$'\033[1;32m'; R=$'\033[1;31m'; Y=$'\033[1;33m'; C=$'\033[1;36m'; N=$'\033[0m'
fi

mkdir -p "$REPO_DIR/.work"
: > "$LOG"

say()  { printf '%s\n' "$*"; }
step() { STEP=$((STEP+1)); printf '\n%s[%d/%d]%s %s\n' "$C" "$STEP" "$TOTAL" "$N" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '    %s!%s %s\n' "$Y" "$N" "$*"; }
fail() { printf '\n%s安装失败：%s%s\n' "$R" "$*" "$N" >&2
         printf '  完整日志：%s\n' "$LOG" >&2
         printf '\n  ---- 日志末尾 ----\n' >&2
         tail -n 30 "$LOG" >&2 || true
         exit 1; }
run() { { "$@"; } >>"$LOG" 2>&1; }

trap 'fail "脚本在第 $STEP 步意外中止（退出码 $?）"' ERR

# ---------------------------------------------------------------------------
# 0. 必须是 root（用户自己 cd 到仓库后 sudo 运行）
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    say "需要 root 权限。请用以下任一方式运行："
    say "    sudo bash $REPO_DIR/install.sh"
    say "    su -c 'bash $REPO_DIR/install.sh'"
    exit 1
fi

printf '%s\n' "${B}============================================================${N}"
printf '%s\n' "${B}  CMP30HX on Linux — 一键安装${N}"
printf '%s\n' "${B}============================================================${N}"
say "  仓库目录 : $REPO_DIR"
say "  运行内核 : $(uname -r)"
say "  目标内核 : $KVER"
say "  日志文件 : $LOG"

# ---------------------------------------------------------------------------
step
# [1/7] 检测系统
# ---------------------------------------------------------------------------
say "检测系统环境"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) ok "架构 x86_64" ;;
    *) fail "仅支持 x86_64，当前是 $ARCH（30HX 的驱动只有 x86_64 版本）" ;;
esac

DISTRO_ID=""; DISTRO_VER=""; DISTRO_NAME="unknown"; PKG=""
if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID=${ID:-unknown}; DISTRO_VER=${VERSION_ID:-}; DISTRO_NAME=${PRETTY_NAME:-$DISTRO_ID}
    # 优先用 ID_LIKE 判断包管理器家族
    FAMILY="$DISTRO_ID ${ID_LIKE:-}"
else
    FAMILY="$DISTRO_ID"
fi
ok "发行版：$DISTRO_NAME"

for c in apt-get dnf yum pacman zypper apk; do
    command -v "$c" >/dev/null 2>&1 && { PKG=$c; break; }
done
case "$PKG" in
    apt-get) ok "包管理器：apt" ;;
    dnf|yum) ok "包管理器：$PKG" ;;
    pacman)  ok "包管理器：pacman" ;;
    zypper)  ok "包管理器：zypper" ;;
    apk)     ok "包管理器：apk" ;;
    *) warn "未识别到已知包管理器，将跳过依赖自动安装（可用 SKIP_DEPS=1 明确跳过）" ;;
esac

CMDLINE=$(cat /proc/cmdline 2>/dev/null || true)
if command -v mokutil >/dev/null 2>&1; then
    SB=$(mokutil --sb-state 2>/dev/null || true)
    case "$SB" in
        *"SecureBoot enabled"*)
            warn "Secure Boot 已开启：本驱动模块未签名，加载会被内核拒绝"
            info "两种解决办法："
            info "  1) 进 BIOS 关闭 Secure Boot（最简单）"
            info "  2) 给模块签名并 enroll MOK key（见 README 的 Secure Boot 一节）"
            if [ "${ALLOW_SECUREBOOT:-0}" != "1" ]; then
                fail "Secure Boot 开启时无法加载未签名模块。
  请先在 BIOS 里关闭 Secure Boot，或给模块签名后重试。
  确实要强行继续：ALLOW_SECUREBOOT=1 sudo ./install.sh"
            fi
            ;;
        *"SecureBoot disabled"*) ok "Secure Boot 已关闭（模块无需签名）" ;;
    esac
else
    ok "Secure Boot 状态未知（未安装 mokutil，通常无影响）"
fi

# ---------------------------------------------------------------------------
step
# [2/7] 安装构建依赖
# ---------------------------------------------------------------------------
say "检查构建依赖"

have_all_deps() {
    local missing=()
    for t in gcc make ld objcopy modinfo depmod patch tar gzip zstd xz; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [ ${#missing[@]} -eq 0 ] || { warn "缺少工具：${missing[*]}"; return 1; }
    return 0
}

install_deps() {
    case "$PKG" in
        apt-get)
            run apt-get update -qq || warn "apt-get update 失败，继续尝试安装"
            DEBIAN_FRONTEND=noninteractive run apt-get install -y -qq \
                build-essential dkms binutils kmod bc bison flex \
                libssl-dev libelf-dev ca-certificates curl git || return 1
            ;;
        dnf|yum)
            run "$PKG" install -y gcc make dkms binutils kmod bc bison flex \
                openssl-devel elfutils-libelf-devel ca-certificates curl git || return 1
            ;;
        pacman)
            run pacman -Sy --noconfirm gcc make dkms binutils kmod bc bison flex \
                openssl elfutils curl git || return 1
            ;;
        zypper)
            run zypper --non-interactive install -y gcc make dkms binutils kmod bc \
                bison flex libopenssl-devel libelf-devel curl git || return 1
            ;;
        apk)
            run apk add --no-cache gcc make dkms binutils kmod bc bison flex \
                openssl-dev elfutils-dev curl git || return 1
            ;;
        *) return 1 ;;
    esac
}

if have_all_deps; then
    ok "构建依赖齐全"
elif [ "$SKIP_DEPS" = "1" ]; then
    warn "SKIP_DEPS=1，跳过依赖安装（若缺工具后面会编译失败）"
else
    info "自动安装构建依赖（可能需要几分钟）"
    install_deps || fail "构建依赖安装失败，请手动安装 gcc make binutils kmod bc bison flex libssl-dev libelf-dev"
    have_all_deps || fail "依赖安装后仍缺少工具，请检查日志"
    ok "构建依赖安装完成"
fi

# pahole 只是锦上添花（模块 BTF），装在最后、失败不影响
if ! command -v pahole >/dev/null 2>&1 && [ "$SKIP_DEPS" != "1" ]; then
    case "$PKG" in
        apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pahole >/dev/null 2>&1 ;;
        dnf|yum) "$PKG" install -y dwarves >/dev/null 2>&1 ;;
        pacman) pacman -S --noconfirm --needed pahole >/dev/null 2>&1 ;;
        zypper) zypper --non-interactive install -y dwarves >/dev/null 2>&1 ;;
        apk) apk add --no-cache dwarves >/dev/null 2>&1 ;;
    esac
    command -v pahole >/dev/null 2>&1 && ok "pahole 已安装（模块将带 BTF）" || info "pahole 不可用，将跳过 BTF（不影响驱动加载）"
fi

# ---------------------------------------------------------------------------
step
# [3/7] 内核头文件
# ---------------------------------------------------------------------------
say "检查内核头文件（$KVER）"

headers_ok() {
    local h="/usr/src/linux-headers-$KVER"
    local c
    for c in "/usr/src/linux-headers-${KVER%-amd64}-common" "$h"; do
        [ -f "$c/Makefile" ] && [ -d "$c/include" ] && return 0
    done
    # 部分发行版只提供 /lib/modules/$KVER/build
    [ -f "/lib/modules/$KVER/build/Makefile" ] && return 0
    return 1
}

if headers_ok; then
    ok "头文件已安装"
else
    warn "缺少内核头文件，自动安装"
    case "$PKG" in
        apt-get)
            DEBIAN_FRONTEND=noninteractive run apt-get install -y "linux-headers-$KVER" ||
            DEBIAN_FRONTEND=noninteractive run apt-get install -y linux-headers-generic ||
            fail "无法安装 linux-headers-$KVER。
  Kali/Debian 的内核有版本限制：请先确认 apt 源里有对应版本：
      apt-cache policy linux-headers-$KVER
  如果源里没有，请安装同系列内核后重启：sudo apt install linux-image-amd64 linux-headers-amd64"
            ;;
        dnf|yum) run "$PKG" install -y "kernel-devel-$KVER" || run "$PKG" install -y kernel-devel ;;
        pacman) run pacman -S --noconfirm --needed "linux-headers" ;;
        zypper) run zypper --non-interactive install -y "kernel-default-devel" ;;
        apk) run apk add --no-cache "linux-headers" ;;
        *) fail "无法自动安装内核头文件，请手动安装后重试" ;;
    esac
    headers_ok || fail "内核头文件安装后仍不可用。
  请确认：ls /usr/src/linux-headers-$KVER/
  某些发行版需要先安装与内核匹配的 linux-headers 版本。"
    ok "内核头文件安装完成"
fi

if command -v gcc >/dev/null 2>&1; then
    KCC=$(sed -n 's/^CONFIG_CC_VERSION_TEXT="\([^"]*\)".*/\1/p' "/usr/src/linux-headers-${KVER%-amd64}-common/.config" 2>/dev/null \
          || sed -n 's/^CONFIG_CC_VERSION_TEXT="\([^"]*\)".*/\1/p' "/usr/src/linux-headers-$KVER/.config" 2>/dev/null)
    [ -n "${KCC:-}" ] && info "内核由以下编译器构建：$KCC" || true
fi

# ---------------------------------------------------------------------------
step
# [4/7] 已有驱动的检测（避免重复安装）
# ---------------------------------------------------------------------------
say "检查现有 NVIDIA 驱动"

TARGET_VER=615.78.08
if command -v lsmod >/dev/null 2>&1 && lsmod | grep -q '^nvidia '; then
    CUR=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
    GPUOK=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
    if [ -n "$CUR" ] && [ "$CUR" = "$TARGET_VER" ] && [ -n "$GPUOK" ]; then
        ok "当前已加载 NVIDIA 驱动 $CUR（$GPUOK），工作正常"
        nvidia-smi 2>/dev/null | head -14 || true
        if [ "$FORCE" != "1" ]; then
            say ""
            say "  驱动已经在运行，无需重复安装。"
            say "  要强制重装：FORCE=1 sudo ./install.sh"
            exit 0
        fi
        warn "FORCE=1，继续重装"
    elif [ -n "${CUR:-}" ]; then
        warn "已加载的驱动版本是 $CUR，不是目标版本 $TARGET_VER，将重新安装"
    else
        warn "nvidia 模块已加载但 nvidia-smi 无法通信，将重新安装"
    fi
fi

INSTALLED_USER=$(command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --version 2>/dev/null | sed -n 's/.*DRIVER\s*VERSION\s*:\s*\([0-9.]*\).*/\1/p' | head -1 || true)
if [ -n "${INSTALLED_USER:-}" ] && [ "$INSTALLED_USER" != "$TARGET_VER" ]; then
    warn "系统里有 NVIDIA 用户态驱动 $INSTALLED_USER，与 $TARGET_VER 不匹配，可能冲突"
    info "建议先 sudo apt purge 'nvidia-*'，或继续让安装器覆盖"
fi
ok "继续安装"

# ---------------------------------------------------------------------------
step
# [5/7] 获取官方驱动包
# ---------------------------------------------------------------------------
say "准备 NVIDIA 615.78.08 官方驱动包"

RUN_NAME="NVIDIA-Linux-x86_64-615.78.08.run"
RUN_URL="https://cn.download.nvidia.com/XFree86/Linux-x86_64/615.78.08/$RUN_NAME"
WORK=$REPO_DIR/.work
RUNFILE=""

for cand in "$REPO_DIR/$RUN_NAME" "$WORK/$RUN_NAME" "$HOME/$RUN_NAME" "/root/$RUN_NAME" \
            "$HOME/Downloads/$RUN_NAME" "$HOME/下载/$RUN_NAME" \
            "/home/${SUDO_USER:-root}/Downloads/$RUN_NAME" \
            /run/media/*/*/*/"$RUN_NAME" /run/media/*/"$RUN_NAME" /media/*/*/"$RUN_NAME"; do
    if [ -f "$cand" ] && [ "$(stat -c %s "$cand" 2>/dev/null || echo 0)" -gt 400000000 ]; then
        RUNFILE=$cand; break
    fi
done

if [ -n "$RUNFILE" ]; then
    ok "使用本地驱动包：$RUNFILE"
    if [ "$RUNFILE" != "$WORK/$RUN_NAME" ]; then
        mkdir -p "$WORK"
        info "复制到工作目录（避免 U 盘/FUSE 上执行安装器）"
        run cp -f "$RUNFILE" "$WORK/$RUN_NAME" || fail "复制驱动包失败（磁盘空间不足？）"
        RUNFILE=$WORK/$RUN_NAME
    fi
else
    info "未找到本地驱动包，开始下载（约 505 MB）"
    mkdir -p "$WORK"
    dl() {
        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 3 --connect-timeout 20 -o "$WORK/$RUN_NAME.part" "$1"
        else
            wget -q --tries=3 -O "$WORK/$RUN_NAME.part" "$1"
        fi
    }
    dl "$RUN_URL" || dl "https://us.download.nvidia.com/XFree86/Linux-x86_64/615.78.08/$RUN_NAME" ||
    dl "https://international.download.nvidia.com/XFree86/Linux-x86_64/615.78.08/$RUN_NAME" ||
    fail "驱动包下载失败。
  可手动下载后放到仓库目录再重跑：
      $RUN_URL
  离线机器：把 $RUN_NAME 放到 $(pwd)/ 下即可"
    mv -f "$WORK/$RUN_NAME.part" "$WORK/$RUN_NAME"
    RUNFILE=$WORK/$RUN_NAME
    ok "下载完成"
fi
chmod 755 "$RUNFILE"


# ---------------------------------------------------------------------------
step
# [6/7] 打补丁并编译
# ---------------------------------------------------------------------------
say "编译 CMP 30HX 内核模块"

[ -f "$REPO_DIR/build.sh" ] || fail "仓库不完整：缺少 build.sh（请确认在仓库根目录运行）"
[ -f "$REPO_DIR/patches/30hx-mod.patch" ] || fail "仓库不完整：缺少 patches/30hx-mod.patch"

if ! run env KVER="$KVER" JOBS="$JOBS" MODULES="${MODULES:-nvidia nvidia-modeset nvidia-drm nvidia-uvm}" \
        bash "$REPO_DIR/build.sh"; then
    # 带详细输出重跑一次，让用户直接看到错误
    env KVER="$KVER" JOBS="$JOBS" bash "$REPO_DIR/build.sh" || fail "内核模块编译失败，请把上面的报错提交到 GitHub Issues"
fi

DIST=$REPO_DIR/dist/$KVER
ls "$DIST"/*.ko >/dev/null 2>&1 || fail "编译完成但没有产出 .ko，请检查日志"
ok "编译完成：$(ls "$DIST"/*.ko | wc -l) 个模块"

# ---------------------------------------------------------------------------
step
# [7/7] 安装、屏蔽 nouveau、加载验证
# ---------------------------------------------------------------------------
say "安装并加载驱动"

if ! run env KVER="$KVER" bash "$REPO_DIR/build.sh" --install; then
    env KVER="$KVER" bash "$REPO_DIR/build.sh" --install || fail "安装失败"
fi

# 判断是否需要重启
if lsmod | grep -q '^nouveau'; then
    NEED_REBOOT=1
elif [ "$KVER" != "$(uname -r)" ]; then
    NEED_REBOOT=1
elif ! lsmod | grep -q '^nvidia '; then
    NEED_REBOOT=1
fi

# ---------------------------------------------------------------------------
# 结果
# ---------------------------------------------------------------------------
say ""
if [ "$NEED_REBOOT" -eq 1 ]; then
    printf '%s============================================================%s\n' "$Y" "$N"
    printf '%s  安装完成，但需要重启一次%s\n' "$Y" "$N"
    printf '%s============================================================%s\n' "$Y" "$N"
    say ""
    if lsmod | grep -q '^nouveau'; then
        say "  原因：nouveau（开源驱动）在开机早期就占用了显卡，屏蔽规则要重启才生效。"
    else
        say "  原因：目标内核 $KVER 与当前运行内核 $(uname -r) 不同，或模块尚未自动加载。"
    fi
    say ""
    say "  重启后执行以下命令即可使用："
    say "      sudo modprobe nvidia && sudo modprobe nvidia-uvm && nvidia-smi"
    say ""
    if [ "$REBOOT" = "1" ]; then
        say "  REBOOT=1，5 秒后自动重启..."
        sleep 5
        reboot
    else
        say "  现在重启：sudo reboot"
        say "  自定义重启命令已设置：REBOOT=1 sudo ./install.sh 会自动重启"
    fi
else
    printf '%s============================================================%s\n' "$G" "$N"
    printf '%s  安装成功，驱动已加载%s\n' "$G" "$N"
    printf '%s============================================================%s\n' "$G" "$N"
    say ""
    nvidia-smi 2>/dev/null || warn "nvidia-smi 执行异常，请查看：dmesg | grep -i nvrm"
    say ""
    say "  PCIe 链路："
    nvidia-smi -q 2>/dev/null | sed -n '/PCIe Generation/,/Link Width/,+4p' | sed 's/^/    /' || true
fi

cat <<EOF

----------------------------------------------------------------------------
  常用命令
    nvidia-smi                              查看 GPU 状态
    nvidia-smi -q                           详细信息
    nvidia-smi --query-gpu=temperature.gpu,power.draw --format=csv
    nvidia-smi -q | grep -iE 'Encoder|Decoder'    编解码能力

  维护
    重新安装      : FORCE=1 sudo ./install.sh
    内核升级之后  : sudo ./install.sh
    卸载          : sudo ./uninstall.sh
    完整日志      : $LOG
----------------------------------------------------------------------------
EOF
