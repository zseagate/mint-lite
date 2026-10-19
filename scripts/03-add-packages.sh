#!/bin/bash
# 03-add-packages.sh: 按 profile 的 add-packages.txt 下载 deb并落进 root：
#   默认（宿主与目标同版本，如 22.3/noble）：apt download 显式清单——清单即完整闭包。
#   USE_TARGET_SOURCES=1（跨版本，如 19.3/bionic）：apt-get install --download-only，
#     以 work/root 的 status 做依赖解析（镜像已有的不再下），apt 补全闭包 deb。
# 下载后 dpkg-deb -x 进 root + 合并 status + 生成 .list（防"空壳包"，见 AGENTS.md）。
# 已装包被升级（如 firefox）：替换 status 段（保 Status 行）+ 先清旧文件再解包 + 同步 conffiles。
# 架构守卫：deb Architecture 必须 = $ARCH/all（APT::Architecture 没生效会当场报错）。
# 用法：PROFILE=yyy [USE_TARGET_SOURCES=1] ./scripts/03-add-packages.sh
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
export ARCH   # 传给下面 python 的架构守卫
R=work/root
[ -d "$R" ] || { echo "先跑 01-unpack.sh"; exit 1; }
rm -rf tmp-debs tmp-apt
mkdir -p tmp-debs/partial

echo "[1/3] 下载 deb..."
ADDLIST="$(profile_file add-packages.txt)"
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$ADDLIST")
[ "${#PKGS[@]}" -gt 0 ] || { echo "add-packages.txt 为空"; exit 1; }
if [ "${USE_TARGET_SOURCES:-0}" = 1 ]; then
  APTSRC=""
  for c in "$PROFDIR/apt-sources.list" "$PROFDIR/official-package-repositories.list"; do
    [ -f "$c" ] && APTSRC="$c" && break
  done
  [ -n "$APTSRC" ] || { echo "profile 缺 apt 源列表"; exit 1; }
  # 密钥暂存：镜像 trusted.d + usr/share/keyrings 逐个用 gpg 验证，坏文件自动排除
  # （bionic 镜像：mint 签名密钥在 ubuntu-defaults.chroot.key.gpg；linuxmint-keyring.gpg 是坏包）
  KEYDIR=/tmp/opencode/apt-keys
  rm -rf "$KEYDIR"; mkdir -p "$KEYDIR"
  for k in "$R"/etc/apt/trusted.gpg.d/*.gpg "$R"/usr/share/keyrings/*.gpg; do
    [ -f "$k" ] || continue
    gpg --no-default-keyring --keyring "$k" --list-keys >/dev/null 2>&1 && cp "$k" "$KEYDIR/"
  done
  [ -n "$(ls -A "$KEYDIR")" ] || { echo "镜像 keyring 为空或全坏"; exit 1; }
  mkdir -p tmp-apt/lists/partial tmp-apt/state tmp-apt/log tmp-apt/cache/archives/partial
  # 七件套 + 架构 + 密钥 + 日志：Dir:: 全重定向，宿主 status/锁/日志零写入（见 AGENTS.md）
  APT_OPTS=(-o "APT::Architecture=$ARCH"
            -o "APT::Architectures::=$ARCH"
            -o "Dir::Etc::sourcelist=$PWD/$APTSRC"
            -o Dir::Etc::sourceparts=/dev/null
            -o "Dir::Etc::trustedparts=$KEYDIR"
            -o Dir::Etc::trusted=/dev/null
            -o "Dir::State=$PWD/tmp-apt/state"
            -o "Dir::State::lists=$PWD/tmp-apt/lists"
            -o "Dir::State::status=$PWD/$R/var/lib/dpkg/status"
            -o "Dir::Cache=$PWD/tmp-apt/cache"
            -o "Dir::Cache::archives=$PWD/tmp-debs"
            -o "Dir::Log=$PWD/tmp-apt/log"
            -o Acquire::Retries=5
            -o Acquire::http::Timeout=30
            -o Acquire::https::Timeout=30
            -o Debug::NoLocking=1)
  apt-get "${APT_OPTS[@]}" update
  # --download-only：只下载不安装（status 不动）；--no-install-recommends：闭包由清单显式控制；
  # --no-remove：解析计划出现卸载即报错——status 经 02 审计过，不该发生，发生了要看得见
  apt-get "${APT_OPTS[@]}" install -y --download-only \
    --no-install-recommends --no-remove "${PKGS[@]}"
else
  printf '%s\n' "${PKGS[@]}" | (cd tmp-debs && xargs -r apt-get download)
fi
echo "下载 $(find tmp-debs -maxdepth 1 -name '*.deb' | wc -l) 个 deb"

echo "[2/3] 解包 + status/.list..."
python3 - <<'PY'
import subprocess, os, re, glob, shutil, sys
R = "work/root"
ARCH = os.environ["ARCH"]
sp = f"{R}/var/lib/dpkg/status"
segs = [s for s in open(sp).read().split("\n\n") if s.strip()]
by = {}
for i, s in enumerate(segs):
    m = re.search(r"^Package: (\S+)", s, re.M)
    if m:
        by[m.group(1)] = i
print(f"status 现有: {len(segs)}")

def dfields(deb):
    # 逐字段单次调用：单字段=裸值（多字段会输出 "Field: value" 带标签行，勿混用）
    def f(name):
        return subprocess.run(["dpkg-deb", "-f", deb, name],
                              capture_output=True, text=True, check=True).stdout.strip()
    return f("Package"), f("Version"), f("Architecture")

def old_version(seg):
    m = re.search(r"^Version: (\S+)", seg, re.M)
    return m.group(1) if m else ""

for deb in sorted(glob.glob("tmp-debs/*.deb")):
    pkg, ver, arch = dfields(deb)
    if arch not in (ARCH, "all"):
        sys.exit(f"deb 架构不符: {deb} arch={arch} want={ARCH}（APT::Architecture 没生效？）")
    pdir = f"tmp-debs/ctrl-{pkg}"
    os.makedirs(pdir, exist_ok=True)
    # 升级：先按旧 .list 清旧文件（只删普通文件/软链，绝不碰目录），再解新包
    if pkg in by and (ov := old_version(segs[by[pkg]])) and ov != ver:
        oldlist = f"{R}/var/lib/dpkg/info/{pkg}.list"
        if os.path.exists(oldlist):
            for line in open(oldlist, errors="replace"):
                p = line.strip()
                if p.startswith("./"):
                    p = p[1:]
                if not p.startswith("/"):
                    continue
                fp = R + p
                if os.path.islink(fp) or os.path.isfile(fp):
                    try:
                        os.remove(fp)
                    except FileNotFoundError:
                        pass
        print(f"  UPGRADE: {pkg} {ov} -> {ver}")
    subprocess.run(["dpkg-deb", "-x", deb, R], check=True)
    subprocess.run(["dpkg-deb", "-e", deb, pdir], check=True)
    ctrl = open(f"{pdir}/control").read().strip()
    seg = "Status: install ok installed\n" + ctrl
    if pkg in by:
        if (ov := old_version(segs[by[pkg]])) and ov != ver:
            segs[by[pkg]] = seg  # 版本变化：整段换成新 control（保 Status 行）
            print(f"  UPDATE status: {pkg} {ov} -> {ver}")
        # 同版本：原段不动
    else:
        segs.append(seg)
        by[pkg] = len(segs) - 1
        print(f"  ADD status: {pkg} {ver}")
    # conffiles 同步（dpkg 升级/清理要用）
    cf = f"{pdir}/conffiles"
    if os.path.exists(cf):
        shutil.copy(cf, f"{R}/var/lib/dpkg/info/{pkg}.conffiles")
    # .list：dpkg-deb -c 的 ./xxx 字段 -> 绝对路径（与镜像原格式一致：含目录）
    out = subprocess.run(["dpkg-deb", "-c", deb], capture_output=True, text=True).stdout
    paths = ["/" + m.group(1)
             for line in out.splitlines()
             if (m := re.search(r"\s\./(\S+)", line)) and "/" + m.group(1) != "/"]
    open(f"{R}/var/lib/dpkg/info/{pkg}.list", "w").write("\n".join(paths) + "\n")
open(sp, "w").write("\n\n".join(segs) + "\n")
print(f"status 总: {len(segs)}")
PY

echo "[3/3] 同步 manifest..."
write_manifest work/iso/casper/filesystem.manifest
echo "manifest=$(wc -l < work/iso/casper/filesystem.manifest)"
echo OK
