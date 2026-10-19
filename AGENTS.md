# AGENTS.md — mint-lite

把官方 Mint Xfce ISO 精简为中文化 live ISO（现成两套：`mint-22.3-xfce` 64 位 + fcitx5、`mint-19.3-xfce` 32 位 + fcitx4，均已构建）。流水线全在 `scripts/01-07`（按编号顺序跑，全部 rootless，公共逻辑在 `scripts/lib.sh`），构建配置按版本拆在 `config/profiles/<名字>/`（包清单、源、`skel/`、`profile.conf` 卷标/引导配置），自定义资源在 `assets/`。`work/`（root/、iso/、成品 ISO）是工作目录，不进版本库。

环境变量：`SRC_ISO=`（原 ISO，可省略——按 profile.conf 的 `ISO_FILENAME` 在项目根自动找）、`PROFILE=`（默认 `mint-22.3-xfce`）、`ARCH=`（默认取 profile.conf 的 `ARCH=`，19.3 为 i386；无则回退宿主架构，`i386` 自动切 multiarch 库路径）、`OUT_ISO=`、`USE_TARGET_SOURCES=1`（宿主与目标版本不一致时走 profile 源下载 deb）。加新版本 = 复制一份 profile 改改，见 `config/profiles/README.md`。

## 环境约束

- 无 root：无 sudo、无 chroot、无 mount。`locale-gen` 不可用，`apt -o RootDir=` 不可用（会 unlink 整个 root 目录）。
- 无系统级 `xorriso`：01/07 走 rootless shim——`work/xorriso-local/bin/xorriso`（4 行包装脚本：设 `LD_LIBRARY_PATH` 指向 `../root/usr/lib/x86_64-linux-gnu` 再 exec 真二进制），lib.sh 发现 PATH 无 xorriso 且 shim 存在时**自动挂上**（无需再手动 `PATH=` 前缀）。重建（`work/` 清了就没了）：`apt download xorriso libisoburn1t64`（noble 包名）+ 必要的 libisofs/libburn deb（本机 `/lib` 恰有 `libisofs.so.6`/`libburn.so.4`，缺则 `ldd` 按报错补下）→ 全部 `dpkg-deb -x *.deb work/xorriso-local/root/` → 手写包装脚本 `chmod +x`。无 `qemu`：自动验证跑不了，改 VirtualBox 手动测（步骤见 README「验证」）。只读检查 ISO 用 `isoinfo`/`7z l`（7z 甚至能看 El Torito 目录树）；shellcheck 静态二进制放 `/tmp/opencode/shellcheck`（GitHub release 下载，tmp 重启即清——没了就重新下；CI 用同款默认规则，本地过了 CI 才绿）。
- 构建约需：解包后 `work/root` ~5.6GB 磁盘空间；`mksquashfs` xz 约 6 分钟。
- 临时文件放 `/tmp/opencode`；`work/` 路径一律用相对路径（不要写死 `/home/<user>/...`）。

## 常用命令

```bash
./scripts/01-unpack.sh  # 解出 work/root + work/iso（xorriso 整树 extract，见下）
./scripts/02-slim.sh    # 按 profile 的 remove-packages.txt 删包 + 文件级清理
./scripts/03-add-packages.sh  # 按 profile 的 add-packages.txt 加包
./scripts/04-configure.sh     # 中文化/skel/输入法（fcitx5 或 profile 的 IM=fcitx；幂等，可反复跑）
./scripts/05-apply-assets.sh  # 壁纸/logo（改 assets/ 后跑）
./scripts/06-repack.sh  # 刷新 fontconfig 系统缓存 + fakeroot 重打 squashfs
./scripts/07-build-iso.sh     # xorriso 重建 ISO + 引导验证
```

自定义：改 profile 下 `remove-packages.txt` / `add-packages.txt` 后重跑 02/03；改 profile `skel/` 后重跑 04；换 `assets/*.png` 后跑 05→06→07。
换版本：全链路带 `PROFILE=`，如 `PROFILE=mint-19.3-xfce ./scripts/01-unpack.sh`（01-07 同前缀；01/07 的 xorriso 由 lib.sh 自动挂 shim，见「环境约束」）。
验证：本机无 qemu（命令留档：`qemu-system-x86_64 -enable-kvm -m 4096 -cdrom work/mint-lite-build.iso`，UEFI 加 `-bios /usr/share/OVMF/OVMF_CODE_4M.fd`）；现状走 VirtualBox 手动测，32 位客户机步骤见 README「验证」。

## dpkg / apt（rootless 固定姿势）

- 查包必须带 admindir，否则读的是宿主库：`dpkg-query --admindir=work/root/var/lib/dpkg -W -f='${Package} ${Status}\n'`
- **删包必须 `dpkg --root=<绝对路径>/work/root --admindir=.../var/lib/dpkg --force-all --no-triggers`。绝不能只给 `--admindir`**：那只改数据库位置，`.list` 里的绝对路径仍指向宿主——实测 purge 报"无法移除 /usr/lib/libreoffice/... 权限不够"（宿主装了 LO 才靠权限位幸免；有 root 会真删宿主文件），且文件从未从 work/root 删掉（假瘦身）。
- **删包前先把维护脚本换 exit-0 存根**（`info/<pkg>.<script>` 备份为 `.rootless-bak`）：脚本写宿主绝对路径，rootless 必失败留 `half-*` 状态；`--no-triggers` 防触发器把 man-db/mime-support 等保留包连坐成 half-configured。清单内包无人用 update-alternatives，清空脚本安全。见 `02-slim.sh`（自带终审计：清单包全消失+文件真被删+全库零 half-*）。
- `apt-get -s remove` 只做模拟，且必须用 `Dir::State::status=` 等 5 个 `Dir::` 选项指到 `work/root`，禁用 `RootDir=`。
- 用 apt 做任何事（模拟 `-s`、依赖解析）必须同时带：`-o APT::Architecture=<目标>`（宿主 amd64 读 i386 的 status 会把所有包报"无法安装它"）、`-o Dir::State::status=<root>/var/lib/dpkg/status`、`-o Dir::State::lists=`、`-o Dir::Cache=`、`-o Dir::Etc::sourcelist=/dev/null`、`-o Dir::Etc::sourceparts=/dev/null`、`-o Debug::NoLocking=1`——七件套缺一即错或碰宿主。
- 加包的 deb 默认走宿主 `apt download`；宿主与目标版本不一致时用 `USE_TARGET_SOURCES=1`：03 走 profile 的 `apt-sources.list`（19.3 实测可用：阿里云 bionic main/restricted/universe/multiverse + updates + security、packages.linuxmint.com tricia，2026-10 连 firefox 71→136 升级都还在收），`apt-get install --download-only --no-install-recommends --no-remove` 只下载、不动宿主不碰目标状态；key 用镜像 `trusted.gpg.d` 里的文件分阶段 gpg 校验（`--no-keyring --keyring <file> --no-default-keyring` 逐个试），**镜像的 `usr/share/keyrings/linuxmint-keyring.gpg` 损坏，mint key 实为 `ubuntu-defaults.chroot.key.gpg`**。arch 与 profile 不符时 03 直接报错退出。
- `apt remove 'foo*'` 通配符会匹配几百个未装包，输出全是噪音——用具体包名（清单见 profile）。
- **绝不跑 `apt autoremove`**，会拖走桌面。以下不要动，删之前先 `-s remove` 看级联：
  - 主题/图标/cursor（`mint-*-icons`/`mint-themes` 等）→ `mint-artwork` → `mint-meta-core` → `mint-meta-xfce`
  - `gcc-13`/`g++-13`/`cpp-13`、内核头文件 → `dkms`/`build-essential`，还会拖走 `xfce4-session`
- 省空间靠文件级清理：`usr/share/doc`、`man`、`help`、非 `zh*`/`en*` 的 `usr/share/locale`、`var/lib/apt/lists`。

## 加包：status + .list 必须同步（"空壳包"坑）

- `dpkg-deb -x` 只解文件，不写 status。只解不合并 → dpkg 看不到包、manifest 缺项。每个 deb 必须：`dpkg-deb -e` 取 control，prepend `Status: install ok installed` 后合并；再从 `dpkg-deb -c` 输出生成 `var/lib/dpkg/info/<pkg>.list`（取 `./` 开头的字段——`dpkg-deb -c` 的 symlink 行最后一列是链接目标，不是路径）。逻辑已在 `03-add-packages.sh`，改动时沿用它。
- status 合并按空行分段：每段含 `Package:` 则保证以 `Status: install ok installed` 开头；整体写回，不要原地 append（control 文缺换行会 corrupt 整个 status，`dpkg-query` 全盘失败）。

## squashfs 重打（`06-repack.sh`，不要改方案）

- **不用 `-all-root`**：它保留 setuid 位却把 setgid 文件属组压成 root:root（`unix_chkpwd` 变 root:root 而非 root:shadow → sudo 密码失效）。正确方案：fakeroot 内 `chown -R root:root` + 按 `work/perms.txt` 逐条 `chown user:group` + `chmod oct` 回放，`mksquashfs -comp xz -b 128K -noappend` 且不加 `-all-root`。
- `work/perms.txt` 由 `01-unpack.sh` 从原 squashfs 元数据生成（`unsquashfs -ll` 解析 mode 含 `s` 的行；**必须走这条路**——非 root 解包会丢 s 位，`find -perm` 在 `work/root` 里扫不到）。无 perms.txt 时 06 回退到内置 Mint 22.3 表，仅应急用。
- 重打后必须同步 `work/iso/casper/` 下两文件：
  - `filesystem.manifest`：**用 lib.sh 的 `write_manifest`**（02/03 调用）。原厂命名口径 = **Multi-Arch: same 才加 `:arch` 限定**，其余裸名（bionic dpkg 的 `${binary:Package}` 规则；原盘 763 个限定行全是 MA:same，用该规则与原盘 1807 个共同包逐包对照 0 不一致）。**禁用宿主 noble dpkg 的 `${binary:Package}`**——它给所有外来架构包都加限定（多 ~630 行），`manifest-remove` 的 15 个精确匹配会丢 4 个（装完盘 ubiquity/gparted/python3-pam/ubiquity-frontend-gtk 清不掉）。
  - `filesystem.size` = **解包树的字节数**（`du -sB1 work/root`，十进制+换行），**不是 squashfs 体积**——实测 19.3 原盘 5.34GB、22.3 原盘 8.10GB，都远超各自 squashfs（1.90/2.57GB）且为 4096 整倍数；ubiquity `misc.py: install_size()` 读它**×2 判定装盘最小分区**（超 8GB 封顶），写成 squashfs 小值会让安装器误判空间够用。07 已按此修；冻结的 22.3 成品写的是 squashfs 大小（2.19GB，与原厂口径不符，重打才能修，未动）。

## fontconfig 系统缓存（live 首登黑屏的根因，勿删）

- **症状**：中文盘冷启动后**首个** XFCE 会话黑屏（`sudo systemctl restart lightdm` 后的第二会话则正常）。实测 `xfwm4`/`xfce4-panel`/`xfdesktop`/`fcitx`/`xfsettingsd` **全部**陷在 `libfreetype.so.6` 内死循环（`ps` STAT `R1`、CPU 高、`strace -c` 几乎无系统调用、ptrace 采样 EIP 恒定）。VDI 冷启动必现。
- **根因**：镜像自带的 `/var/cache/fontconfig`（**系统**缓存）只对原盘的字体/配置有效。02/03/04 增删字体包或加 fontconfig 配置后，缓存条目失效；live **首次登录**（家目录全新、`~/.cache/fontconfig` 不存在）时 fontconfig 会**重建缓存**，该重建路径令上述进程在 FreeType 里死循环，直到家目录缓存被写全（故第二会话正常）。原盘英文 locale 从不渲染中文，因此不触发。
- **已证实的因果**：`rm -rf ~/.cache/fontconfig` + `systemctl restart lightdm` → 复现黑屏；先 `sudo fc-cache -f`（刷新系统缓存）再删用户缓存 + 重启 → 正常桌面。
- **修复**：`06-repack.sh` 打 squashfs 前调 `lib.sh refresh_fontconfig_cache`——用 `bwrap`（非特权 userns，rootless "chroot"）把 `work/root` 当根、跑**镜像自己的** `fc-cache -f`，按镜像内绝对路径重建 `$R/var/cache/fontconfig`。**必须在所有字体/配置改动之后做**（放 06 最稳；放 04 的话改字体而没重跑 04 会漏）。宿主不能直接跑目标 `fc-cache`：字体路径会指到宿主的 `/usr/share/fonts`，且 i386 二进制需镜像自带 loader 加载。
- **验证**：`bwrap ... /usr/bin/fc-cache -v` 应对所有字体目录输出 `existing cache is valid`（`/tmp/.local/share/fonts` 等 "no such directory" 属正常）；随后冷启动确认桌面非黑屏。
- 依赖 `bwrap` + 允许非特权 userns；缺则 `refresh_fontconfig_cache` 告警并跳过（ISO 仍能出，但首登可能黑屏）。

## ISO 解包/重建（已验证，唯一可用组合）

- 解包：`xorriso -extract /` 整树取（单文件 `-extract` 在此镜像上失败）；之后 `chmod -R u+w work/iso/`（原文件 0444/目录 0555，否则 `mksquashfs` 报 Permission denied）；`unsquashfs -d work/root work/iso/casper/filesystem.squashfs`。01 还会校验 sha（`profile.conf` 的 `ISO_SHA256`，为空则跳过）并写 `work/original.sha256`。
- 重建：只用 `xorriso -as mkisofs` 在 `work/iso/` 内重建（`07-build-iso.sh`，MBR 模板 `work/isohdpfx.bin`，卷标/引导文件来自 `profile.conf`，可用 `VOLID=`/`BIOS_IMG=`/`EFI_IMG=`/`CATALOG=` 覆盖）。`-indev/-outdev -update` 会丢 El Torito，禁用。
- 引导指纹（重建后核对）：El Torito catalog LBA 2112、BIOS (`isolinux/isolinux.bin`) + UEFI (`boot/grub/efi.img`) 双引导、`System area summary: MBR isohybrid cyl-align-on + GPT + APM`。**这是 22.3 的双引导指纹**；BIOS-only profile（如 `mint-19.3-xfce`，profile.conf 的 `EFI_IMG` 为空）只有一个 El Torito 入口是正常状态，不是坏了。

## 输入法：fcitx5（22.3）/ fcitx4（19.3）——live + 安装后都要能打字

- noble 里没有 `fcitx5-core`、没有 `fcitx5-table-wubi`。五笔包是 `fcitx5-table-wubi-large` / `fcitx5-table-wubi98`；profile 里有效名是 `wubi98`/`wubi-large`/`wbpy`（`wubi` 不存在，写错则 addon 加载失败）。当前 skel profile：`keyboard-us` 首位（默认英文，终端可直接打命令），pinyin + wubi98 + wbpy 保留可用。
- addon 硬依赖缺一即显示"(不可用)"：`pinyin.conf` Requires `punctuation`，`table.conf` Requires `punctuation`+`pinyinhelper`——所以 `fcitx5-module-punctuation`、`fcitx5-module-pinyinhelper` 必装；拼音另需 `libimepinyin0`（`libIMEPinyin.so.0`）+ `libopencc1.1`/`libopencc-data`/`libmarisa0`；GTK3 前端需 `libfcitx5gclient2`（`libFcitx5GClient.so.2`），Qt5 需 `libfcitx5-qt1`+`libfcitx5-qt-data`，`fcitx5-config-qt` 需 KF5（`libkf5itemviews5`/`libkf5widgetsaddons5`+data）。完整清单见 profile 的 `add-packages.txt`；新增 .so 后用 `readelf -d | grep NEEDED` 扫一遍无缺口再重打。
- GTK3 `immodules.cache` 必须重建并含 fcitx5（`fcitx`+`fcitx5` 两个 context 名），否则 GTK3 应用打不了字——rootless 命令见 `04-configure.sh`（`LD_LIBRARY_PATH` 指向 root 内 multiarch lib + `sed` 去 `$R` 前缀；gtk-query 二进制用 glob 找，跨版本路径不同）。
- 自启三保险：`04-configure.sh` 写的 `/etc/xdg/autostart/fcitx5.desktop` 兜底 + skel `.xinputrc`（`run_im fcitx5`）+ 镜像原有 im-config 链（zh_CN 下自动选 fcitx5）。动自启前先读 04 脚本，不要另起写法。
- **fcitx4（19.3/bionic，profile.conf `IM=fcitx`）**：bionic 没有 fcitx5。04 读 `IM=` 决定自启 desktop（清旧写新 `/etc/xdg/autostart/fcitx.desktop`，`Exec=fcitx -d`）与校验对象。包 = `fcitx` + 前端 `fcitx-frontend-gtk2/gtk3/qt5`（GTK2 前端 19.3 特有，镜像自带 GTK2）+ `fcitx-config-gtk` + `fcitx-googlepinyin`/`fcitx-table-wubi`/`fcitx-table-wbpy` + `fcitx-module-cloudpinyin`（清单见 profile `add-packages.txt`，新增 .so 后照旧 `readelf -d | grep NEEDED` 扫缺口）。
- fcitx4 skel 格式完全不同：`skel/.config/fcitx/profile`（INI：`[Profile]` + `IMName=fcitx-keyboard-us` + `EnabledIMList=fcitx-keyboard-us:True,googlepinyin:True,wubi:True,wbpy:True`，英文键盘首位）；UniqueNames 实测 = `googlepinyin`/`wubi`/`wbpy`（**没有 fcitx5 目录、不是 addon conf 名**），`.xinputrc` = `run_im fcitx`。自启三保险同构：autostart + `.xinputrc` + 原有 im-config 链。
- **GTK2 的 `immodules.cache` 也要重建**（22.3 只有 gtk3）；i386 的 `gtk-query-immodules-3.0` 借镜像自带 loader 跑（04 的 `run_target`：`ld-linux.so.2 --library-path <root>/lib:...`，宿主直接跑会 exec format error）；生成后必须无 `$PWD` 残留——gtk-query 会 realpath 入参，04 双重 sed 后硬校验，失败即退出。
- **IM 环境变量兜底（04 第 5b 步）**：`70im-config_launch` 的 `if [ -z "$GTK_IM_MODULE" ]...` 守卫一满足就跳过 `.xinputrc`、且**不**置 `IM_CONFIG_PHASE`，于是 `im-launch` 也不启动输入法；所以在 `/etc/environment` 里预置 IM 变量会**反过来废掉** im-config 链。正确兜底 = 04 把系统级 `/etc/X11/xinit/xinputrc` 写成 `run_im <IM>`（`~/.xinputrc` 缺失时也选对），并在 `/etc/xdg/xfce4/xinitrc` 的 `exec xfce4-session` 前插入 `export GTK_IM_MODULE/QT_IM_MODULE/XMODIFIERS`（该文件在 startxfce4 里、session 启动前跑，无论走不走 im-config 都会跑到，且不干扰更早执行的 im-config）。fcitx 进程本身仍由 04 的 autostart 兜底拉起。

## 中文化 + 英文家目录（缺一即回退）

- locale 三件套：`/etc/default/locale` → `LANG=zh_CN.UTF-8`；`/etc/locale.gen` 启用 `zh_CN.UTF-8`；rootless 生成 `localedef --prefix=$PWD --no-archive -i zh_CN -f UTF-8 zh_CN.UTF-8`（产物 `usr/lib/locale/zh_CN.utf8`）。
- 英文目录名靠小写开关：`/etc/xdg/user-dirs.conf` 必须是 `enabled=False`（**小写 e**；镜像原大写 `Enabled=` 是 no-op，updater 照跑；`xdg-user-dirs-update --force` 只认小写）。另需 skel 预置 8 个英文实体目录 + `.config/user-dirs.dirs`（英文路径）+ `.config/user-dirs.locale`（`en_US.UTF-8`，防改名提示）。live 用户开机才创建，一律写 `/etc/skel`（profile 的 `skel/` 是来源）。

## live 面板 / 壁纸 / 开始菜单图标（Mint overlay 机制 + 05 兜底）

- Mint 的默认**单面板**（底部、whiskermenu）与壁纸本在 `/usr/share/mint-artwork/xfce/`，靠软链 `/etc/xdg/xdg-xfce` + 环境变量 `XDG_CONFIG_DIRS=/etc/xdg/xdg-xfce:/etc/xdg` 生效（Xsession.d 的 `60x11-common_xdg_path` 设置，依赖 lightdm 传的 `DESKTOP_SESSION=xfce`）。
- **该变量一旦不含 `xdg-xfce`**：`xfce4-panel` 的 xfconf channel 为空 → 启动时 `panel-application.c` 判 `configver < 2` 跑 `migrate` helper → 用**上游** `/etc/xdg/xfce4/panel/default.xml` 初始化（`p=6`=**顶部** applicationsmenu + 一个 autohide 底栏），同时 `xfdesktop` 无默认 → 无壁纸。**Mint 用 whiskermenu，不是 default.xml 的 applicationsmenu**；菜单图标在 `/usr/share/mint-artwork/xfce/xfce4/panel/whiskermenu-1.rc` 的 `button-icon`。
- **坐标语义**（xfce4-panel 4.14 `SnapPosition` 枚举）：`p=6`=`SNAP_POSITION_NW`（左上）、`p=10`=`SNAP_POSITION_SC`（底部居中）。别靠猜，源码 `panel/panel-window.c` 的 enum 为准。
- **05 的兜底（勿删）**：把 overlay 的 `xfce4-panel.xml`/`xfce4-desktop.xml` 复制进 `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/`（`/etc/xdg` 恒在 `XDG_CONFIG_DIRS` 内，两种情况下都得到底部面板 + 壁纸）；把 overlay 与 `/etc/xdg` **两处** `whiskermenu-1.rc` 的 `button-icon` 指向 `/usr/share/pixmaps/mint-lite-menu.png`（default.xml 的 applicationsmenu 图标仍保留作 migrate 兜底）。22.3 是同一机制，重打也建议带上本段。
- **无 X 验证法**：rootless 起镜像自带 i386 `xfconfd` + 假 HOME，设 `XDG_CONFIG_DIRS=$PWD/work/root/etc/xdg`（**只给标准目录**），`xfconf-query -c xfce4-panel -p /configver` 应为 `2`、`/panels/panel-1/position` 应为 `p=10;x=0;y=0`、`-c xfce4-desktop -p /backdrop/screen0/monitor0/image-path` 应为 `/usr/share/xfce4/backdrops/linuxmint.jpg`。

## 安装器的 apt 源与联网下载（换源 + 预置，勿删）

- **live 的 apt 源 = profile 的 `official-package-repositories.list`**（04 第 [6/7] 步复制进 `work/root/etc/apt/sources.list.d/`）。安装后系统**继承**它（target 是 live 的文件系统拷贝），所以这一份同时决定安装期与装机后的源。19.3 已换阿里云：原厂 `archive.ubuntu.com`/`packages.linuxmint.com` 国内实测 4.4s/54KB/s、2.7s/9KB/s；阿里云 0.3s/780KB/s。`archive.canonical.com`（partner）国内直接超时、阿里云也不镜像 → 整行删掉。
- **“安装卡在正在下载 X 个文件”的根因**：`/usr/lib/ubiquity/apt-setup/apt-setup-verify`（Mint 改动，第 91-102 行）在安装期跑一次 `apt-get update`；它虽用 `Dir::Etc::sourcelist=<generator tmp>`，**但 `sourceparts` 仍是 target 的 `/etc/apt/sources.list.d/`**，于是把恢复出来的 `official-package-repositories.list` 全量拉一遍——i386 下正好 **195 个**索引（`apt-get -o Dir::Etc::sourcelist=... update --print-uris` 可数）。源慢就卡在这。**换快源即可**（别去改 apt-setup-verify）。
- **语言支持包**：`ubiquity/install_misc.py:select_language_packs()` 默认 `install_new=True`，把 `check-language-support -l <locale>` 的**缺失集**也装进 target。zh_CN 的缺失集只有 7 个，其中 `fcitx-frontend-qt4` + `fcitx-ui-qimpanel` 会拖 Qt4(15M)+Qt5 QML 全套。
- **profile 可提供 `preseed-extra.seed`**：07 会幂等追加到 ISO 的 `/preseed/linuxmint.seed`（带 marker 注释防重复；该文件在 `work/iso` 树里、只有 07 打包，所以放 07）。19.3 用它写 `d-i pkgsel/install-language-support boolean false` 关掉上面那条。**机制**：casper 的 `casper-set-selections` 对**未注册**的问题会 `db_register debian-installer/dummy` 再 `db_set`，所以即便 live 库里没有该模板（实测没有）也生效；反之直接 `debconf-set-selections` 未注册问题会失败。`cli.seed` 里的同名行是 d-i 用的，与 ubiquity 无关。
- **省空间**：`fonts-noto-cjk-extra` 一个就 131MB deb（19.3 因此从 1.40GB 涨到 1.49GiB）。要瘦就把它从 `add-packages.txt` 去掉。
