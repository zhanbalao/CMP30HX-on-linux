# CMP 30HX 在 Linux 上的驱动安装教程

> 适用于：NVIDIA CMP 30HX（矿卡，`10de:2189`）想跑 CUDA / 视频转码的 Kali / Debian / Ubuntu 用户。
> 全程约 10 分钟（不含下载待）。

---

## 第 0 步：先确认你的卡真的是 30HX

打开终端，执行：

```bash
lspci -nn | grep -i nvidia
```

看到类似这一行就对了：

```
01:00.0 3D controller [0302]: NVIDIA Corporation TU116 [CMP 30HX] [10de:2189] (rev a1)
```

- 有 `10de:2189` → 继续往下。
- 只看到 `VGA compatible controller` 的普通显卡（1660/2060 之类）→ **不需要本教程**，直接用发行版的 `nvidia-driver` 包就行。

再确认系统架构是 x86_64：

```bash
uname -m        # 输出 x86_64 才对
uname -r        # 记下内核版本，例如 7.2.15+kali-amd64
```

---

## 第 1 步：装上内核头文件（编译的必要条件）

```bash
sudo apt update
sudo apt install -y linux-headers-$(uname -r)
```

验证：

```bash
ls /usr/src/linux-headers-$(uname -r)/Makefile
```

能列出来就说明头文件齐了。

---

## 第 2 步：下载安装脚本

```bash
cd ~
curl -fsSL -o install.sh \
  https://raw.githubusercontent.com/<你的用户名>/CMP30HX-on-linux/main/install.sh
```

> ⚠️ **不要**用 `curl ... | bash` 直接执行。那种方式下 sudo 和 apt 的密码提示读不到键盘输入，会卡住或失败。

看一眼脚本内容（可选，但建议）：

```bash
less install.sh
```

---

## 第 3 步：一键安装

```bash
sudo bash install.sh
```

脚本会自动完成：

| 步骤 | 做什么 |
|---|---|
| 1 | 检查架构、内核、头文件 |
| 2 | 从 GitHub 取回驱动源码和补丁 |
| 3 | 安装编译依赖（gcc、dkms、binutils 等） |
| 4 | 下载 NVIDIA 615.78.08 官方包（约 505 MB） |
| 5 | 打 CMP 30HX 补丁，编译 4 个内核模块 |
| 6 | 安装用户态库 + 内核模块，屏蔽 nouveau |
| 7 | 加载驱动并跑 `nvidia-smi` 验证 |

**中途可能会问你 sudo 密码，输入即可。** 编译大约 3～8 分钟，看到下面的输出就成功了：

```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 615.78.08   KMD Version: 615.78.08   CUDA UMD Version: 13.4                  |
+-----------------------------------------+------------------------+----------------------+
|   0  NVIDIA CMP 30HX                Off |   00000000:01:00.0 Off |                  N/A |
| 30%   43C    P0             32W /  125W |       7MiB /   6144MiB |      0%      Default |
+-----------------------------------------+------------------------+----------------------+
```

（温度、功耗、显存使用量会不一样，只要能看到 `NVIDIA CMP 30HX` 和 `6144MiB` 就行。）

---

## 第 4 步：如果脚本提示要重启

**第一次安装大概率需要重启一次。** 原因：系统启动早期就把 `nouveau`（开源驱动）加载了，它占着你的 30HX，NVIDIA 驱动就抢不到。

脚本已经写好了屏蔽规则，重启一次才生效：

```bash
sudo reboot
```

重启后执行：

```bash
sudo modprobe nvidia
sudo modprobe nvidia-uvm
nvidia-smi
```

能看到第 3 步那张表就彻底装好了。

---

## 第 5 步：验证能用

### 驱动状态

```bash
nvidia-smi
```

### 显卡归属检查

```bash
lspci -k -s 01:00.0 | grep 'Kernel driver'
```

应该显示 `Kernel driver in use: nvidia`（不再是 `nouveau`）。

### CUDA 是否可用

```bash
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
```

### 视频编解码是否可用（转码党必看）

```bash
nvidia-smi -q | grep -iE 'Encoder|Decoder'
```

30HX 的 NVENC / NVDEC 是**可用**的，可以拿来跑 Jellyfin / Emby / Plex 硬解硬编，或者 `ffmpeg -hwaccel cuda`。

### 看看显卡真实能力

```bash
nvidia-smi -q | sed -n '/Product Name/,/Product Architecture/p'
```

---

## 常见问题

### Q1：`modprobe: ERROR: could not insert 'nvidia': No such device`

最常见的原因是 **nouveau 还占着显卡**。检查：

```bash
lsmod | grep -i nouveau
lspci -k -s 01:00.0 | grep 'Kernel driver'
```

如果还有 nouveau，说明屏蔽没生效，重启一次：

```bash
sudo reboot
```

重启后还是不行，检查内核命令行：

```bash
cat /proc/cmdline
```

应该能看到 `nouveau.modeset=0`。如果没有，手动加上：

```bash
sudo nano /etc/default/grub
# 找到 GRUB_CMDLINE_LINUX_DEFAULT，在引号内加上：
#    nouveau.modeset=0 rd.driver.blacklist=nouveau
sudo update-grub
sudo reboot
```

### Q2：`nvidia-smi` 说 "couldn't communicate with the NVIDIA driver"

驱动没加载。执行：

```bash
lsmod | grep nvidia
sudo modprobe nvidia
dmesg | grep -i nvrm | tail -20
```

把最后一条的输出贴到 GitHub Issues 里。

### Q3：内核升级后驱动又不好用了

驱动和内核版本是绑定的。升级内核后，重新跑一遍安装：

```bash
sudo reboot                     # 先重启进新内核
cd ~ && sudo bash install.sh     # 重新编译安装
```

### Q4：想卸载

```bash
sudo rm -rf /lib/modules/$(uname -r)/updates/dkms/nvidia*.ko
sudo depmod -a
sudo rm -f /etc/modprobe.d/nvidia-cmp30hx.conf
sudo reboot
```

（用户态库 `nvidia-smi` 等可以用 `sudo apt purge 'nvidia-*'` 清掉。）

### Q5：装完能不能玩游戏 / 接显示器？

**不能。** 30HX 是矿卡，**物理上没有显示输出接口**，也没有显示控制器。它只能当**计算卡**用：

- ✅ CUDA：跑 AI 推理、训练、科学计算
- ✅ NVENC / NVDEC：视频转码
- ✅ 3D 渲染（off-screen，比如 Blender 渲染、云游戏推流）
- ❌ 接显示器打游戏（没有 HDMI / DP 口）
- ❌ 桌面显示（桌面请用核显 / 亮机卡）

### Q6：PCIe 能不能解锁到 Gen2 / Gen3？

系统里**没有软件开关**。实测这张卡的 `Device Max` 就是 Gen1：

```bash
nvidia-smi -q | sed -n '/PCIe Generation/,/Link Width/,+4p'
```

想提升只能改 VBIOS 或补焊电容，属于硬件魔改，风险自负，本教程不涉及。

---

## 装好之后的日常命令

```bash
nvidia-smi                          # 总览
watch -n 1 nvidia-smi               # 实时监控
nvidia-smi -q                       # 详细信息
nvidia-smi --query-gpu=temperature.gpu,power.draw --format=csv   # 温度功耗
nvidia-smi -q | grep -i 'Encoder\|Decoder'                        # 编解码
```
