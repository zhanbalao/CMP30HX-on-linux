# CMP30HX on Linux

让 NVIDIA **CMP 30HX**（`10de:2189`，Turing TU116 矿卡）在 Linux 上正常工作的驱动构建方案：从官方 NVIDIA 615.78.08 开源内核模块出发，打上魔改补丁，用一条命令编译并安装。

> **状态**：已在 Kali Linux 2026.3 / 内核 `7.2.15+kali-amd64` / GCC 16.2.0 上完整验证 —— 驱动加载成功，`nvidia-smi` 正常识别，CUDA、NVENC/NVDEC 可用。

---

## 目录

- [背景：CMP 30HX 在 Linux 上到底差什么](#背景cmp-30hx-在-linux-上到底差什么)
- [魔改内容](#魔改内容)
- [硬件实测结果](#硬件实测结果)
- [快速开始](#快速开始)
- [构建脚本说明](#构建脚本说明)
- [验证](#验证)
- [已知限制](#已知限制)
- [PCIe 速度说明](#pcie-速度说明)
- [排错](#排错)
- [许可](#许可)

---

## 背景：CMP 30HX 在 Linux 上到底差什么

先澄清一个常见误解：**NVIDIA 官方 Linux 驱动是支持 CMP 30HX 的**。

- [官方 supported-gpus 列表](https://download.nvidia.com/XFree86/Linux-x86_64/615.78.08/supported-gpus/supported-gpus.json)里明确有 `NVIDIA CMP 30HX  0x2189`。
- 内核侧 `nv_pci_table` 按 **PCI class `0x0302`（3D controller）+ vendor `10de`** 匹配，没有针对单独 device ID 的黑名单。

所以这张卡**不需要"加 ID 破解"**。真正需要魔改的是两件事：

1. **绑定条件过严**：官方要求 class 寄存器低字节（programming interface）必须为 `0x00`。30HX 上报的正是 `0x0302`，理论上能匹配；但只要 VBIOS 在哪一版里把低字节填了别的值，就会静默绑定失败——而 30HX 正是那种 VBIOS 版本五花八门的矿卡。
2. **在 Kali/Debian 内核上编不出来**：官方 `.run` 的内核模块构建脚本对 gen-btf / conftest / pahole 有假设，在 7.x 内核 + 现代 GCC 上会失败（详见下文）。

本项目的魔改就是针对这两点。

---

## 魔改内容

驱动侧改动全部在 [`patches/30hx-mod.patch`](patches/30hx-mod.patch)，每一处都带 `[30HX-mod]` 注释：

### A. 绑定放宽（针对 30HX 的硬件特性）

| 文件 | 改动 | 说明 |
|---|---|---|
| `kernel-open/nvidia/nv-pci-table.c` | `class_mask` `~0` → `0xff0000`（3D controller 项，两处表） | 只比较 class 寄存器高 16 位（base class + subclass），不再要求 low byte 恰好为 0x00。已用 `objdump` 确认编进 `.ko` 的 `pci_device_id` mask 是 `0x00ff0000` |
| `kernel-open/nvidia-drm/nv-pci-table.c` | 同上（两处） | DRM 侧 |

### B. 构建兼容性（否则编不出来）

| 文件 | 改动 | 为什么必须 |
|---|---|---|
| `kernel-open/Kbuild` | conftest 用 `NV_VERSION_STRING=615_78_08` | `conftest.sh` 用单引号包裹 CFLAGS 传给 gcc，官方写的 `\"615.78.08\"` 会变成字面反斜杠，导致**全部 256 个 conftest 失败**，驱动按最老代码路径编译，报 `mmap_sem` 不存在。换成不带点的字符串后测试全部真正执行 |
| `kernel-open/Kbuild` | x86_64 增加 `-mharden-sls=all`、`-mindirect-branch=thunk-extern`、`-mindirect-branch-register`、`-fno-jump-tables` | 对齐 Kali 内核的 `CONFIG_SLS`/`CONFIG_RETHUNK`/IBT 策略，objtool 不再报 return-thunk 硬错误 |
| `kernel-open/Makefile` | 递归 make 传 `AWK=$(AWK)`，透传 `PAHOLE_FLAGS` | 新版 kbuild 里 `$(AWK)` 展开成裸 `awk`，导致 `*.mod` 为空、**不产出 `.ko`** |

### C. 构建环境适配（脚本自动处理，不改驱动）

- **头文件树组装**：Debian/Kali 把 kernel headers 拆成 arch 包（生成头文件、`.config`、`Module.symvers`、`arch/x86/module.lds`）和 common 包（`include/`、`scripts/`），kbuild 需要 `srctree == objtree` 的一棵树，脚本会把两者拼好。
- **kbuild 二次调用**：kbuild 会在模块目录里执行 `make -f <common/Makefile>`，此时 `$(src)` 指向空目录、`NV_KERNEL_MODULES` 丢失。脚本临时换入一个 shim Makefile 重放原始命令行，结束后恢复原文件。
- **pahole 缺失**：内核 7.x 的 `scripts/gen-btf.sh` 在没有 pahole 时直接失败。脚本给暂存树里的副本打补丁，缺 pahole 时打印 `Skipping BTF generation` 并继续（模块 BTF 只影响 bpftool 类型信息）。
- **gcc 自带 include 缺失**：打包的头文件不含编译器 include 目录，脚本用 `KCPPFLAGS="-idirafter $(gcc -print-file-name=include)"` 补上，否则找不到 `stdarg.h`。

---

## 硬件实测结果

在 CMP 30HX（`2189-100-A1` / TU116，VBIOS `90.16.58.00.01`）上的实测：

```
Product Name        : NVIDIA CMP 30HX
Product Architecture: Turing
FB Memory Total     : 6144 MiB
Power Limit         : 125 W (min 70W / max 125W)
GSP Firmware        : 615.78.08
Encoder / Decoder   : 可用（0% 占用，未被屏蔽）
```

| 项目 | 结果 | 解读 |
|---|---|---|
| 驱动加载 | ✅ `nvidia-smi` 正常，温度 43°C / 空载 32W | — |
| CUDA | ✅ CUDA UMD 13.4 | 推理/训练可用 |
| NVENC / NVDEC | ✅ 都在 | 可以转码 |
| PCIe 宽度 | x16（满宽） | 电气通道完好 |
| PCIe 速率 | **Gen1 ×16（2.5 GT/s）** | 见[下文](#pcie-速度说明) |

---

## 一键安装

**新手请直接看 [TUTORIAL.md](TUTORIAL.md)（带步骤截图式说明的完整安装教程）。**

```bash
git clone https://github.com/YOUR_GITHUB_USER/CMP30HX-on-linux.git
cd CMP30HX-on-linux

# 可选：把官方驱动包放到仓库根目录，安装时就不联网下载（推荐）
#   cp ~/下载/NVIDIA-Linux-x86_64-615.78.08.run .

sudo ./install.sh
```

`install.sh` 优先使用**仓库根目录**里的 `NVIDIA-Linux-x86_64-615.78.08.run`：

- 放好了 → 直接离线使用，不联网；
- 没放 → 依次尝试本仓库 Release 附件、NVIDIA 官方源（国内 CDN → 美国 → 国际）。

驱动包会被校验（大小需约 505 MB、必须是自解压脚本），不合格会明确报错而不是静默跳过。

脚本会自己检测并完成全部工作：

1. 识别发行版 / 包管理器 / 架构 / 内核，检查 Secure Boot
2. 安装缺失的构建依赖（apt / dnf / pacman / zypper / apk）
3. 安装匹配当前内核的头文件
4. 取用本地已有的 `.run`，没有才下载（离线可用）
5. 打 CMP 30HX 补丁、编译 4 个内核模块
6. 安装用户态库 + 内核模块，屏蔽 nouveau（initramfs + grub）
7. 能加载就立即验证 `nvidia-smi`，需要重启则明确列出重启后的命令

首次安装后如果提示需要重启（nouveau 在启动早期就加载了），重启一次即可：

```bash
sudo reboot
sudo modprobe nvidia && sudo modprobe nvidia-uvm && nvidia-smi
```

常用开关：`FORCE=1` 强制重装、`KVER=<版本>` 指定内核、`SKIP_DEPS=1` 跳过依赖安装、
`REBOOT=1` 需要时自动重启、`NO_COLOR=1` 关闭颜色。卸载用 `sudo ./uninstall.sh`。

## 从源码构建（进阶，不需要 root）

### 依赖

```bash
sudo apt-get install -y \
    build-essential linux-headers-$(uname -r) dkms \
    binutils kmod bc bison flex libssl-dev libelf-dev
# 可选（让模块带上 BTF，便于 bpftool）：
sudo apt-get install -y pahole
```

### 编译（不需要 root）

```bash
./build.sh
```

脚本会：下载官方 `NVIDIA-Linux-x86_64-615.78.08.run`（约 505 MB）→ 解压内核模块源码 → 打补丁 → 组装头文件树 → 编译，产物在 `dist/<内核版本>/`：

```
dist/7.2.15+kali-amd64/nvidia.ko
dist/7.2.15+kali-amd64/nvidia-modeset.ko
dist/7.2.15+kali-amd64/nvidia-drm.ko
dist/7.2.15+kali-amd64/nvidia-uvm.ko
```

如果 `.run` 已经在本目录或 `$HOME`，脚本会直接用它，不联网下载。

### 安装（需要 root）

```bash
sudo ./build.sh --install
```

会依次：装用户态库（官方 `.run`，`--no-kernel-modules`）→ 装内核模块到 `/lib/modules/$(uname -r)/updates/dkms/` → `depmod` → 屏蔽 nouveau（含 initramfs 与 GRUB 参数）→ 加载模块 → 跑 `nvidia-smi`。

> **首次安装需要重启一次**：nouveau 可能在 initramfs 阶段就被加载了。安装脚本会写入 `nouveau.modeset=0 rd.driver.blacklist=nouveau` 与 `/etc/modprobe.d/` 黑名单，重启后才会生效。重启后执行：
>
> ```bash
> sudo modprobe nvidia && sudo modprobe nvidia-uvm && nvidia-smi
> ```

### 指定其他内核版本

```bash
KVER=7.3.0+kali-amd64 ./build.sh          # 编译
sudo KVER=7.3.0+kali-amd64 ./build.sh --install
```

### 常用环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `KVER` | `$(uname -r)` | 目标内核版本 |
| `JOBS` | `nproc` | 并行编译数 |
| `MODULES` | `nvidia nvidia-modeset nvidia-drm nvidia-uvm` | 要编译的模块 |
| `WORK` | `./.work` | 解压与暂存目录 |
| `PATCH` | `patches/30hx-mod.patch` | 补丁路径（设为 `/dev/null` 可编译原版） |
| `HEADERS` / `COMMON` | `/usr/src/linux-headers-$KVER` 及对应 common | 自定义头文件位置 |

---

## 构建脚本说明

[`build.sh`](build.sh) 的流程：

```
[0] 检查架构/工具链/头文件
[1] 下载或复用官方 .run          →  .work/NVIDIA-Linux-x86_64-615.78.08.run
[2] 解压 + 打补丁                →  .work/nvidia/kernel-open/
[3] 组装自包含头文件树           →  .work/khs/usr/src/linux-headers-*/
[4] kbuild 编译（带 shim）       →  dist/<KVER>/*.ko
[5] 可选安装（--install）
```

第 4 步的 shim 机制解释：kbuild 在模块目录里重新执行 `make -f <common Makefile>`，这时它既找不到 `<模块>/<模块>.Kbuild`（因为 `$(src)` 指向头文件树），`NV_KERNEL_MODULES` 这个在第一次 make 里计算出来的变量也丢了。脚本的做法是临时把 `kernel-open/Makefile` 换成一个小 shim，由它重放原始编译命令行（此时 `$(src)` 正确），编译结束用 `trap` 恢复原文件。

---

## 验证

```bash
# 基本
nvidia-smi

# 驱动占位
lspci -k -s 01:00.0 | grep 'Kernel driver'      # 应为 nvidia

# 编解码能力
nvidia-smi -q | sed -n '/Encoder Stats/,/^$/p'

# PCIe 链路
nvidia-smi -q | sed -n '/PCIe Generation/,/Link Width/,+4p'
```

构建产物自检：

```bash
modinfo -F vermagic dist/*/nvidia.ko              # 应与目标内核一致
objdump -d dist/*/nvidia.ko | grep -c endbr64     # IBT 生效，应 > 0
modinfo -F alias dist/*/nvidia.ko | grep bc03sc   # 3D controller 绑定
```

---

## 已知限制

- **仅 x86_64**，仅针对 NVIDIA 615.78.08 系列（open kernel modules）。
- 30HX 是**无显示输出**的矿卡：`nvidia-drm`/`nvidia-modeset` 可以编、可以装，但不会出画面，桌面需要由核显（如 Intel i915）输出。CUDA 与 NVIDIA 硬件编解码走 `nvidia.ko` + `nvidia-uvm.ko`。
- **没有 Modules BTF**（除非装了 `pahole`），只影响 `bpftool` 类型信息，不影响加载。
- 内核升级后 `vermagic` 不匹配，需要重新跑 `./build.sh`。
- 不支持 `nvidia-peermem`（需要 RDMA 头文件，30HX 用不到）。
- 未签名模块会让内核标记 `tainting kernel`，在没有启用 Secure Boot 的系统上正常；**启用 Secure Boot 时需要自行签名**。

---

## PCIe 速度说明

很多 30HX 用户关心"能不能把 PCIe 解锁到 Gen2/Gen3"。实测结论：

```
PCIe Generation
    Device Max : 1     ← 显卡自己上报的最大能力只有 Gen1
    Host Max   : 3     ← 主板（根桥）支持 Gen3
    Current    : 1
Link Width
    Max/Current: 16x / 16x
```

**`Device Max = 1` 是 VBIOS 写死的链路能力**，系统、内核、驱动都没有软件开关能改它——链路速率由两端"最大能力"取小值协商，显卡自报 Gen1，就只能跑 Gen1。

想提升只能走硬件路线：

1. **刷改过的 VBIOS**：社区有把 30HX 恢复到 Gen2/Gen3 的项目（如 `ngthaihoc/CMP30HXmodtoGEN2`），实测带宽可到 6.3–6.4 GB/s。风险是需要核显做救砖备份。
2. **补焊 PCIe 耦合电容**：恢复信号完整性。

**建议先评估收益**：Gen1 x16 双向约 4 GB/s，日常 CUDA 推理、转码、小模型训练基本跑不满；只有大模型加载、多卡 P2P、大规模 host-device 拷贝才会明显受限于它。

---

## 排错

**`modprobe: ERROR: could not insert 'nvidia': No such device`**

- 最常见：nouveau 仍占着显卡。检查 `lspci -k -s 01:00.0 | grep 'Kernel driver'`。
- 确认黑名单生效：`lsmod | grep nouveau` 应无输出；若仍有，检查 `/etc/modprobe.d/*.conf`、initramfs 和内核命令行（`cat /proc/cmdline` 应有 `nouveau.modeset=0`），必要时重启。
- 其他原因看 `dmesg | grep -i nvrm | tail -40`。

**`NVRM: RmInitAdapter failed`**

GSP 固件缺失。检查 `/lib/firmware/nvidia/615.78.08/` 下是否有 `gsp_tu10x.bin` 等文件（由用户态安装步骤安装）。

**`nvidia-smi` 报 "couldn't communicate with the NVIDIA driver"**

模块没加载成功，先看 `lsmod | grep nvidia` 与上面那条 dmesg。

**构建时 pahole 报错**

装 `pahole`，或用不带 BTF 的构建（脚本默认会在缺 pahole 时跳过 BTF）。

**`Module.symvers is missing`**

头文件包不完整，确认 `linux-headers-$(uname -r)` 已安装。

---

## 目录结构

```
.
├── build.sh                  # 唯一的构建/安装入口
├── patches/
│   └── 30hx-mod.patch        # 驱动侧全部魔改
├── licenses/
│   └── NVIDIA-615.78.08-LICENSE.txt
└── dist/<kernel>/            # 构建产物（不入库）
```

---

## 许可

- 本项目自己的脚本与补丁：MIT。
- 内核模块源码与用户态库来自 NVIDIA 官方发布包，适用 **NVIDIA 的专有许可**（见 `licenses/`）。本项目**不重新分发** NVIDIA 二进制文件，构建时自行从官方下载。
- `nvidia-drm` 与部分内核模块代码遵循 MIT，见官方包内 `LICENSE`。
