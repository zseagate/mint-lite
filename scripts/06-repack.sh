#!/bin/bash
# shellcheck disable=SC2016  # 下面 fakeroot bash -c 的单引号拼接是故意的：变量留给子 shell 展开
# 06-repack.sh: fakeroot 重打 squashfs（setuid/setgid 精确恢复，不用 -all-root）
# -all-root 会保留 setuid 位但破坏 setgid 属组（unix_chkpwd 变 root:root → sudo 密码失效）
# 权限来源：work/perms.txt（01-unpack.sh 从原 squashfs 元数据生成，格式 user:group:oct:relpath）；
# 无 perms.txt 时回退到内置表（Mint 22.3，如需 THAT 才用）。
# 用法：PROFILE=yyy ./scripts/06-repack.sh
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
R=work/root
OUT=work/iso/casper/filesystem.squashfs
[ -d "$R" ] || { echo "先跑 01-unpack.sh"; exit 1; }

# 打 squashfs 前刷新 fontconfig 系统缓存（必须晚于所有字体/配置改动；
# 不刷新则 live 首登黑屏，见 lib.sh refresh_fontconfig_cache 与 AGENTS.md）。
echo "[0/3] 刷新 fontconfig 系统缓存..."
refresh_fontconfig_cache

CMDS=""
if [ -f work/perms.txt ]; then
  echo "用 work/perms.txt 回放 ($(wc -l < work/perms.txt) 条)..."
  while IFS=: read -r user group oct rel; do
    [ -n "${rel:-}" ] || continue
    CMDS+="chown $user:$group \"\$R/$rel\";chmod $oct \"\$R/$rel\";"
  done < work/perms.txt
else
  echo "无 work/perms.txt，用内置表（先跑 01-unpack.sh 重新生成才是正道）..."
  # 内置回退表：Mint 22.3 Xfce（setgid 文件 -> 属组）
  declare -A SETGID=(
    ["usr/bin/chage"]="shadow" ["usr/bin/expiry"]="shadow"
    ["usr/bin/crontab"]="crontab" ["usr/bin/plocate"]="plocate"
    ["usr/bin/ssh-agent"]="_ssh" ["usr/libexec/camel-lock-helper-1.2"]="mail"
    ["usr/lib/x86_64-linux-gnu/utempter/utempter"]="utmp"
    ["usr/sbin/pam_extrausers_chkpwd"]="shadow" ["usr/sbin/unix_chkpwd"]="shadow"
    ["usr/lib/xorg/Xorg.wrap"]="root"
  )
  SETUID=(
    usr/lib/dbus-1.0/dbus-daemon-launch-helper usr/sbin/pppd
    usr/bin/chfn usr/bin/chsh usr/bin/fusermount3 usr/bin/gpasswd
    usr/bin/mount usr/bin/newgrp usr/bin/passwd usr/bin/pkexec
    usr/bin/su usr/bin/sudo usr/bin/umount usr/lib/openssh/ssh-keysign
    usr/lib/polkit-1/polkit-agent-helper-1 usr/sbin/mount.cifs
    usr/sbin/mount.ecryptfs_private usr/lib/xorg/Xorg.wrap
  )
  for p in "${!SETGID[@]}"; do CMDS+="chown root:${SETGID[$p]} \"\$R/$p\";"; done
  for p in "${SETUID[@]}"; do CMDS+="chmod 4755 \"\$R/$p\";"; done
  for p in "${!SETGID[@]}"; do
    if [ "$p" = "usr/lib/xorg/Xorg.wrap" ]; then CMDS+="chmod 6755 \"\$R/$p\";"
    else CMDS+="chmod 2755 \"\$R/$p\";"; fi
  done
fi

# 用 declare -p 把数组传进 fakeroot（bash -c 展开）
fakeroot bash -c '
set -euo pipefail
R="'"$R"'"; OUT="'"$OUT"'"
echo "[1/3] chown -R root:root"; chown -R root:root "$R"
echo "[2/3] setuid/setgid"; '"$CMDS"'
echo "[3/3] mksquashfs (xz, ~6min)"; rm -f "$OUT"
mksquashfs "$R" "$OUT" -comp xz -b 128K -noappend
'
echo "DONE: $(stat -c%s "$OUT") bytes"
