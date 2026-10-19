#!/bin/bash
# 04-configure.sh: 中文化 + skel + 输入法（IM=fcitx/fcitx5 由 profile.conf 的 IM 键决定）+ autostart
# 幂等，可反复跑。
# i386 目标：GTK immodules.cache 重建要用镜像自己的 ld-linux.so.2 跑 i386 的 gtk-query
# （宿主 amd64 直接 exec 会因缺 32 位解释器失败；见 AGENTS.md）。
# 用法：PROFILE=yyy ./scripts/04-configure.sh
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
R=work/root
LIB="$(multiarch_libdir)"
IM="$(profile_conf IM fcitx5)"
HOST_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
[ -d "$R" ] || { echo "先跑 01-unpack.sh"; exit 1; }

echo "[1/7] locale 三件套..."
echo 'LANG=zh_CN.UTF-8' > "$R/etc/default/locale"
sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' "$R/etc/locale.gen" 2>/dev/null || \
  grep -q zh_CN "$R/etc/locale.gen" || echo "zh_CN.UTF-8 UTF-8" >> "$R/etc/locale.gen"
if [ ! -d "$R/usr/lib/locale/zh_CN.utf8" ]; then
  (cd "$R" && localedef --prefix="$PWD" --no-archive -i zh_CN -f UTF-8 zh_CN.UTF-8 2>/dev/null) || \
    echo "  (localedef 跳过，live 内已生成则无妨)"
fi

echo "[2/7] user-dirs：小写 enabled=False（大写是 no-op，见 AGENTS.md）..."
printf '[Settings]\nenabled=False\n' > "$R/etc/xdg/user-dirs.conf"

echo "[3/7] skel 同步（$PROFILE skel/ -> root/etc/skel，含英文目录/$IM profile/.xinputrc）..."
SKEL="$(profile_file skel)"
mkdir -p "$R/etc/skel"
cp -a "$SKEL/." "$R/etc/skel/"
for d in Desktop Documents Downloads Music Pictures Public Templates Videos; do
  mkdir -p "$R/etc/skel/$d"
done

echo "[4/7] GTK immodules.cache 重建（gtk3 + gtk2，必须含 $IM，否则 GUI 打不了字）..."
export LD_LIBRARY_PATH="$R/usr/lib/$LIB:$R/lib/$LIB"
# 跨架构执行：用镜像自带 loader 加载目标二进制（同架构则直接跑，22.3 老路径不变）
run_target() {
  local bin="$1"; shift
  if [ "$ARCH" != "$HOST_ARCH" ] && [ -x "$R/lib/ld-linux.so.2" ]; then
    "$R/lib/ld-linux.so.2" --library-path "$LD_LIBRARY_PATH" "$bin" "$@"
  else
    "$bin" "$@"
  fi
}
im_cache() {  # $1=query二进制glob  $2=immodules目录  $3=cache路径  $4=标签
  local q imdir cache label n
  q="$(compgen -G "$1" | head -1 || true)"
  imdir="$2"; cache="$3"; label="$4"
  if [ -z "$q" ]; then echo "!! $label: 找不到 gtk-query，cache 无法重建"; return 1; fi
  if ! ls "$imdir"/*.so >/dev/null 2>&1; then echo "!! $label: immodules 目录无 .so"; return 1; fi
  # gtk-query 可能把参数 realpath 绝对化：先剥 $PWD/$R（绝对输出），再剥相对 $R
  run_target "$q" "$imdir"/*.so 2>/dev/null | sed -e "s#$PWD/$R##g" -e "s#$R##g" > "$cache"
  if grep -qF "$PWD" "$cache"; then echo "!! $label cache 残留构建机路径（sed 漏网）"; return 1; fi
  n="$(grep -c "$IM" "$cache" || true)"
  echo "  $label cache: $IM 条目 $n"
  [ "$n" -ge 1 ] || { echo "!! $label immodules.cache 无 $IM（该套 GUI 将打不了字）"; return 1; }
}
im_cache "$R/usr/lib/$LIB/libgtk-3-0*/gtk-query-immodules-3.0" \
         "$R/usr/lib/$LIB/gtk-3.0/3.0.0/immodules" \
         "$R/usr/lib/$LIB/gtk-3.0/3.0.0/immodules.cache" "gtk3"
im_cache "$R/usr/lib/$LIB/libgtk2.0-0*/gtk-query-immodules-2.0" \
         "$R/usr/lib/$LIB/gtk-2.0/2.10.0/immodules" \
         "$R/usr/lib/$LIB/gtk-2.0/2.10.0/immodules.cache" "gtk2"

echo "[5/7] $IM autostart 兜底（+ skel .xinputrc + im-config 链 三保险）..."
case "$IM" in
  fcitx)  IMNAME=Fcitx ;;
  fcitx5) IMNAME="Fcitx 5" ;;
  *)      IMNAME="$IM" ;;
esac
rm -f "$R/etc/xdg/autostart/fcitx.desktop" "$R/etc/xdg/autostart/fcitx5.desktop"
cat > "$R/etc/xdg/autostart/$IM.desktop" <<EOF
[Desktop Entry]
Name=$IMNAME
Comment=Input Method
Exec=$IM -d
Terminal=false
Type=Application
Categories=System;
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

# 5b. IM 环境变量兜底 + 系统级 im-config 选择
#     精简盘实测：某些 live 会话里 Xsession.d 的 im-config 链没有生效，导致
#     GTK_IM_MODULE/XMODIFIERS 为空（表现：应用里打不了字）。im-config 在选择
#     输入法时会用 $HOME/.xinputrc，否则回退到系统 /etc/X11/xinit/xinputrc
#     （原盘是 run_im default）。这里把系统级选择也设为 $IM，并在 Xfce 会话入口
#     /etc/xdg/xfce4/xinitrc 里显式 export（该文件在 startxfce4 里、xfce4-session
#     启动前执行，无论走不走 im-config/im-launch 都会跑到，且不会反过来禁用
#     im-config —— im-config 在 Xsession.d 里更早执行）。fcitx 本身由上面的
#     autostart 兜底拉起。
case "$IM" in
  fcitx5) IMMOD=fcitx ;;   # fcitx5 仍注册为 "fcitx" 模块名
  *)      IMMOD="$IM" ;;
esac
if [ -d "$R/etc/X11/xinit" ]; then
  printf 'run_im %s\n' "$IM" > "$R/etc/X11/xinit/xinputrc"
  echo "  /etc/X11/xinit/xinputrc: run_im $IM"
fi
XINITRC="$R/etc/xdg/xfce4/xinitrc"
if [ -f "$XINITRC" ]; then
python3 - "$XINITRC" "$IMMOD" <<'PY'
import sys
p, immod = sys.argv[1], sys.argv[2]
s = open(p).read()
mark = "# mint-lite IM env"
if mark in s:
    print("  xinitrc: IM env 已存在（幂等）")
else:
    block = (
        mark + "（兜底：即使 im-config/Xsession.d 没生效也能打字）\n"
        "export GTK_IM_MODULE=%s\n"
        "export QT_IM_MODULE=%s\n"
        "export XMODIFIERS=@im=%s\n" % (immod, immod, immod)
    )
    out, inserted = [], False
    for ln in s.splitlines(keepends=True):
        if not inserted and ln.strip() == "exec xfce4-session":
            out.append(block)
            inserted = True
        out.append(ln)
    if not inserted:
        out.append("\n" + block)
    open(p, "w").write("".join(out))
    print("  xinitrc: IM env 已插入" if inserted else "  xinitrc: IM env 追加（注意：未找到 exec xfce4-session）")
PY
else
  echo "  (无 /etc/xdg/xfce4/xinitrc，跳过 IM env 兜底)"
fi

echo "[6/7] 镜像源（profile 自带源列表）..."
SRCLIST=""
if [ -e "$PROFDIR/official-package-repositories.list" ]; then
  SRCLIST="$PROFDIR/official-package-repositories.list"
fi
if [ -n "$SRCLIST" ]; then
  cp "$SRCLIST" "$R/etc/apt/sources.list.d/official-package-repositories.list"
  chmod 644 "$R/etc/apt/sources.list.d/official-package-repositories.list"
else
  echo "  (profile 无源列表，保留原 ISO 源)"
fi

echo "[7/7] gschemas 重编..."
/usr/bin/glib-compile-schemas "$R/usr/share/glib-2.0/schemas/" 2>/dev/null || true
echo OK
