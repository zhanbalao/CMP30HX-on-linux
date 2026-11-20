#!/bin/bash
# ============================================================================
#  CMP30HX on Linux — build + install
#
#  One script: extracts the NVIDIA 615.78.08 open kernel modules source from
#  the official .run file, applies the CMP 30HX patches, builds the kernel
#  modules for the running kernel and (with --install) installs them together
#  with the userspace library.
#
#  Usage:
#      ./build.sh                 # build only, no root needed
#      sudo ./build.sh --install  # build + install for the running kernel
#      KVER=7.2.15+kali-amd64 ./build.sh          # build for another kernel
#      JOBS=4 MODULES="nvidia nvidia-uvm" ./build.sh
#
#  Requires (build):  make gcc bc bison flex kmod binutils gzip zstd xz
#                     apt-get install -y \
#                       build-essential linux-headers-$(uname -r) dkms \
#                       binutils kmod bc bison flex libssl-dev libelf-dev
#
#  The script never touches /usr unless --install is given.
# ============================================================================
set -euo pipefail

VERSION="615.78.08"
REPO_DIR=$(cd "$(dirname "$0")" && pwd)
RUN_NAME="NVIDIA-Linux-x86_64-${VERSION}.run"
RUN_URL="https://cn.download.nvidia.com/XFree86/Linux-x86_64/${VERSION}/${RUN_NAME}"
WORK=${WORK:-$REPO_DIR/.work}
SRC=$WORK/nvidia
PATCH=${PATCH:-$REPO_DIR/patches/30hx-mod.patch}
KVER=${KVER:-$(uname -r)}
JOBS=${JOBS:-$(nproc)}
MODULES=${MODULES:-"nvidia nvidia-modeset nvidia-drm nvidia-uvm"}

# Kernel headers: Debian/Kali install them into /usr/src as two packages
# (arch + common).  The build must be driven from the *common* tree because
# that is where include/ and scripts/ live; the arch tree only adds generated
# headers and Module.symvers.
HEADERS=${HEADERS:-/usr/src/linux-headers-$KVER}
if [ -z "${COMMON:-}" ]; then
    for cand in "/usr/src/linux-headers-$(echo "$KVER" | sed 's/-amd64$/-common/')" \
                "$HEADERS" ; do
        [ -f "$cand/Makefile" ] && { COMMON=$cand; break; }
    done
fi

DO_INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) DO_INSTALL=1 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "--install needs root: sudo $0 --install"; }

# ---------------------------------------------------------------------------
# 0. sanity checks
# ---------------------------------------------------------------------------
log "host: $(uname -s) $(uname -r) ($(uname -m)), target kernel: $KVER"
[ "$(uname -m)" = "x86_64" ] || die "this driver only supports x86_64"
[ -f "$HEADERS/.config" ] || die "kernel headers not found: $HEADERS
  install them first:  apt-get install -y linux-headers-$KVER"
[ -n "${COMMON:-}" ] && [ -f "$COMMON/Makefile" ] || die "kernel common headers not found
  install them first:  apt-get install -y linux-headers-$KVER
  or set COMMON=/path/to/linux-headers-<ver>-common"
gcc --version >/dev/null || die "gcc not found"
command -v ld >/dev/null && command -v objcopy >/dev/null || die "binutils missing"

# ---------------------------------------------------------------------------
# 1. official driver tarball
# ---------------------------------------------------------------------------
mkdir -p "$WORK"
if [ ! -f "$WORK/$RUN_NAME" ]; then
    if [ -f "$REPO_DIR/$RUN_NAME" ]; then
        log "using local $RUN_NAME"
        cp -f "$REPO_DIR/$RUN_NAME" "$WORK/$RUN_NAME"
    else
        log "downloading $RUN_NAME"
        curl -fL --retry 3 -o "$WORK/$RUN_NAME.part" "$RUN_URL"
        mv -f "$WORK/$RUN_NAME.part" "$WORK/$RUN_NAME"
    fi
fi
chmod 755 "$WORK/$RUN_NAME"

# ---------------------------------------------------------------------------
# 2. extract + patch the open kernel modules
# ---------------------------------------------------------------------------
if [ ! -d "$SRC/kernel-open" ]; then
    log "extracting $RUN_NAME"
    rm -rf "$WORK/extract"
    ( cd "$WORK" && sh "./$RUN_NAME" --extract-only --target "$WORK/extract" >/dev/null 2>&1 ) ||
        die "extraction failed: the .run file is corrupt"
    mv "$WORK/extract" "$SRC"
fi

if ! grep -q '\[30HX-mod\]' "$SRC/kernel-open/Kbuild" 2>/dev/null; then
    log "applying $(basename "$PATCH")"
    ( cd "$SRC/kernel-open" && patch -p1 --forward < "$PATCH" ) || die "patch failed"
fi

# ---------------------------------------------------------------------------
# 3. prepare a self-contained headers tree
#
# Debian/Kali split the kernel headers into an arch package (generated
# headers, .config, Module.symvers, arch/x86/module.lds) and a common package
# (include/, scripts/, arch headers).  kbuild needs one tree where srctree ==
# objtree, so both are staged side by side under .work/khs.
# ---------------------------------------------------------------------------
KHS=$WORK/khs
A=$KHS/usr/src/$(basename "$HEADERS")
C=$KHS/usr/src/$(basename "$COMMON")
if [ ! -d "$KHS/usr/src" ]; then
    log "staging kernel headers in $KHS"
    mkdir -p "$KHS/usr/src" "$KHS/usr/lib"
    # arch package (generated headers, .config, Module.symvers, module.lds)
    cp -a "$HEADERS" "$KHS/usr/src/"
    # common package (include/, scripts/, arch headers)
    if [ "$(basename "$COMMON")" != "$(basename "$HEADERS")" ]; then
        cp -a "$COMMON" "$KHS/usr/src/"
    fi
    # kbuild scripts: the arch tree links scripts -> /usr/lib/linux-kbuild-<ver>
    for kb in /usr/lib/linux-kbuild-*; do
        [ -d "$kb" ] && cp -a "$kb" "$KHS/usr/lib/"
    done
    [ -f "$C/Makefile" ] || C=$(ls -d "$KHS"/usr/src/*common* 2>/dev/null | head -1)
    [ -d "$C/scripts" ] || { KB=$(ls -d "$KHS"/usr/lib/linux-kbuild-*/scripts | head -1); [ -n "$KB" ] && cp -a "$KB" "$C/scripts"; }
    # the arch Makefile includes the common one through an absolute path
    sed -i "s#^include /usr/src/.*linux-headers-.*-common/Makefile#include $C/Makefile#" "$A/Makefile"
    # generated headers / config / symvers live in the arch tree
    mkdir -p "$C/include" "$C/arch/x86"
    [ -e "$C/include/config" ]     || ln -s "$A/include/config" "$C/include/config"
    [ -e "$C/include/generated" ]  || ln -s "$A/include/generated" "$C/include/generated"
    [ -e "$C/Module.symvers" ]     || cp -f "$A/Module.symvers" "$C/Module.symvers"
    cp -an "$A/arch/x86/include/generated/." "$C/arch/x86/include/generated/" 2>/dev/null || true
    [ -e "$C/arch/x86/module.lds" ] || cp -f "$A/arch/x86/module.lds" "$C/arch/x86/"
fi
COMMON=$C
[ -f "$COMMON/Makefile" ] || die "header staging failed, see $KHS"

# module BTF is optional and gen-btf.sh aborts when pahole is missing; the
# staged tree is ours, so patch the copy instead of /usr/src.
GEN_BTF=$COMMON/scripts/gen-btf.sh
if [ -f "$GEN_BTF" ] && ! command -v pahole >/dev/null 2>&1 && ! grep -q '\[30HX-mod\]' "$GEN_BTF"; then
    log "patching staged gen-btf.sh (skip BTF when pahole is missing)"
    python3 - "$GEN_BTF" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
needle = 'ELF_FILE="$1"\nshift\n'
if needle in s:
    s = s.replace(needle, needle + """
# [30HX-mod] pahole may be missing on the build host; module BTF is optional
# (bpftool/BPF type info only), so skip it instead of failing the build.
if ! command -v "${PAHOLE:-pahole}" >/dev/null 2>&1; then
	echo "Skipping BTF generation for ${ELF_FILE} (pahole not installed)" >&2
	exit 0
fi
""", 1)
    open(p, 'w').write(s)
PY
fi

# ---------------------------------------------------------------------------
# 4. build
#
# kbuild re-invokes "the last -f Makefile" inside the module directory and
# locates the per-module Kbuild fragment from $(src).  With a distro headers
# tree $(src) is empty, so a thin shim Makefile is swapped in for the build;
# it replays the original build command line and the original Makefile is
# restored on exit.  KCPPFLAGS points at the compiler's own include directory,
# which the packaged headers do not reference.
# ---------------------------------------------------------------------------
log "building: $MODULES"
SYSINC=$(gcc -print-file-name=include)
MODDIR=$SRC/kernel-open
SHIM=$WORK/placeholder.mk
# The shim is generated with values substituted in, so every make variable
# (including its own $(...)) is written out literally.
{
    echo '# [30HX-mod] temporary kbuild entry shim, generated by build.sh'
    echo "SRC_DIR := $MODDIR"
    echo "BUILD_RUN_DIR := $MODDIR"
    echo 'ORIG_M := $(filter-out M=%,$(MAKECMDGOALS))'
    echo '$(if $(ORIG_M),,$(eval ORIG_M := modules))'
    echo '.PHONY: __30hx_go'
    echo '__30hx_go:'
    echo '\t@$(MAKE) -C $(SRC_DIR) -f $(SRC_DIR)/Makefile.nvidia $(ORIG_M)'
    echo 'ifneq ($(MAKECMDGOALS),)'
    echo '$(MAKECMDGOALS): __30hx_go ;'
    echo 'else'
    echo '.NOTPARALLEL:'
    echo '__30hx_default: __30hx_go'
    echo 'default: __30hx_default ;'
    echo 'endif'
} > "$SHIM"

# keep the untouched Makefile around: the build shim must never re-enter
# itself, and the original is what $(src)/Makefile includes normally.
cp -f "$MODDIR/Makefile" "$MODDIR/Makefile.nvidia"
cp -f "$SHIM" "$MODDIR/Makefile"
trap 'cp -f "$MODDIR/Makefile.nvidia" "$MODDIR/Makefile"' EXIT

make -j"$JOBS" -C "$COMMON" -f "$COMMON/Makefile" \
     M="$MODDIR" NV_KERNEL_MODULES="$MODULES" \
     "NV_KERNEL_SOURCES=$COMMON" "NV_KERNEL_OUTPUT=$COMMON" \
     KCPPFLAGS="-idirafter $SYSINC"

trap - EXIT
cp -f "$MODDIR/Makefile.nvidia" "$MODDIR/Makefile"
rm -f "$MODDIR/Makefile.nvidia"

OUT=$REPO_DIR/dist/$KVER
mkdir -p "$OUT"
for m in $MODULES; do
    [ -f "$MODDIR/$m.ko" ] || die "expected $m.ko, but it was not produced"
    cp -f "$MODDIR/$m.ko" "$OUT/"
    printf '  %-22s %8.1f MiB  vermagic=%s\n' "$m.ko" \
        "$(awk -v s="$(stat -c %s "$MODDIR/$m.ko")" 'BEGIN{printf "%.1f", s/1048576}')" \
        "$(modinfo -F vermagic "$MODDIR/$m.ko" | awk '{print $1}')"
done
log "modules in $OUT"

# ---------------------------------------------------------------------------
# 5. install (root only)
# ---------------------------------------------------------------------------
if [ "$DO_INSTALL" -eq 1 ]; then
    MODDIR_INST=/lib/modules/$KVER/updates/dkms

    log "installing userspace libraries from the official .run"
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        sh "$WORK/$RUN_NAME" --silent --no-kernel-modules --no-nouveau-check \
            --no-x-check --no-cc-version-check --install-libglvnd
    else
        echo "  nvidia-smi present, userspace already installed"
    fi

    log "installing kernel modules -> $MODDIR_INST"
    mkdir -p "$MODDIR_INST"
    for m in $MODULES; do
        install -m 0644 "$OUT/$m.ko" "$MODDIR_INST/$m.ko"
    done
    depmod -a "$KVER"

    # nouveau must never claim the GPU again (initramfs included).
    cat > /etc/modprobe.d/nvidia-cmp30hx.conf <<'CONF'
# [30HX-mod] never let nouveau take the NVIDIA GPU
blacklist nouveau
install nouveau /bin/false
options nouveau modeset=0
CONF
    if [ "${SKIP_BOOT_FIX:-0}" = "1" ]; then
        log "SKIP_BOOT_FIX=1: 跳过 initramfs 与 grub 修改"
    elif [ -d /etc/initramfs-tools ]; then update-initramfs -u -k "$KVER" >/dev/null 2>&1 || true; fi
    if [ "${SKIP_BOOT_FIX:-0}" != "1" ] && [ -f /etc/default/grub ] && ! grep -q 'nouveau.modeset=0' /etc/default/grub; then
        cp -f /etc/default/grub /etc/default/grub.bak.cmp30hx
        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT="' /etc/default/grub; then
            sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nouveau.modeset=0 rd.driver.blacklist=nouveau"/' /etc/default/grub
        else
            echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nouveau.modeset=0 rd.driver.blacklist=nouveau"' >> /etc/default/grub
        fi
        command -v update-grub >/dev/null && update-grub >/dev/null
        echo "  kernel command line updated: reboot before loading the driver"
    fi

    if [ "$KVER" != "$(uname -r)" ]; then
        log "modules installed for $KVER; reboot into it, then run:"
        echo "    sudo modprobe nvidia && sudo modprobe nvidia-uvm && nvidia-smi"
        exit 0
    fi

    lsmod | grep -q '^nouveau' && die "nouveau is still loaded; reboot once and re-run the install"
    modprobe nvidia
    modprobe nvidia-uvm || true
    log "nvidia-smi:"
    nvidia-smi || die "nvidia-smi failed; check: dmesg | grep -i nvrm"
fi

cat <<'DONE'

--------------------------------------------------------------------------
Done.
  modules   : dist/<kernel-release>/*.ko
  verify    : nvidia-smi
  PCIe info : nvidia-smi -q | sed -n '/PCIe Generation/,/Link Width/,+4p'
  re-build  : ./build.sh          (drop .work/ to re-extract from scratch)
--------------------------------------------------------------------------
DONE
