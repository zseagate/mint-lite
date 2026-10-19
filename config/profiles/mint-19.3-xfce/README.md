# mint-19.3-xfce（32 位，已构建）

Linux Mint 19.3 "Tricia" Xfce 32-bit（Ubuntu 18.04 bionic 底包）→ 中文化精简 live。
**2026-10-18 修复 live 面板/壁纸/输入法 + 安装卡“正在下载 166 个文件”**；**2026-10-19 修复冷启动首个会话黑屏**（均见下节），重跑 03→04→06→07。
成品 `work/mint-lite-19.3-build.iso`
（1,596,456,960 B，原盘 1,973,420,032 B，sha256 `848513f0bf197de799048b023e4ad766944949695f144804127d46b710777cf8`）。

## 与 22.3 的差异（全部实测结论，改这里先读 AGENTS 对应章节）

- **输入法 fcitx4**（bionic 没有 fcitx5）：`profile.conf` 的 `IM=fcitx`。包 = `fcitx` +
  `fcitx-frontend-gtk2/gtk3/qt5` + `fcitx-config-gtk` + `fcitx-googlepinyin` /
  `fcitx-table-wubi` / `fcitx-table-wbpy` + `fcitx-module-cloudpinyin`（见 `add-packages.txt`）。
  skel 是 `skel/.config/fcitx/profile`（INI，`EnabledIMList` 里 UniqueNames 实测 =
  `googlepinyin`/`wubi`/`wbpy`，键盘 `fcitx-keyboard-us` 首位），`.xinputrc` = `run_im fcitx`；
  04 生成 `/etc/xdg/autostart/fcitx.desktop`（`Exec=fcitx -d`）。
  **GTK2 + GTK3 两份 `immodules.cache` 都要重建**（04 已覆盖；i386 的 gtk-query 借镜像自带
  `ld-linux.so.2 --library-path` 跑，宿主直接跑是 exec format error）。
- **apt 源**：live 与安装后系统都用 profile 的 `official-package-repositories.list`
  （04 第 [6/7] 步复制进 `work/root/etc/apt/sources.list.d/`）= **阿里云** linuxmint-packages
  tricia + ubuntu bionic 全家桶（见「安装卡…」一节）。`apt-sources.list` 仅供 03 的
  `USE_TARGET_SOURCES=1` 宿主侧下载，同样全走阿里云。2026-10 实测仍可用：03 的
  `apt-get --download-only --no-install-recommends --no-remove` 模式，69 个包 + 3 个版本升级
  （含 firefox 71→136.0.1，Mint 至今维护 tricia）全从这里收。key 用镜像 `trusted.gpg.d`
  分阶段 gpg 校验——镜像 `linuxmint-keyring.gpg` 损坏，mint key 实为
  `ubuntu-defaults.chroot.key.gpg`。
- **引导 BIOS-only**：`EFI_IMG=` 留空 → 07 不加任何 UEFI 参数。重建后指纹 =
  单 El Torito 入口（`Boot media 0 (No Emulation)`，`Bootoff 87 135`，isolinux.bin）
  + `System area summary: MBR isohybrid cyl-align-on`（无 GPT/APM，正常，不是坏了）。
- **32 位**：`ARCH=i386`（lib.sh 优先读 profile.conf）；deb 全 i386；03 有 arch 守卫，
  不符直接报错。跨架构跑 i386 二进制走镜像自带 loader（04 的 `run_target`）。
- **manifest 命名**：`write_manifest` 按 Multi-Arch: same 才加 `:i386`（本盘 808 行限定，
  与原盘共同包逐包对照 0 不一致）；`filesystem.size` = 树 du 4,302,807,040
  （ubiquity `install_size()` ×2 ≈ 8GB 装盘口径）。

## live 会话修复（2026-10-18，VirtualBox 32 位实测暴露）

症状：面板跑到**顶部**、壁纸未设置、输入法无效。根因与修法：

- **面板位置 + 壁纸**：Mint 的默认单面板（底部 `p=10` 的 whiskermenu）与壁纸本在
  `/usr/share/mint-artwork/xfce/`，靠软链 `/etc/xdg/xdg-xfce` + 环境变量
  `XDG_CONFIG_DIRS=/etc/xdg/xdg-xfce:/etc/xdg` 生效（Xsession.d 的 60 脚本设置）。
  该变量一旦不含 `xdg-xfce`，`xfce4-panel` 的 xfconf channel 为空 → 启动时跑 `migrate`
  用上游 `/etc/xdg/xfce4/panel/default.xml` 初始化（`p=6` **顶部** + applicationsmenu，
  外加一个 autohide 底栏），同时 xfdesktop 没壁纸 → 症状全中。
  **05 现在把 overlay 的权威 `xfce4-panel.xml`/`xfce4-desktop.xml` 复制到
  `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/`（`/etc/xdg` 恒在 `XDG_CONFIG_DIRS` 内），
  不再依赖该变量**。沙箱用镜像自带 i386 xfconfd 验证：只给 `/etc/xdg` 也得到
  `configver=2`、`panel-1.position=p=10`、壁纸路径。
- **开始菜单图标**：Mint 用 whiskermenu（不是 default.xml 的 applicationsmenu）。05 现在
  同时改 overlay 与 `/etc/xdg` 两处 `whiskermenu-1.rc` 的 `button-icon` 指向
  `/usr/share/pixmaps/mint-lite-menu.png`（default.xml 的 applicationsmenu 图标保留作兜底）。
- **输入法兜底**：04 除原三保险（autostart + skel `.xinputrc` + im-config 链）外，另把系统级
  `/etc/X11/xinit/xinputrc` 设为 `run_im fcitx`，并在 `/etc/xdg/xfce4/xinitrc`（startxfce4
  里、xfce4-session 启动前执行，无论走不走 im-config 都会跑到）显式
  `export GTK_IM_MODULE/QT_IM_MODULE/XMODIFIERS`。im-config 仍在 Xsession.d 更早执行，不受影响。

> 22.3 也是同一套「overlay 经 XDG_CONFIG_DIRS 生效」机制，重打时同样受益于 05 的复制段。

## 安装卡在“正在下载 166 个文件”（2026-10-18，VirtualBox 实测）

症状：live 联网正常，ubiquity 走到某步显示“正在下载第 N 个文件，共 166 个”后长时间不动。

根因（两条，都是原厂源在国内太慢）：

1. **索引**：安装期 `apt-setup-verify` 会跑一次 `apt-get update`（Mint 改动，见
   `/usr/lib/ubiquity/apt-setup/apt-setup-verify` 第 91-102 行）。注意它虽用
   `Dir::Etc::sourcelist=<generator tmp>`，**但 `sourceparts` 仍是 target 的
   `/etc/apt/sources.list.d/`，于是会把恢复出来的 `official-package-repositories.list`
   全量拉一遍**——i386 下实测正好 **195 个**索引文件（`apt-get ... update --print-uris`
   数得），对应你看到的 166。原厂源 4.4s/54KB/s，于是“爬不动”。
2. **语言支持包**：`install_misc.py:select_language_packs()` 默认 `install_new=True`，会把
   `check-language-support -l zh_CN` 的**缺失集**也装进 target。

修法：

- **换阿里云源**：新增 profile 的 `official-package-repositories.list`（04 复制；
  live 与安装后系统共用）。实测阿里云 0.3s/780KB/s，索引几秒抓完。
  原厂的 `archive.canonical.com`（partner）国内直接超时、阿里云也不镜像 → 整行去掉。
- **预装中文语言支持**：`add-packages.txt` 加了 `check-language-support -l zh_CN` 缺失集里的
  字体/拼音 `fonts-noto-cjk-extra` + `fonts-arphic-{uming,ukai}` + `fcitx-pinyin` +
  `fcitx-sunpinyin`（03 实测新增 7 包，167MB——`fonts-noto-cjk-extra` 一个就 131MB）。
- **关掉“新装语言支持”**：该缺失集还剩 `fcitx-frontend-qt4` + `fcitx-ui-qimpanel`，
  会拖进 Qt4(15M) + Qt5 QML 全套，lite 不该要。新增 profile 的 `preseed-extra.seed`，
  由 07 幂等追加到 ISO 的 `/preseed/linuxmint.seed`：
  `d-i pkgsel/install-language-support boolean false`。机制：casper 的
  `casper-set-selections` 对未注册的问题会 `db_register debian-installer/dummy` 再 `db_set`，
  所以即便 live 库里没有该模板也能生效；ubiquity 于是只保留已装的、不再下载那两个。

> 副作用：ISO 由 1.40GB 涨到 1.49GiB（全是字体）。若嫌大，把 `fonts-noto-cjk-extra`
> 从 `add-packages.txt` 去掉即可省 ~130MB（代价：罕见汉字/异体字回退到 `fonts-noto-cjk`）。

## 冷启动首个会话黑屏（2026-10-19，VirtualBox 32 位实测）

症状：冷启动进 live 后，**第一个** XFCE 会话黑屏（无面板/壁纸）；`sudo systemctl restart lightdm`
出来的第二会话一切正常。VDI 冷启动必现。

定位与根因（详见 AGENTS.md「fontconfig 系统缓存」）：

- 黑屏会话里 `xfwm4`/`xfce4-panel`/`xfdesktop`/`fcitx`/`xfsettingsd` **全部**陷在
  `libfreetype.so.6` 内死循环（STAT `R1`、CPU 高、`strace -c` 几乎无系统调用、ptrace
  采样 EIP 恒定；`libfreetype` 与原盘逐字节一致，非库损坏）。
- 加字体包（`fonts-noto-cjk-extra`/`fonts-arphic-*`）后，镜像自带的 `/var/cache/fontconfig`
  系统缓存失效；**首登家目录全新、`~/.cache/fontconfig` 不存在**，fontconfig 于是重建缓存，
  该路径让上述进程在 FreeType 里死循环。家目录缓存写全后（第二会话）即正常。
- 因果实证：`rm -rf ~/.cache/fontconfig` + 重启 → 复现黑屏；先 `sudo fc-cache -f`
  （刷新系统缓存）再删用户缓存 + 重启 → 正常桌面。

修法：`06-repack.sh` 打 squashfs 前调 `lib.sh refresh_fontconfig_cache`——用 `bwrap`
（非特权 userns，rootless "chroot"）把 `work/root` 当根、跑镜像自己的 `fc-cache -f`，
按镜像内绝对路径重建 `/var/cache/fontconfig`。**无需改包清单/字体**；重建 06→07 即可。

**验证（2026-10-19，VirtualBox 32 位冷启动）**：首个会话直接出完整桌面（壁纸/底部面板/
中文图标），`uptime` load ≈0.35（原故障时 6.82）、`xfwm4`/`xfce4-panel`/`fcitx` 全部 `S`（不再
`R` 自旋）、fcitx 已起、`xprop _NET_SUPPORTING_WM_CHECK` 有值（故障时缺失）。

## 待办（需要虚拟机，见根 README「验证」）

- [x] VirtualBox 32 位客户机 live **首会话**验收（2026-10-19 冷启动，**黑屏已修**）：
      面板在**底部**、壁纸已设置、全中文、fcitx 进程已起、WM 已注册、load≈0（见上节）。
- [ ] 继续点验：输入法实际打字（`Ctrl+空格` → 谷歌拼音/五笔）、vlc+mpv、Firefox 中文、
      LibreOffice·Thunderbird 命令已消失
- [ ] 装盘测试（ubiquity）：目标分区 ≥8GB → 装完重启后输入法仍可用、家目录英文名。
      **重点看**：不再卡“正在下载 166 个文件”（索引走阿里云）；
      装好后 `dpkg -l | grep -E 'fcitx-frontend-qt4|fcitx-ui-qimpanel|libqtcore4'` 应为空；
      `dpkg -l fonts-noto-cjk-extra` 已装
- [ ] 有 qemu 的环境回归：BIOS-only 启动 + El Torito 指纹（`isoinfo -d`）

## 已知无害差异（vs 原盘）

- PVD `System id`：原盘 `LINUX`，重建为空——mkisofs 兼容层不暴露该选项，纯展示字段，不影响引导。
- `filesystem.manifest-remove` 沿用原盘 2019 文件（装盘要删的 live 包都还在库里，
  15/15 精确匹配已核）。
- El Torito catalog/引导镜像 LBA 差 4 个扇区（134/135 vs 原 138/139）：布局由 xorriso
  自动摆放，结构等价（同为单 BIOS 无仿真启动）。
