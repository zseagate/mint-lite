#!/bin/bash
# 05-apply-assets.sh: 壁纸 + 开始菜单 logo + 面板/壁纸的系统级 xfconf 默认值（幂等，可反复跑）
# 换皮肤：替换 assets/wallpaper.png / assets/menu-logo.png 后重跑本脚本，
# 再跑 06-repack.sh + 07-build-iso.sh 即可出新 ISO。
set -euo pipefail
cd "$(dirname "$0")/.."
R=work/root
[ -d "$R" ] || { echo "先跑 01-unpack.sh"; exit 1; }
MENU_ICON=/usr/share/pixmaps/mint-lite-menu.png

# 1. 壁纸：原位覆盖 xfce4-desktop.xml 指向的 linuxmint.jpg
#    （gdk-pixbuf 按内容识别格式，PNG 数据放 .jpg 路径可正常加载）
if [ -f assets/wallpaper.png ]; then
  cp assets/wallpaper.png "$R/usr/share/xfce4/backdrops/linuxmint.jpg"
  chmod 644 "$R/usr/share/xfce4/backdrops/linuxmint.jpg"
  echo "wallpaper -> usr/share/xfce4/backdrops/linuxmint.jpg"
fi

# 2. 开始菜单 logo 文件
if [ -f assets/menu-logo.png ]; then
  cp assets/menu-logo.png "$R$MENU_ICON"
  chmod 644 "$R$MENU_ICON"
  echo "menu logo -> ${MENU_ICON#/}"
fi

# 3. 面板 + 壁纸的系统级 xfconf 默认值（关键，勿删）
#    Mint 把默认面板（底部 whiskermenu，position=p=10）与壁纸放在
#    /usr/share/mint-artwork/xfce/，经软链 /etc/xdg/xdg-xfce + 环境变量
#    XDG_CONFIG_DIRS=/etc/xdg/xdg-xfce:/etc/xdg 生效（Xsession.d 的
#    60x11-common_xdg_path 设置）。精简盘实测该变量未含 xdg-xfce 时：
#      xfce4-panel 的 xfconf channel 为空 → 启动时跑 migrate helper →
#      用上游 /etc/xdg/xfce4/panel/default.xml 初始化（p=6=顶部 +
#      applicationsmenu），同时 xfdesktop 无壁纸。
#    这里把 overlay 的权威默认值同时复制到 /etc/xdg/xfce4/（/etc/xdg 始终在
#    XDG_CONFIG_DIRS 中），不再依赖该环境变量，两种情况都得到 Mint 的
#    底部面板与壁纸。
ART="$R/usr/share/mint-artwork/xfce"
SRCXML="$ART/xfce4/xfconf/xfce-perchannel-xml"
DSTXML="$R/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
if [ -d "$SRCXML" ]; then
  mkdir -p "$DSTXML"
  for f in xfce4-panel.xml xfce4-desktop.xml; do
    [ -f "$SRCXML/$f" ] || continue
    cp "$SRCXML/$f" "$DSTXML/$f"
    echo "系统默认 -> etc/xdg/xfce4/xfconf/xfce-perchannel-xml/$f"
  done
fi

# 4. 菜单图标：whiskermenu 用独立 rc 文件（overlay 与 /etc/xdg 两处都设，
#    避免 XDG_CONFIG_DIRS 优先级带来的歧义）
if [ ! -f "$R/etc/xdg/xfce4/panel/whiskermenu-1.rc" ] && [ -f "$ART/xfce4/panel/whiskermenu-1.rc" ]; then
  mkdir -p "$R/etc/xdg/xfce4/panel"
  cp "$ART/xfce4/panel/whiskermenu-1.rc" "$R/etc/xdg/xfce4/panel/whiskermenu-1.rc"
fi
for rc in "$ART/xfce4/panel/whiskermenu-1.rc" "$R/etc/xdg/xfce4/panel/whiskermenu-1.rc"; do
  [ -f "$rc" ] || continue
  if grep -q '^button-icon=' "$rc"; then
    sed -i "s#^button-icon=.*#button-icon=$MENU_ICON#" "$rc"
  else
    printf 'button-icon=%s\n' "$MENU_ICON" >> "$rc"
  fi
  echo "whiskermenu 图标 -> ${rc#"$R"/}"
done

# 5. 兜底：上游 default.xml 的 applicationsmenu 图标（万一仍走 migrate 也用我们的 logo）
if [ -f "$R/etc/xdg/xfce4/panel/default.xml" ]; then
python3 - <<'PY'
import xml.dom.minidom
p = "work/root/etc/xdg/xfce4/panel/default.xml"
doc = xml.dom.minidom.parse(p)
changed = False
for prop in doc.getElementsByTagName("property"):
    if prop.getAttribute("name") == "plugin-1" and prop.getAttribute("value") == "applicationsmenu":
        # 已有则更新，没有则加
        for child in prop.childNodes:
            if getattr(child, "getAttribute", lambda a: "")("name") == "button-icon":
                child.setAttribute("value", "/usr/share/pixmaps/mint-lite-menu.png")
                changed = True
                break
        else:
            el = doc.createElement("property")
            el.setAttribute("name", "button-icon")
            el.setAttribute("type", "string")
            el.setAttribute("value", "/usr/share/pixmaps/mint-lite-menu.png")
            prop.appendChild(el)
            changed = True
if changed:
    with open(p, "w") as f:
        doc.writexml(f)
    print("panel default.xml: button-icon 已设置")
else:
    print("panel default.xml: 未找到 plugin-1（跳过）")
PY
else
  echo "panel default.xml 不存在（跳过 button-icon）"
fi
echo OK
