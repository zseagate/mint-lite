#!/bin/bash
# lib.sh: 通用构建库（被 01-07 脚本 source，不要直接执行）
# 环境变量（都可覆盖，都有默认值）：
#   SRC_ISO  原 ISO 路径（默认按 PROFILE 猜）
#   PROFILE  profile 名（默认 mint-22.3-xfce）
#   ARCH     目标架构（默认取 profile.conf 的 ARCH，如 i386；再回退宿主 dpkg 架构）

PROFILE="${PROFILE:-mint-22.3-xfce}"
PROFDIR="config/profiles/$PROFILE"
# ARCH 优先 profile.conf（19.3 是 i386——用宿主 amd64 会静默搞错 multiarch 库路径与 apt 解析）
CONF_ARCH=""
[ -f "$PROFDIR/profile.conf" ] && CONF_ARCH="$(grep -E '^ARCH=' "$PROFDIR/profile.conf" | tail -1 | cut -d= -f2-)"
ARCH="${ARCH:-${CONF_ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}}"
SRC_ISO="${SRC_ISO:-}"
OUT_ISO="${OUT_ISO:-}"   # 空则由 07 按 profile 的 OUT_FILENAME 决定

# 无系统级 xorriso 时自动用 rootless shim（work/xorriso-local，重建方法见 AGENTS）
# ——01/07 在 source 本文件后立刻 `command -v xorriso` 检查，必须先挂 PATH。
if ! command -v xorriso >/dev/null 2>&1 && [ -x work/xorriso-local/bin/xorriso ]; then
  PATH="$PWD/work/xorriso-local/bin:$PATH"
  export PATH
fi

# multiarch 库目录（amd64/i386/...）
multiarch_libdir() {
  case "$ARCH" in
    amd64) echo "x86_64-linux-gnu" ;;
    i386)  echo "i386-linux-gnu" ;;
    arm64) echo "aarch64-linux-gnu" ;;
    *)     echo "${ARCH}-linux-gnu" ;;
  esac
}

# profile 文件解析（兼容旧版顶层 config/*.txt，无则报错）
# 用法：profile_file remove-packages.txt
profile_file() {
  if [ -e "$PROFDIR/$1" ]; then echo "$PROFDIR/$1";
  elif [ -e "config/$1" ]; then echo "config/$1";
  else echo "找不到 $PROFDIR/$1" >&2; return 1; fi
}

# profile.conf 键值读取（无文件则回退到默认值）
# 用法：profile_conf VOLUME_ID "Linux Mint 22.3 Xfce 64-bit"
profile_conf() {
  local key="$1" default="$2" val=""
  [ -f "$PROFDIR/profile.conf" ] && \
    val="$(grep -E "^${key}=" "$PROFDIR/profile.conf" | tail -1 | cut -d= -f2-)"
  echo "${val:-$default}"
}

# 默认 SRC_ISO：profile.conf 的 ISO_FILENAME，找不到则报错提示
default_src_iso() {
  local f; f="$(profile_conf ISO_FILENAME "")"
  if [ -n "$f" ] && [ -f "$f" ]; then echo "$f"; return 0; fi
  echo "找不到原 ISO：设置 SRC_ISO=... 或把 ISO 放到 $f" >&2
  return 1
}

# 生成 casper/filesystem.manifest——原厂命名口径：Multi-Arch: same 的包加 ":arch"
# 限定，其余裸名（= bionic 时代 dpkg 的 ${binary:Package} 规则，实测原盘 763 行限定
# 全部 Multi-Arch: same）。宿主 noble dpkg 的 ${binary:Package} 会给所有外来架构包
# 加限定（多 ~630 行），manifest-remove 的 15 个精确匹配会丢 4 个（装完盘
# ubiquity/gparted 等清不掉）——所以禁用 ${binary:Package}，按 MA 字段手写。
# 依赖调用方的 $R（目标根绝对路径）。
# 用法：write_manifest work/iso/casper/filesystem.manifest
write_manifest() {
  dpkg-query --admindir="$R/var/lib/dpkg" -W \
    -f='${Package}\t${Version}\t${Architecture}\t${Multi-Arch}\n' 2>/dev/null |
  awk -F'\t' '{
    if ($4 == "same") printf "%s:%s\t%s\n", $1, $3, $2;
    else              printf "%s\t%s\n", $1, $2;
  }' > "$1"
}

# 刷新目标树的 fontconfig 系统缓存（$R/var/cache/fontconfig）。
# 必要性：02/03/04 增删字体包或加 fontconfig 配置后，原 ISO 自带的缓存条目失效。
# live 首次登录（新家目录、无用户缓存）时 fontconfig 会重建缓存——实测在 zh_CN +
# 本盘字体组合下，xfwm4/xfce4-panel/xfdesktop/fcitx/xfsettingsd 会在 FreeType 里
# 死循环（首会话黑屏），二会话/home 缓存存在后才正常。预生成有效系统缓存、
# 让 live 直接命中即可，冷启动实测恢复。细节见 AGENTS.md「fontconfig 系统缓存」。
# 实现：宿主不能直接跑目标 fc-cache（绝对字体路径会指到宿主的 /usr/share/fonts），
# 用 bwrap + userns 做 rootless "chroot"（$R 当根），目标 fc-cache 就会按镜像内
# 路径扫描并写回镜像内的 /var/cache/fontconfig。HOME 放 tmpfs 以免污染 $R。
# 依赖调用方已设好 $R 与 $ARCH（lib.sh 顶部）。跨架构用镜像自带 loader 加载。
refresh_fontconfig_cache() {
  local R="${R:-work/root}" RABS LIB hostarch
  local -a loader=()
  [ -x "$R/usr/bin/fc-cache" ] || { echo "  (无 $R/usr/bin/fc-cache，跳过 fontconfig 缓存刷新)"; return 0; }
  if ! command -v bwrap >/dev/null 2>&1; then
    echo "!! 无 bwrap：跳过 fontconfig 系统缓存刷新（live 首登可能黑屏，见 AGENTS.md）" >&2
    return 0
  fi
  RABS="$(cd "$R" && pwd)"
  LIB="$(multiarch_libdir)"
  hostarch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  if [ "$ARCH" != "$hostarch" ] && [ -x "$R/lib/ld-linux.so.2" ]; then
    loader=(/lib/ld-linux.so.2 --library-path "/lib/$LIB:/usr/lib/$LIB")
  elif [ -x "$R/lib64/ld-linux-x86-64.so.2" ]; then
    loader=(/lib64/ld-linux-x86-64.so.2 --library-path "/lib/$LIB:/usr/lib/$LIB")
  fi
  mkdir -p "$R/var/cache/fontconfig"
  echo "  刷新 $R/var/cache/fontconfig ..."
  bwrap --bind "$RABS" / --dev /dev --proc /proc --tmpfs /tmp \
        --setenv HOME /tmp --setenv LANG C --setenv PATH /usr/bin:/bin \
        "${loader[@]}" /usr/bin/fc-cache -f || { echo "!! fc-cache 失败" >&2; return 1; }
  local n; n="$(find "$R/var/cache/fontconfig" -name '*.cache-7' 2>/dev/null | wc -l)"
  echo "  完成：$n 个 .cache-7 条目"
  [ "$n" -ge 1 ] || { echo "!! fontconfig 缓存为空" >&2; return 1; }
}
