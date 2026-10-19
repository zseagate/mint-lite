#!/bin/bash
# 02-slim.sh: 按 profile 的 remove-packages.txt 删包（dpkg 手术）+ 文件级清理
# rootless 三个铁律（血泪见 AGENTS.md）：
#   1. 必须 dpkg --root=<abs root>——只给 --admindir 时文件删除仍走宿主绝对路径
#      （实测 purge 报"无法移除 /usr/lib/libreoffice/... 权限不够"；有 root 就会删宿主文件，
#       且 work/root 里的文件从未被删 = 假瘦身）
#   2. 维护脚本在删包前就换 exit-0 存根（脚本写宿主绝对路径，rootless 必失败留 half-*；
#      --no-triggers 防触发器把 man-db/mime-support 等保留包连坐成 half-configured）
#   3. 终审计三件套：状态（清单包全消失、零 half-*）+ 文件（被删包 .list 快照全消失）+ manifest
# 用法：PROFILE=yyy ./scripts/02-slim.sh
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
R=work/root
[ -d "$R" ] || { echo "先跑 01-unpack.sh"; exit 1; }
RABS="$PWD/$R"
INFO="$R/var/lib/dpkg/info"
DPKG=(dpkg --root="$RABS" --admindir="$RABS/var/lib/dpkg" --force-all --no-triggers)
SNAP=/tmp/opencode/02-lists
mkdir -p "$R/var/log"

pkg_state() { dpkg-query --admindir="$R/var/lib/dpkg" -W -f='${Status}' "$1" 2>/dev/null || true; }
# 等同"已消失"：无条目，或 available 幽灵（purge 后 dpkg 在 available 留元数据，
# 按名查询打印 unknown ok not-installed；无名枚举不含它——行为差异勿误判为失败）
state_gone() {
  case "$1" in
    ""|"unknown ok not-installed"|"purge ok not-installed") return 0 ;;
    *) return 1 ;;
  esac
}

# 维护脚本换存根（原脚本备份 *.rootless-bak；存根随 purge 一起消失）
neuter() {
  local s
  for s in preinst postinst prerm postrm; do
    if [ -f "$INFO/$1.$s" ] && [ ! -f "$INFO/$1.$s.rootless-bak" ]; then
      mv -f "$INFO/$1.$s" "$INFO/$1.$s.rootless-bak"
    fi
    [ -f "$INFO/$1.$s" ] || { printf '#!/bin/sh\nexit 0\n' > "$INFO/$1.$s"; chmod 755 "$INFO/$1.$s"; }
  done
}

REMOVE_LIST="$(profile_file remove-packages.txt)"
rm -rf "$SNAP"; mkdir -p "$SNAP"

echo "[1/3] dpkg 删除（--root 前缀；先存根脚本 -> -r -> 残留则 --purge -> 核验消失）..."
fail=0
while read -r pkg; do
  st="$(pkg_state "$pkg")"
  state_gone "$st" && continue
  echo "  remove $pkg ($st)"
  # 快照本包文件清单（purge 后 .list 消失）；只存普通文件/软链——目录不作物证
  if [ -f "$INFO/$pkg.list" ]; then
    while IFS= read -r p; do
      p="${p#./}"
      case "$p" in
        /*) if [ -f "$R$p" ] || [ -L "$R$p" ]; then printf '%s\n' "$p"; fi ;;
      esac
    done < "$INFO/$pkg.list" > "$SNAP/$pkg.list"
  fi
  neuter "$pkg"
  "${DPKG[@]}" -r "$pkg" >/dev/null 2>&1 || true
  st="$(pkg_state "$pkg")"
  if ! state_gone "$st"; then
    "${DPKG[@]}" --purge "$pkg" >/dev/null 2>&1 || true
    st="$(pkg_state "$pkg")"
  fi
  if ! state_gone "$st"; then
    echo "  !! 删除失败: $pkg -> $st"
    fail=1
  fi
done < <(grep -vE '^\s*(#|$)' "$REMOVE_LIST")
[ "$fail" = 0 ] || { echo "中止：有包删不干净"; exit 1; }

echo "[1b/3] 修复被连坐的保留包（half-* 且不在清单内）..."
mapfile -t BROKEN < <(dpkg-query --admindir="$R/var/lib/dpkg" -W -f='${Package}\t${Status}\n' 2>/dev/null \
  | awk -F'\t' '$2 ~ /half-/ {print $1}')
if [ "${#BROKEN[@]}" -gt 0 ]; then
  SHIM=/tmp/opencode/dpkg-shim
  mkdir -p "$SHIM"
  # 这些命令只写宿主绝对路径或已删目录，rootless 一律 no-op（目标库刷新在后面单独做）
  for c in update-man-db mandb update-mime-database update-desktop-database \
           update-icon-caches update-menus; do
    printf '#!/bin/sh\nexit 0\n' > "$SHIM/$c"; chmod 755 "$SHIM/$c"
  done
  echo "  修复: ${BROKEN[*]}"
  PATH="$SHIM:$PATH" "${DPKG[@]}" --configure --force-all "${BROKEN[@]}" >/dev/null 2>&1 || true
fi

echo "[2/3] 文件级清理（doc/man/help/非zh-en locale/apt lists）..."
rm -rf "$R/usr/share/doc"/* "$R/usr/share/man"/* "$R/usr/share/help"/*
find "$R/usr/share/locale" -mindepth 1 -maxdepth 1 -type d ! -name 'zh*' ! -name 'en*' -exec rm -rf {} + 2>/dev/null || true
rm -rf "$R/var/lib/apt/lists"/* 2>/dev/null || true
# 目标库刷新（宿主 amd64 工具 + 目标路径，rootless）：清掉悬空 desktop/mime 条目
if command -v update-desktop-database >/dev/null; then
  update-desktop-database "$R/usr/share/applications" 2>/dev/null || true
fi
if command -v update-mime-database >/dev/null; then
  update-mime-database "$R/usr/share/mime" 2>/dev/null || true
fi

echo "[3/3] 终审计（状态 + 文件物证）+ 同步 manifest..."
# 3a. 清单包必须全消失
dirty=""
while read -r pkg; do
  st="$(pkg_state "$pkg")"
  if ! state_gone "$st"; then
    dirty="$dirty $pkg($st)"
  fi
done < <(grep -vE '^\s*(#|$)' "$REMOVE_LIST")
# 3b. 全库零 half-*
half="$(dpkg-query --admindir="$R/var/lib/dpkg" -W -f='${Package}\t${Status}\n' 2>/dev/null \
  | awk -F'\t' '$2 ~ /half-/ {print $1"("$2")"}' | tr '\n' ' ')"
# 3c. 文件物证：本 run 被删包快照里的每个文件必须不存在（--root 生效的铁证）
if ! python3 - <<'PYEOF'
import glob, os, sys
snap, root = "/tmp/opencode/02-lists", "work/root"
total, bad = 0, []
for f in glob.glob(snap + "/*.list"):
    for line in open(f, errors="replace"):
        p = line.strip()
        if not p:
            continue
        total += 1
        if os.path.lexists(root + p):
            bad.append(p)
if bad:
    print("删包后仍存在 %d/%d 个快照文件:" % (len(bad), total))
    for p in bad[:8]:
        print("  " + p)
    sys.exit(1)
print("文件物证: 本 run 快照 %d 个被删文件全部消失" % total if total else "文件物证: 本 run 无删包，跳过")
PYEOF
then
  echo "!! 文件级审计失败（--root 没生效？）"
  exit 1
fi
if [ -n "$dirty$half" ]; then
  echo "!! 状态审计失败：清单残留=[$dirty] 库内残骸=[$half]"
  exit 1
fi
total=$(dpkg-query --admindir="$R/var/lib/dpkg" -W -f='.\n' 2>/dev/null | wc -l)
write_manifest work/iso/casper/filesystem.manifest
echo "审计通过：库内 $total 条目全部 installed；manifest=$(wc -l < work/iso/casper/filesystem.manifest)"
echo OK
