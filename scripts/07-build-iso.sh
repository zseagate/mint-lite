#!/bin/bash
# 07-build-iso.sh: xorriso -as mkisofs 重建（唯一可用方式，保留双引导）
# 警告：-indev/-outdev -update 会丢 El Torito，不要用。
# 卷标/引导文件来自 profile.conf，可被环境变量覆盖：
#   VOLID=... BIOS_IMG=... EFI_IMG=... CATALOG=... OUT_ISO=... ./scripts/07-build-iso.sh
# profile 的 EFI_IMG 留空 = BIOS-only 镜像（如 19.3 32 位），自动跳过全部 UEFI 参数。
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
[ -d work/iso ] || { echo "先跑 01-unpack.sh"; exit 1; }
command -v xorriso >/dev/null || { echo "缺 xorriso"; exit 1; }

VOLID="${VOLID:-$(profile_conf VOLUME_ID "")}"
[ -n "$VOLID" ] || { echo "profile 无 VOLUME_ID，设 VOLID=..."; exit 1; }
BIOS_IMG="${BIOS_IMG:-$(profile_conf BIOS_IMG isolinux/isolinux.bin)}"
EFI_IMG="${EFI_IMG:-$(profile_conf EFI_IMG "")}"   # 空 = BIOS-only
CATALOG="${CATALOG:-$(profile_conf CATALOG isolinux/boot.cat)}"
if [ -z "$OUT_ISO" ]; then
  OUT_ISO="work/$(profile_conf OUT_FILENAME "${PROFILE}-build.iso")"
fi
[ -f "work/iso/$BIOS_IMG" ] || { echo "缺 BIOS 引导文件 work/iso/$BIOS_IMG（改 profile.conf 的 BIOS_IMG）"; exit 1; }
if [ -n "$EFI_IMG" ]; then
  [ -f "work/iso/$EFI_IMG" ] || { echo "缺 EFI 引导文件 work/iso/$EFI_IMG（改 profile.conf，或留空走 BIOS-only）"; exit 1; }
fi

# 追加 profile 的安装器预置片段到 ISO 的 /preseed/linuxmint.seed（幂等，marker 防重复）。
# 该文件在 work/iso 树里、只有本步骤会打包，所以放这里；改 profile 的 preseed-extra.seed 后重跑 07。
# 例：19.3 用它关掉 pkgsel/install-language-support，避免安装器把 fcitx-frontend-qt4 等
# （拖 Qt4/KDE）装进目标系统（详见 config/profiles/mint-19.3-xfce/preseed-extra.seed）。
SEED="work/iso/preseed/linuxmint.seed"
EXTRA="$PROFDIR/preseed-extra.seed"
SEED_MARK="# === mint-lite: $PROFILE/preseed-extra.seed ==="
if [ -f "$EXTRA" ] && [ -f "$SEED" ]; then
  if grep -qF -- "$SEED_MARK" "$SEED"; then
    echo "preseed: 已含 profile 片段（$EXTRA），跳过"
  else
    { echo ""; echo "$SEED_MARK"; cat "$EXTRA"; } >> "$SEED"
    echo "preseed: 已追加 profile 片段到 $SEED"
  fi
fi

# 同步 size（manifest 由 02/03 步骤维护）。
# 约定 = 解包树字节数（du 块计数），不是 squashfs 体积：实测 19.3 原盘 5.34GB / 22.3 原盘
# 8.10GB 都远超各自 squashfs（1.90/2.57GB）且为 4096 整倍数——原厂写的就是树 du。
# 有消费方（如安装器估分区）按树大小口径，写成 squashfs 小值会低估。
SZ=$(du -sB1 work/root | cut -f1)
echo "$SZ" > work/iso/casper/filesystem.size
echo "filesystem.size=$SZ (树du)  squashfs=$(stat -c%s work/iso/casper/filesystem.squashfs)  manifest=$(wc -l < work/iso/casper/filesystem.manifest)"

ARGS=(-r -V "$VOLID" -J -joliet-long -iso-level 3 -cache-inodes
      -isohybrid-mbr ../isohdpfx.bin)
if [ -n "$EFI_IMG" ]; then
  ARGS+=(-isohybrid-gpt-basdat -isohybrid-apm-hfsplus)
fi
ARGS+=(-c "$CATALOG" -b "$BIOS_IMG" -no-emul-boot -boot-load-size 4 -boot-info-table)
if [ -n "$EFI_IMG" ]; then
  ARGS+=(-eltorito-alt-boot -e "$EFI_IMG" -no-emul-boot -partition_offset 16)
fi
ARGS+=(-o "../$(basename "$OUT_ISO")" .)

cd work/iso
xorriso -as mkisofs "${ARGS[@]}"
cd ../..
ls -la "$OUT_ISO"
echo "=== 验证引导 ==="
xorriso -indev "$OUT_ISO" -report_el_torito plain 2>/dev/null | grep -E 'catalog|boot img' || true
xorriso -indev "$OUT_ISO" -report_system_area plain 2>/dev/null | grep 'System area summary' || true
