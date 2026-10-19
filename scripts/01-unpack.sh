#!/bin/bash
# 01-unpack.sh: 从原 ISO 解出 work/root + work/iso（rootless）
# 用法：SRC_ISO=xxx.iso PROFILE=yyy ARCH=amd64 ./scripts/01-unpack.sh
# 附带生成 work/perms.txt（原始 setuid/setgid 表，供 06-repack.sh 回放）
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

[ -z "$SRC_ISO" ] && SRC_ISO="$(default_src_iso)"
[ -f "$SRC_ISO" ] || { echo "找不到 $SRC_ISO"; exit 1; }
command -v xorriso >/dev/null || { echo "缺 xorriso"; exit 1; }
command -v unsquashfs >/dev/null || { echo "缺 squashfs-tools"; exit 1; }

echo "[1/5] 校验 sha256..."
EXPECT="$(profile_conf ISO_SHA256 "")"
if [ -n "$EXPECT" ]; then
  GOT="$(sha256sum "$SRC_ISO" | cut -d' ' -f1)"
  [ "$GOT" = "$EXPECT" ] || { echo "sha 不匹配: $GOT"; exit 1; }
  echo "  sha OK"
else
  echo "  (profile 无 ISO_SHA256，跳过)"
fi
sha256sum "$SRC_ISO" > work/original.sha256

echo "[2/5] 提取 MBR 模板..."
mkdir -p work
dd if="$SRC_ISO" of=work/isohdpfx.bin bs=1 count=512 status=none

echo "[3/5] 提取 ISO 树（整树 /，单文件 -extract 在此镜像上失败）..."
rm -rf work/iso
# 用 xorriso osirrox 整树取出（保留权限；之后 chmod u+w）
xorriso -indev "$SRC_ISO" -osirrox on -extract / work/iso 2>&1 | tail -2
chmod -R u+w work/iso/
chmod 644 work/iso/casper/filesystem.squashfs 2>/dev/null || true

echo "[4/5] 解包 squashfs（rootless：device 节点 / security xattr 报错属预期，见 AGENTS.md）..."
rm -rf work/root
if ! unsquashfs -d work/root work/iso/casper/filesystem.squashfs; then
  echo "  (unsquashfs 非零退出：rootless 建不了 device/xattr——/dev 开机由 udev 重建，继续)"
fi
if ! { [ -d work/root/etc ] && [ -d work/root/usr ] && [ -d work/root/var/lib/dpkg ]; }; then
  echo "解包不完整，中止"; exit 1
fi

echo "[5/5] 记录原始 setuid/setgid 表（解包会丢 s 位，必须从 squashfs 元数据取）..."
python3 - work/iso/casper/filesystem.squashfs work/perms.txt <<'PY'
import subprocess, sys, re
sq, out = sys.argv[1], sys.argv[2]
p = subprocess.run(["unsquashfs", "-ll", sq], capture_output=True, text=True)
n = 0
with open(out, "w") as f:
    for line in p.stdout.splitlines():
        # 形如：-rwsr-xr-x root/root  1234 2024-01-01 00:00 squashfs-root/usr/bin/su
        m = re.match(r"^(\S+)\s+(\S+)\s+\d+\s+\S+\s+\S+\s+(.*)$", line)
        if not m:
            continue
        mode, owner, path = m.groups()
        if len(mode) < 10 or mode[0] == "d" or ("s" not in mode[3] + mode[6]):
            continue
        user, group = (owner.split("/") + ["root"])[:2]
        rel = path.split("/", 1)[1] if "/" in path else path  # 去掉 squashfs-root/
        # 八进制 mode：第 4/7 位是 s/S → 4/2 开头
        suid = mode[3] in "sS"
        sgid = mode[6] in "sS"
        # 八进制 mode：suid->4xxx, sgid->2xxx，其余 rwx 直接翻译
        def tri(t):
            v = 0
            if t[0] == "r": v += 4
            if t[1] == "w": v += 2
            if t[2] in "xst": v += 1
            return str(v)
        octal = str((4 if suid else 0) + (2 if sgid else 0)) + tri(mode[1:4]) + tri(mode[4:7]) + tri(mode[7:10])
        f.write(f"{user}:{group}:{octal}:{rel}\n")
        n += 1
print(f"perms: {n}")
PY

echo "[校验]"
ls work/root/etc/lsb-release work/iso/casper/filesystem.squashfs work/isohdpfx.bin work/perms.txt
echo "OK: work/root + work/iso 就绪"
