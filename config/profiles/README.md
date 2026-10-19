# 加新版本 / 新 profile：复制一份改改就行

```bash
cp -r config/profiles/mint-22.3-xfce config/profiles/<新profile>
# 然后改：
#   profile.conf                        卷标、codename、架构、引导文件、输出名
#   remove-packages.txt / add-packages.txt   增删包（包名按新版本调整）
#   official-package-repositories.list  新版本的源（live 与安装后系统共用，04 复制）
#   preseed-extra.seed                  可选：安装器预置片段（07 幂等追加到 ISO 的 /preseed/linuxmint.seed）
#   apt-sources.list                    可选：03 的 USE_TARGET_SOURCES=1 宿主侧下载源
#   skel/                               默认用户预置（fcitx5、user-dirs 等）
```

构建时选 profile：

```bash
SRC_ISO=xxx.iso PROFILE=<新profile> ./scripts/01-unpack.sh
# ... 02-07 同理（PROFILE 会继承当前 shell 环境变量）
```

`profile.conf` 全部键（都有默认值，见 `scripts/lib.sh` + 07 脚本）：

| 键 | 说明 |
|---|---|
| `ISO_FILENAME` | 原 ISO 默认文件名 |
| `ISO_SHA256` | 为空则跳过校验 |
| `VOLUME_ID` | ISO 卷标（`-V`） |
| `UBUNTU_CODENAME` | 底包代号（如 noble），仅文档/将来用 |
| `ARCH` | 目标架构（amd64/i386/arm64），决定 multiarch 库路径 |
| `BIOS_IMG` / `EFI_IMG` / `CATALOG` | 引导文件；`EFI_IMG` **留空 = BIOS-only**（07 自动跳过全部 UEFI 参数，如 19.3 32 位） |
| `OUT_FILENAME` | 成品 ISO 名（`work/` 下；未设则 `work/<profile>-build.iso`） |

版本差异一般只在这三处：包名变化、库路径变化（04 已用 glob 自适应）、引导结构变化。
宿主与目标版本不一致时，加包用 `USE_TARGET_SOURCES=1 ./scripts/03-add-packages.sh`
（走 profile 自带源下载；host 需有对应 release key）。

> **加/删字体（或改 fontconfig 配置）后必须重跑 06**：06 会用 `bwrap` 跑镜像自己的
> `fc-cache -f` 重建 `/var/cache/fontconfig`，否则 live 首登会因缓存失效重建而黑屏
> （详见 `AGENTS.md`「fontconfig 系统缓存」）。`bwrap` + 非特权 userns 是软依赖，
> 缺失时 06 仅告警跳过。
