# CMP30HX on Linux

**基于 [NVIDIA-patcher](https://github.com/dartraiden/NVIDIA-patcher) 项目的思路，为 CMP 30HX 矿卡做的 Linux 内核模块魔改 + 一键安装脚本。**

把官方的 `NVIDIA-Linux-x86_64-615.78.08.run` 丢进仓库根目录，用 root `cd` 进去跑一个脚本，剩下的它全包了：检测环境、装依赖、打补丁、编译、安装、加载、验证。

---

## 快速开始

```bash
# 1. 克隆仓库
git clone https://github.com/zhanbalao/CMP30HX-on-linux.git
cd CMP30HX-on-linux

# 2. 把官方驱动包放进仓库根目录（离线安装，不联网）
cp ~/下载/NVIDIA-Linux-x86_64-615.78.08.run .

# 3. 切到 root，进仓库目录，运行脚本
sudo -i
cd /home/你的用户名/CMP30HX-on-linux
./install.sh
```

就这三步。脚本跑完会直接打印 `nvidia-smi` 的结果；如果提示要重启，重启后再执行一次 `./install.sh` 即可。

> 驱动包从 [NVIDIA 官网](https://www.nvidia.com/en-us/drivers/) 下载，文件名必须是 `NVIDIA-Linux-x86_64-615.78.08.run`。
> 不放进去也行，脚本会自己下载（约 505 MB）。

---

## 脚本会自己做什么

以 root 在仓库目录运行后，`install.sh` 依次完成：

| 步骤 | 内容 |
|---|---|
| 1/7 | 检测发行版、包管理器、架构、**Secure Boot 状态** |
| 2/7 | 检测并安装缺失的构建依赖（apt / dnf / yum / pacman / zypper / apk 自动选包名） |
| 3/7 | 检测并安装与当前内核匹配的**内核头文件** |
| 4/7 | 检查是否已装过驱动（已装且正常就直接退出，不折腾） |
| 5/7 | 使用仓库根目录的 `.run`（校验 505 MB + 自解压脚本头），没有才下载 |
| 6/7 | 解压 → 应用魔改补丁 → 组装头文件树 → 编译 4 个内核模块 |
| 7/7 | 安装用户态库 + 内核模块，屏蔽 nouveau（modprobe + initramfs + grub），`depmod` 并加载验证 |

出错时会打印日志末尾 30 行，完整日志在 `.work/install.log`。

---

## 魔改了什么

### 与 NVIDIA-patcher 的关系

[NVIDIA-patcher](https://github.com/dartraiden/NVIDIA-patcher)（dartraiden 的项目）用**二进制字节补丁**的方式，把改过的 `nv-kernel.o_binary` 替换进官方驱动，给矿卡加 3D 加速支持。它是 **Windows** 方案（Linux 部分也是打二进制）。

本项目在 **Linux 内核模块源码层面**做同样的目标，但更干净、可审计、可复现：

- 不修改任何二进制文件，**全部是源码级补丁**（`patches/30hx-mod.patch`）
- 用现代内核（7.x）编译，公钥可见、可 diff
- 每个补丁点都带 `[30HX-mod]` 注释，说明为什么改

同时吸收了 NVIDIA-patcher 文档里针对 CMP 30HX / 40HX 的优化建议（见下文的 GSP 章节）。

### A. 绑定条件放宽（针对 30HX 的 0x0302 类设备）

| 文件 | 改动 |
|---|---|
| `kernel-open/nvidia/nv-pci-table.c` | `class_mask` 由 `~0` 改为 `0xff0000`（3D controller 项，两张表都改） |
| `kernel-open/nvidia-drm/nv-pci-table.c` | 同上（两张表） |

官方要求 class 寄存器**低字节**（programming interface）必须为 `0x00`。30HX 上报的是 `0x0302`，理论上能匹配，但矿卡 VBIOS 版本五花八门，只要低字节填了别的值就会静默绑定失败。改成只比较 class 寄存器高 16 位（base class + subclass），彻底消除这个隐患。

已用 `objdump` 验证编进 `.ko` 的 `pci_device_id` mask 确实是 `0x00ff0000`。

### B. 让驱动能在 Kali/Debian 7.x 内核上编出来

| 文件 | 改动 | 原因 |
|---|---|---|
| `Kbuild` | conftest 使用 `NV_VERSION_STRING=615_78_08` | `conftest.sh` 用单引号包裹 CFLAGS，官方写的 `\"615.78.08\"` 会变成字面反斜杠，导致**全部 256 个 conftest 失败**，驱动退化成按最老代码路径编译（表现为 `mmap_sem` 不存在等报错） |
| `Kbuild` | x86_64 增加 `-mharden-sls=all`、`-mindirect-branch=thunk-extern`、`-mindirect-branch-register`、`-fno-jump-tables` | 对齐内核的 SLS / RETHUNK / IBT 策略，objtool 不再报 return-thunk 错误 |
| `Makefile` | 递归 make 传 `AWK=$(AWK)`，透传 `PAHOLE_FLAGS` | 新版 kbuild 里 `$(AWK)` 展开成裸 `awk`，导致 `*.mod` 生成失败、**不产出 `.ko`** |

### C. 构建环境适配（脚本自动处理）

- **头文件树组装**：Kali/Debian 把 headers 拆成 arch 包和 common 包，kbuild 需要 `srctree == objtree` 的一棵树，脚本自动拼好
- **kbuild 二次调用 shim**：kbuild 会在模块目录重跑 `make -f <common/Makefile>`，此时 `$(src)` 为空，脚本临时换入 shim 重放原命令行
- **pahole 缺失**：7.x 的 `scripts/gen-btf.sh` 没 pahole 会直接失败，脚本给副本打补丁改为跳过 BTF
- **gcc include 缺失**：`KCPPFLAGS="-idirafter $(gcc -print-file-name=include)"`

---

## 实测结果

在 Kali Linux 2026.3 / 内核 `7.2.15+kali-amd64` / GCC 16.2.0 上验证通过：

```
NVIDIA CMP 30HX | VBIOS 90.16.58.00.01 | 6144 MiB | 125W | CUDA UMD 13.4
```

| 项目 | 状态 |
|---|---|
| 驱动加载 / `nvidia-smi` | ✅ |
| CUDA | ✅ CUDA 13.4 |
| NVENC / NVDEC | ✅ 可用，未被屏蔽 |
| 构建产物 | 4 个模块，vermagic 匹配，endbr64 生效 |
| PCIe | x16 宽度完好，速率 Gen1（见下文） |

---

## 性能优化：关闭 GSP 固件（30HX / 40HX 建议做）

这是 NVIDIA-patcher 文档里针对 CMP 30HX / 40HX 的推荐优化——关闭 GSP 固件后，游戏和计算负载的性能与稳定性会更好。本项目默认**没有**关，装好后想优化可以执行：

```bash
# 1. 屏蔽 nouveau
sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

# 2. 关闭 GSP
sudo tee /etc/modprobe.d/nvidia-gsp.conf >/dev/null <<'EOF'
options nvidia NVreg_EnableGpuFirmware=0
EOF

# 3. 内核参数（也可以只用上面第 2 步，两者二选一或都加）
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia.NVreg_EnableGpuFirmware=0"/' /etc/default/grub
sudo update-grub && sudo update-initramfs -u -k all

# 4. 重启后验证
sudo reboot
nvidia-smi -q | grep GSP      # 应显示 N/A 或该行消失
```

---

## PCIe 速度：为什么只有 Gen1

很多人关心能不能解锁 PCIe Gen2/Gen3。实测：

```
PCIe Generation
    Device Max : 1     ← 显卡自己上报的最大能力只有 Gen1
    Host Max   : 3     ← 主板支持 Gen3
    Current    : 1
Link Width
    Max/Current: 16x / 16x
```

`Device Max = 1` 是 **VBIOS 写死的链路能力**，系统/内核/驱动都没有软件开关能改。NVIDIA-patcher 的文档也明确说：**解锁 CMP 卡的 x16 PCI-E 需要补焊插槽附近缺失的元件**，属于硬件改动。

所以：

- 想要 Gen2/Gen3 → 刷改过的 VBIOS 或补焊电容，风险自负
- 日常 CUDA 推理、转码、小模型训练跑不满 Gen1 x16 的带宽，**不建议为此冒险**

---

## 验证安装

```bash
nvidia-smi                                    # 总览
lspci -k -s 01:00.0 | grep 'Kernel driver'    # 应为 nvidia
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
nvidia-smi -q | grep -iE 'Encoder|Decoder'    # 编解码能力
nvidia-smi -q | sed -n '/PCIe Generation/,/Link Width/,+4p'
```

---

## 常用选项

```bash
sudo ./install.sh                      # 标准安装
FORCE=1 sudo ./install.sh              # 已装也强制重装
KVER=7.1.5+kali-amd64 sudo ./install.sh # 给指定内核编译安装
SKIP_DEPS=1 sudo ./install.sh          # 跳过依赖自动安装
REBOOT=1 sudo ./install.sh             # 需要重启时自动重启
SKIP_BOOT_FIX=1 sudo ./install.sh      # 不改 grub / initramfs
NO_COLOR=1 sudo ./install.sh           # 关闭彩色输出
```

卸载：

```bash
sudo ./uninstall.sh                    # 卸模块 + 用户态库
sudo ./uninstall.sh --restore-grub     # 同时还原内核命令行
```

---

## 常见问题

**`modprobe: ERROR: could not insert 'nvidia': No such device`**

nouveau 仍占着显卡。脚本已写入屏蔽规则，但需要重启一次才生效：

```bash
sudo reboot
sudo ./install.sh      # 重启后重跑，会自动加载
```

**Secure Boot 开启时加载失败**

未签名模块会被内核拒绝。进 BIOS 关闭 Secure Boot（最简单），或自行给模块签名并 enroll MOK。

**内核升级后驱动失效**

`.ko` 的 vermagic 与内核绑定。升级内核并重启后，重新跑一次 `sudo ./install.sh`。

**安装脚本卡在下载**

把 `NVIDIA-Linux-x86_64-615.78.08.run` 放到仓库根目录再跑，脚本会走离线模式。

**30HX 能接显示器打游戏吗**

不能。矿卡没有显示输出接口，也没有显示控制器。只能当计算卡：CUDA、NVENC/NVDEC 转码、离屏渲染。桌面请用核显或亮机卡。

---

## 文件说明

```
.
├── install.sh            # 一键安装（root，在仓库目录运行）
├── build.sh              # 编译内核模块（不需要 root）
├── uninstall.sh          # 卸载
├── patches/
│   └── 30hx-mod.patch    # 全部魔改
├── NVIDIA-Linux-x86_64-615.78.08.run   # 官方驱动包（自行放入，不入库）
├── README.md / TUTORIAL.md / TESTPLAN.md
└── licenses/
```

---

## 参考项目

- [dartraiden/NVIDIA-patcher](https://github.com/dartraiden/NVIDIA-patcher) — 本项目灵感的来源，Windows 侧矿卡驱动二进制补丁，含 CMP 30HX 支持与 GSP 优化建议
- NVIDIA 官方 [615.78.08 驱动](https://www.nvidia.com/en-us/drivers/)（`supported-gpus.json` 已包含 CMP 30HX `0x2189`）

---

## 许可

- 本项目脚本与补丁（`*.sh`、`patches/`、文档）：**MIT**
- NVIDIA 内核模块源码与用户态库：**NVIDIA 专有许可**，本项目不重新分发，构建时从官方包获取，见 `licenses/`

**本仓库不包含任何 NVIDIA 二进制文件。** 请自行从官网下载驱动包并按教程放入仓库根目录。
