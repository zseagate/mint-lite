# mint-lite — 精简中文化 Linux Mint Xfce Live ISO

把官方 Mint Xfce ISO 精简为中文 live ISO：保留中文界面、浏览器、视频播放，去掉 LibreOffice/
Thunderbird 等，新增 VLC + mpv + 中文输入法。现成两套成品 profile：

- `mint-22.3-xfce`：64 位，fcitx5（拼音 + 五笔 wubi98/wbpy）+ Hypnotix
- `mint-19.3-xfce`：32 位老机专用，fcitx4（谷歌拼音 + 五笔 + 五笔拼音），BIOS-only

**全部操作 rootless**（无 sudo、无 chroot、无 mount）：dpkg 手术 + `dpkg-deb -x` + fakeroot 重打包。

多版本/多架构通过 **profile** 支持：`config/profiles/<名字>/`（包清单、源、skel、卷标/引导配置），
脚本用 `PROFILE=` / `SRC_ISO=` / `ARCH=` 切换。加新版本就是复制一份 profile 改改（见 `config/profiles/README.md`）。

## 仓库结构

```
mint-lite/
├── README.md
├── AGENTS.md            踩坑记录（AI/贡献者必读：status 合并、空壳包、setuid、xorriso…）
├── assets/              自定义资源（壁纸、开始菜单 logo）
├── config/profiles/     按版本拆的构建配置
│   ├── mint-22.3-xfce/  成熟 profile（卷标/引导/输出名在 profile.conf）
│   │   ├── remove-packages.txt / add-packages.txt
│   │   ├── official-package-repositories.list
│   │   └── skel/        /etc/skel 预置（fcitx5 profile、user-dirs、英文目录…）
│   └── mint-19.3-xfce/  32 位成品 profile（fcitx4、BIOS-only、bionic 源，构建记录见其 README）
├── scripts/             构建脚本（按编号顺序执行，全部 rootless）
│   ├── lib.sh           公共库（PROFILE/ARCH 解析，勿直接执行）
│   ├── 01-unpack.sh     从原 ISO 解出 root + iso 树（+ 校验 sha + 记录 setuid 表）
│   ├── 02-slim.sh       删包 + 文件级清理
│   ├── 03-add-packages.sh  装新增包（dpkg-deb -x + status/.list 合并）
│   ├── 04-configure.sh  中文化 + skel + autostart（幂等，可反复跑）
│   ├── 05-apply-assets.sh  壁纸/logo 替换（读 assets/）
│   ├── 06-repack.sh     fakeroot 重打 squashfs（按 perms.txt 恢复 setuid/setgid）
│   └── 07-build-iso.sh  xorriso 重建 ISO（保留双引导）
└── work/                工作目录（gitignored：root/、iso/、成品 ISO）
```

## 快速开始

```bash
# 0. 准备：原 ISO 放到项目根（默认名见 profile.conf 的 ISO_FILENAME）
# 1. 解包
./scripts/01-unpack.sh
# 2. 精简
./scripts/02-slim.sh
# 3. 加包
./scripts/03-add-packages.sh
# 4. 配置（中文化/skel/输入法）
./scripts/04-configure.sh
# 5. 换皮肤（改 assets/ 后跑）
./scripts/05-apply-assets.sh
# 6. 刷新 fontconfig 系统缓存 + 重打 squashfs（约 6 分钟）
./scripts/06-repack.sh
# 7. 重建 ISO
./scripts/07-build-iso.sh
# 成品：work/mint-lite-build.iso
```

换 profile / 换 ISO / 换架构：

```bash
SRC_ISO=other.iso PROFILE=other-profile ./scripts/01-unpack.sh  # 02-07 同理
PROFILE=mint-19.3-xfce ./scripts/01-unpack.sh  # 32 位全链路（无系统级 xorriso：lib.sh 自动用 work/xorriso-local shim，重建见 AGENTS）
ARCH=i386 ./scripts/04-configure.sh          # 库路径自动切换 multiarch（19.3 由 profile.conf 自动设）
USE_TARGET_SOURCES=1 ./scripts/03-add-packages.sh  # 宿主与目标版本不一致时，走 profile 源下载
```

## 自定义

| 想改 | 怎么做 |
|---|---|
| 增删组件 | 改 profile 下 `remove-packages.txt` / `add-packages.txt`，重跑 02/03（改字体后 06 会自动刷新 fontconfig 系统缓存，勿删） |
| 壁纸/logo | 替换 `assets/wallpaper.png` / `assets/menu-logo.png`，跑 `05-apply-assets.sh` |
| 默认输入法/目录 | 改 profile `skel/`，重跑 `04-configure.sh` |
| 新版本底包 | 复制一份 profile（见 `config/profiles/README.md`），`SRC_ISO` + `PROFILE` 指向它 |
| 镜像源 | 改 profile `official-package-repositories.list`，重跑 `04-configure.sh` |
| 安装器预置 | 改 profile `preseed-extra.seed`（07 幂等追加到 ISO 的 `/preseed/linuxmint.seed`），重跑 `07-build-iso.sh` |

## 验证

```bash
qemu-system-x86_64 -enable-kvm -m 4096 -cdrom work/mint-lite-build.iso        # BIOS
qemu-system-x86_64 -enable-kvm -m 4096 -bios /usr/share/OVMF/OVMF_CODE_4M.fd -cdrom work/mint-lite-build.iso  # UEFI
```

没有 qemu 时用 VirtualBox 手动测试（32 位 19.3 示例）：

1. 新建虚拟机：类型 Linux、版本 **Ubuntu (32-bit)**、内存 ≥2048MB、硬盘 ≥12GB（测装盘要够）；
   「系统 → 主板」里**不要勾「启用 EFI」**——19.3 是 BIOS-only 盘。
2. 存储 → IDE 控制器 → 光盘挂 `work/mint-lite-19.3-build.iso` → 启动。
3. live 验收：桌面全中文、壁纸/开始菜单 logo 是自定义的；终端可直接打英文命令（默认英文键盘），
   `Ctrl+空格` 唤出 fcitx，谷歌拼音/五笔可切换；Firefox 中文、vlc/mpv 可播；
   `libreoffice`/`thunderbird` 命令应不存在。
4. 装盘验收（ubiquity）：安装器要求目标分区 ≥8GB（`filesystem.size`×2 口径）→ 装完重启后
   仍能打中文（skel 的 `.xinputrc` + `~/.config/fcitx/profile` 随装落盘）、家目录是英文名。

## 当前版本内容（mint-22.3-xfce）

- 删 53 包（LibreOffice 36、Thunderbird 9、词典、transmission、warpinator、papirus/yaru）
- 新增 vlc、mpv、fcitx5 全套（拼音+五笔 wubi98/wbpy）、中文语言包、firefox 中文、hypnotix
- 中文 live + 安装后英文 home 目录名 + 默认 fcitx5
- 壁纸/logo：见 `assets/`

## 当前版本内容（mint-19.3-xfce，2026-10-18 构建）

- 删 81 包（LibreOffice 全家 + `ure`/`uno-libs3`、Thunderbird、词典…）+ 文件级清理（doc/man/非中英 locale）
- 新增 vlc 3.0.8、mpv 0.27.2、fcitx4 全套（谷歌拼音 + 五笔 + 五笔拼音 + 云拼音）、中文语言包、
  firefox 中文（Mint 仍维护 tricia，构建时顺带 71→136.0.1）
- 中文 live + 安装后英文 home 目录名 + 默认 fcitx4；BIOS-only（单 El Torito 入口）
- **2026-10-18 修 live 面板在顶部 / 壁纸未设置 / 输入法无效**（05 把 Mint overlay 的
  `xfce4-panel.xml`+`xfce4-desktop.xml` 复制进恒被读取的 `/etc/xdg/xfce4/xfconf/`；菜单图标改
  whiskermenu；04 补 IM 兜底）——详见 `config/profiles/mint-19.3-xfce/README.md`
- **2026-10-18 修安装卡“正在下载 166 个文件”**：apt 源换阿里云（profile
  `official-package-repositories.list`，live 与安装后系统共用）；预装中文语言支持
  （`fonts-noto-cjk-extra`/`fonts-arphic-*`/`fcitx-pinyin`/`fcitx-sunpinyin`）；用 profile
  `preseed-extra.seed` 关掉安装器的 `install-language-support`（否则会拖 Qt4/KDE）——
  详见 19.3 profile README
- **2026-10-19 修冷启动首个会话黑屏**：根因是加字体后镜像自带的 fontconfig **系统**缓存
  失效，live 首登时重建缓存导致 `xfwm4`/panel/desktop/fcitx/xfsettingsd 在 FreeType 内死循环
  （二次会话正常）。修法：06 打 squashfs 前用 `bwrap` 跑镜像自己的 `fc-cache -f` 重建
  `/var/cache/fontconfig`（`lib.sh refresh_fontconfig_cache`）——详见 AGENTS.md「fontconfig 系统缓存」
- 成品 `work/mint-lite-19.3-build.iso`：1,596,456,960 字节（原盘 1,973,420,032），
  squashfs 1.52GB、manifest 1885 行、sha256 `848513f0bf197de799048b023e4ad766944949695f144804127d46b710777cf8`
