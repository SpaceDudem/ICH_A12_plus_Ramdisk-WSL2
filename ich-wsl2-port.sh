#!/usr/bin/env bash
set -Eeuo pipefail

ICH_REPO='https://github.com/Pa7r0n/ICH_A12_plus_Ramdisk.git'
ICH_COMMIT='b3c2db8d160c94d802393b87d0377f3623fff54b'
ROOT="${ICH_WSL_ROOT:-$HOME/ICH_A12_plus_Ramdisk-wsl2}"
TOOLS="$ROOT/tools/linux"
VENDOR="$ROOT/.wsl-vendor"
VENV="$ROOT/.venv"
STATE="$ROOT/.wsl-port-state"
JOBS="${JOBS:-$(nproc)}"

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    [OK] %s\n' "$*"; }
warn() { printf '    [WARN] %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

on_err() {
    local rc=$?
    printf '\nFAILED at line %s: %s (exit %s)\n' "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" "$rc" >&2
    exit "$rc"
}
trap on_err ERR

usage() {
    cat <<'EOF'
Usage:
  ich-wsl2-port.sh install   Clone/pin ICH v1.2, install Linux tools, apply WSL port
  ich-wsl2-port.sh apfs      Build/load linux-apfs-rw for the running WSL kernel
  ich-wsl2-port.sh usb       Attach the Apple DFU USB device to WSL with usbipd
  ich-wsl2-port.sh status    Verify the port, APFS support, USB, and pwned DFU
  ich-wsl2-port.sh build     Run ICH build.sh after verification
  ich-wsl2-port.sh boot      Run ICH boot.sh after a successful build

Run this script as your normal WSL user. It invokes sudo only for package,
kernel-module, mount, and APFS operations.
EOF
}

require_wsl() {
    grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease || die 'This script must run inside WSL2.'
}

ensure_dir() {
    mkdir -p "$1"
}

clone_once() {
    local url="$1" dst="$2"
    if [[ -d "$dst/.git" ]]; then
        ok "cached $(basename "$dst")"
        return 0
    fi
    [[ ! -e "$dst" ]] || die "$dst exists and is not a git checkout"
    git clone --depth 1 --recurse-submodules "$url" "$dst"
}

apt_install() {
    log 'Installing Debian/Ubuntu/Kali dependencies'
    sudo -v
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential autoconf automake libtool libtool-bin pkg-config cmake ninja-build \
        git curl ca-certificates jq perl rsync attr acl file xz-utils unzip zip bsdextrautils \
        python3 python3-venv python3-dev python3-pip \
        libusb-1.0-0-dev libreadline-dev libplist-dev libssl-dev libpng-dev \
        libcurl4-openssl-dev liblzma-dev libzstd-dev libbz2-dev \
        libimobiledevice-utils libusbmuxd-tools usbmuxd usbutils sshpass \
        bc bison flex dwarves libelf-dev libssl-dev cpio kmod

    if apt-cache show libimobiledevice-glue-dev >/dev/null 2>&1; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libimobiledevice-glue-dev
    fi
    if apt-cache show libirecovery-utils >/dev/null 2>&1; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libirecovery-utils
    fi
}

checkout_ich() {
    log "Preparing ICH_A12_plus_Ramdisk at pinned commit $ICH_COMMIT"
    if [[ ! -d "$ROOT/.git" ]]; then
        [[ ! -e "$ROOT" || -z "$(find "$ROOT" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] \
            || die "$ROOT already exists and is not an ICH git checkout"
        rm -rf "$ROOT"
        git clone "$ICH_REPO" "$ROOT"
    fi

    cd "$ROOT"
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
        if [[ ! -f "$STATE/port-applied" ]]; then
            die "$ROOT has local modifications. Move them aside before the first port install."
        fi
    fi
    git fetch --quiet origin "$ICH_COMMIT"
    if [[ ! -f "$STATE/port-applied" ]]; then
        git checkout --detach "$ICH_COMMIT"
    fi
    ensure_dir "$TOOLS"
    ensure_dir "$VENDOR"
    ensure_dir "$STATE"
}

setup_venv() {
    log 'Preparing Python venv'
    python3 -m venv "$VENV"
    "$VENV/bin/python" -m pip install --upgrade pip wheel setuptools
    "$VENV/bin/python" -m pip install -r "$ROOT/requirements.txt" pyusb remotezip
    "$VENV/bin/python" - <<'PY'
import capstone, pyimg4, usb
from remotezip import RemoteZip
print('Python modules: pyimg4/capstone/pyusb/remotezip OK')
PY
}

install_irecovery() {
    log 'Installing irecovery'
    local irecovery_bin=''
    irecovery_bin="$(command -v irecovery 2>/dev/null || true)"
    if [[ -z "$irecovery_bin" ]]; then
        local src="$VENDOR/libirecovery"
        clone_once 'https://github.com/libimobiledevice/libirecovery.git' "$src"
        if ! pkg-config --exists libimobiledevice-glue-1.0; then
            local glue="$VENDOR/libimobiledevice-glue"
            clone_once 'https://github.com/libimobiledevice/libimobiledevice-glue.git' "$glue"
            (cd "$glue" && ./autogen.sh --prefix="$ROOT/.local" && make -j"$JOBS" && make install)
            export PKG_CONFIG_PATH="$ROOT/.local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            export LD_LIBRARY_PATH="$ROOT/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
        (cd "$src" && ./autogen.sh --prefix="$ROOT/.local" && make -j"$JOBS" && make install)
        irecovery_bin="$ROOT/.local/bin/irecovery"
    fi
    [[ -x "$irecovery_bin" ]] || die 'irecovery build/install failed'
    ln -sfn "$irecovery_bin" "$TOOLS/irecovery"
    ok "$irecovery_bin"
}

install_ipsw() {
    log 'Installing blacktop/ipsw Linux binary'
    local ipsw_bin
    ipsw_bin="$(command -v ipsw 2>/dev/null || true)"
    if [[ -n "$ipsw_bin" ]]; then
        ln -sfn "$ipsw_bin" "$TOOLS/ipsw"
        ok "$ipsw_bin"
        return
    fi

    local version tarball url tmp
    version="$(curl -fsSL --retry 4 --retry-delay 2 https://api.github.com/repos/blacktop/ipsw/releases/latest \
        | jq -r '.tag_name' | sed 's/^v//')"
    [[ -n "$version" && "$version" != null ]] || die 'Could not resolve latest blacktop/ipsw release'
    tarball="ipsw_${version}_linux_x86_64.tar.gz"
    url="https://github.com/blacktop/ipsw/releases/latest/download/$tarball"
    tmp="$VENDOR/$tarball"
    if [[ ! -s "$tmp" ]]; then
        curl -fL --retry 4 --retry-delay 3 --progress-bar "$url" -o "$tmp.part"
        mv "$tmp.part" "$tmp"
    fi
    local extract_dir="$VENDOR/ipsw-extract" found
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xzf "$tmp" -C "$extract_dir"
    found="$(find "$extract_dir" -type f -name ipsw -print -quit)"
    [[ -n "$found" ]] || die 'blacktop/ipsw archive contained no ipsw executable'
    install -m 0755 "$found" "$TOOLS/ipsw"
    rm -rf "$extract_dir"
    ok "ipsw $version"
}

install_img4() {
    log 'Building xerub/img4lib for Linux'
    local src="$VENDOR/img4lib"
    clone_once 'https://github.com/xerub/img4lib.git' "$src"
    git -C "$src" submodule update --init --recursive
    if [[ -d "$src/lzfse" ]]; then
        cmake -S "$src/lzfse" -B "$src/lzfse/build" -DCMAKE_BUILD_TYPE=Release
        cmake --build "$src/lzfse/build" --parallel "$JOBS"
    fi
    make -C "$src" -j"$JOBS"
    install -m 755 "$src/img4" "$TOOLS/img4"
    ok 'img4'
}

install_trustcache() {
    log 'Building CRKatri/trustcache for Linux'
    local src="$VENDOR/trustcache"
    clone_once 'https://github.com/CRKatri/trustcache.git' "$src"
    make -C "$src" clean >/dev/null 2>&1 || true
    make -C "$src" -j"$JOBS" OPENSSL=1
    install -m 755 "$src/trustcache" "$TOOLS/trustcache"
    ok 'trustcache'
}

install_ibootim() {
    log 'Building ibootim for Linux'
    local src="$VENDOR/ibootim"
    clone_once 'https://github.com/realnp/ibootim.git' "$src"
    make -C "$src" -j"$JOBS"
    install -m 755 "$src/ibootim" "$TOOLS/ibootim"
    ok 'ibootim'
}

install_apfsprogs() {
    log 'Building mkapfs'
    local src="$VENDOR/apfsprogs"
    clone_once 'https://github.com/linux-apfs/apfsprogs.git' "$src"
    make -C "$src/mkapfs" -j"$JOBS"
    install -m 755 "$src/mkapfs/mkapfs" "$TOOLS/mkapfs"
    ok 'mkapfs'
}

install_usbliter8ctl() {
    log 'Installing usbliter8ctl'
    local src="$VENDOR/usbliter8"
    clone_once 'https://github.com/JoshAtticus/usbliter8.git' "$src"

    cat > "$TOOLS/usbliter8ctl" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
exec "$VENV/bin/python" "$src/usbliter8ctl" "\$@"
EOF
    chmod 755 "$TOOLS/usbliter8ctl"

    cat > "$TOOLS/usbliter8_boot" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$# -eq 1 ]] || { echo 'usage: usbliter8_boot <raw-iBoot>' >&2; exit 64; }
exec "$VENV/bin/python" "$src/usbliter8ctl" boot "\$1"
EOF
    chmod 755 "$TOOLS/usbliter8_boot"
    ok 'usbliter8ctl + compatibility usbliter8_boot'
}

install_pzb_wrapper() {
    log 'Installing pzb-compatible HTTP range ZIP wrapper'
    cat > "$TOOLS/pzb.py" <<'PY'
#!/usr/bin/env python3
import argparse
import os
import shutil
import sys
from pathlib import Path
from remotezip import RemoteZip


def progress_copy(src, dst, total):
    copied = 0
    next_report = 8 * 1024 * 1024
    while True:
        chunk = src.read(1024 * 1024)
        if not chunk:
            break
        dst.write(chunk)
        copied += len(chunk)
        if copied >= next_report:
            if total:
                pct = copied * 100.0 / total
                print(f"\r  {copied/1048576:.1f}/{total/1048576:.1f} MiB ({pct:.1f}%)", end='', flush=True)
            else:
                print(f"\r  {copied/1048576:.1f} MiB", end='', flush=True)
            next_report += 8 * 1024 * 1024
    if copied:
        print()


def main():
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument('-g', '--get', dest='member')
    p.add_argument('-o', '--output', dest='output')
    p.add_argument('-l', '--list', action='store_true')
    p.add_argument('-h', '--help', action='store_true')
    p.add_argument('url', nargs='?')
    args, extra = p.parse_known_args()
    if args.help or not args.url:
        print('usage: pzb -g <path> [-o output] <remote.zip>')
        return 0
    with RemoteZip(args.url) as rz:
        if args.list:
            for info in rz.infolist():
                print(info.filename)
            return 0
        if not args.member:
            raise SystemExit('pzb wrapper: -g <path> is required')
        try:
            info = rz.getinfo(args.member)
        except KeyError:
            matches = [i for i in rz.infolist() if i.filename == args.member]
            if not matches:
                raise SystemExit(f'pzb wrapper: member not found: {args.member}')
            info = matches[0]
        out = Path(args.output or os.path.basename(args.member))
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_name(out.name + '.part')
        print(f'pzb(range): {args.member} -> {out}')
        with rz.open(info) as src, tmp.open('wb') as dst:
            progress_copy(src, dst, info.file_size)
        tmp.replace(out)
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
PY
    cat > "$TOOLS/pzb" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
exec "$VENV/bin/python" "$TOOLS/pzb.py" "\$@"
EOF
    chmod 755 "$TOOLS/pzb" "$TOOLS/pzb.py"
    ok 'pzb range wrapper'
}

link_system_tools() {
    log 'Linking native Linux host tools'
    local name target
    for name in jq sshpass iproxy; do
        target="$(command -v "$name" 2>/dev/null || true)"
        [[ -x "$target" ]] || die "Missing $name after package install"
        ln -sfn "$target" "$TOOLS/$name"
    done
    ln -sfn "$(command -v tar)" "$TOOLS/gtar"
    ok 'jq/sshpass/iproxy/gtar'
}

write_linux_env() {
    cat > "$ROOT/env.sh" <<'EOF'
#!/usr/bin/env bash
# Shared paths for ICHA12A13 (A12/A13 SSH ramdisk), WSL/Linux port.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NEW_RAMDISK_ROOT="$ROOT"
export NR_VERSION="v1.2-ICHA12A13-wsl2"
export NR_AUTHOR="@Official_I_C_H + WSL2 host port"
export NR_TELEGRAM="https://t.me/Official_I_C_H"
case "$(uname -s)" in
    Linux) export NR_TOOLS="$ROOT/tools/linux" ;;
    Darwin) export NR_TOOLS="$ROOT/tools/darwin" ;;
    *) echo "unsupported host OS: $(uname -s)" >&2; return 1 ;;
esac
export NR_PATCH="$ROOT/patch"
export NR_RESOURCES="$ROOT/resources"
export NR_CACHE="$ROOT/cache"
export NR_WORK="$ROOT/work"
export NR_BOOTCHAIN_ROOT="$ROOT/bootchain"
export PATH="$ROOT/.venv/bin:$NR_TOOLS:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
export LD_LIBRARY_PATH="$ROOT/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH="$ROOT/.local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
# shellcheck source=scripts/banner.sh
source "$ROOT/scripts/banner.sh"
export NR_LAST_BOOTCHAIN_FILE="$ROOT/.last_bootchain"
if [[ -z "${BOOTCHAIN_NAME:-}" && -f "$NR_LAST_BOOTCHAIN_FILE" ]]; then
    BOOTCHAIN_NAME="$(<"$NR_LAST_BOOTCHAIN_FILE")"
fi
export BOOTCHAIN_NAME="${BOOTCHAIN_NAME:-}"
export BOOTCHAIN="${BOOTCHAIN_NAME:+$NR_BOOTCHAIN_ROOT/$BOOTCHAIN_NAME}"
EOF
}

write_linux_ramdisk() {
    cat > "$ROOT/scripts/ramdisk_expand.sh" <<'EOF'
#!/usr/bin/env bash
# WSL/Linux APFS RestoreRamDisk clone + SSH injection.

nr_expand_inject_ramdisk() {
    local stock_dmg="$1"
    local ssh_tar="$2"
    local ignored_mount_pt="${3:-/tmp/NewRamdiskRD}"
    local gtar_bin="${4:-tar}"

    [[ -s "$stock_dmg" ]] || { echo "ramdisk: missing $stock_dmg" >&2; return 1; }
    [[ -s "$ssh_tar" ]] || { echo "ramdisk: missing $ssh_tar" >&2; return 1; }
    command -v sudo >/dev/null || { echo 'ramdisk: sudo is required' >&2; return 1; }
    [[ -x "$NR_TOOLS/mkapfs" ]] || { echo 'ramdisk: tools/linux/mkapfs missing' >&2; return 1; }

    sudo -v
    sudo modprobe libcrc32c 2>/dev/null || true
    sudo modprobe apfs 2>/dev/null || {
        echo 'ramdisk: APFS module is not loaded. Run: ~/ich-wsl2-port.sh apfs' >&2
        return 1
    }

    local stock_bytes headroom max_bytes target_bytes
    stock_bytes="$(stat -c%s "$stock_dmg")"
    headroom=$((80 * 1024 * 1024))
    max_bytes=$((280 * 1024 * 1024))
    target_bytes=$((stock_bytes + headroom))
    (( target_bytes < 256 * 1024 * 1024 )) && target_bytes=$((256 * 1024 * 1024))
    (( target_bytes > max_bytes )) && target_bytes=$max_bytes
    (( target_bytes <= stock_bytes )) && target_bytes=$stock_bytes

    echo "ramdisk linux: stock=${stock_bytes} target=${target_bytes}"

    local td stock_mp new_mp new_img mounted_stock=0 mounted_new=0
    td="$(mktemp -d /tmp/ich-rd.XXXXXX)"
    stock_mp="$td/stock"
    new_mp="$td/new"
    new_img="$td/ramdisk.new.dmg"
    mkdir -p "$stock_mp" "$new_mp"

    _nr_linux_cleanup() {
        set +e
        ((mounted_new)) && sudo umount "$new_mp" >/dev/null 2>&1
        ((mounted_stock)) && sudo umount "$stock_mp" >/dev/null 2>&1
        rm -rf "$td"
    }
    trap _nr_linux_cleanup RETURN

    truncate -s "$target_bytes" "$new_img"
    "$NR_TOOLS/mkapfs" -L RestoreRamDisk "$new_img"

    sudo mount -t apfs -o loop,ro "$stock_dmg" "$stock_mp"
    mounted_stock=1
    sudo mount -t apfs -o loop,rw,readwrite "$new_img" "$new_mp"
    mounted_new=1

    echo 'ramdisk linux: cloning stock filesystem'
    sudo cp -a "$stock_mp"/. "$new_mp"/

    echo 'ramdisk linux: injecting SSH payload'
    sudo "$gtar_bin" -x --no-overwrite-dir --same-owner --same-permissions -f "$ssh_tar" -C "$new_mp/"

    if [[ -f "$new_mp/usr/bin/mount_ich" ]]; then
        sudo chmod 755 "$new_mp/usr/bin/mount_ich"
    else
        echo 'warning: usr/bin/mount_ich missing after SSH payload injection' >&2
    fi

    if [[ -f "$NR_RESOURCES/restored_external" && -d "$new_mp/usr/local/bin" ]]; then
        sudo cp "$NR_RESOURCES/restored_external" "$new_mp/usr/local/bin/restored_external"
        sudo chmod 755 "$new_mp/usr/local/bin/restored_external"
        echo 'ramdisk linux: installed ICH restored_external'
    fi

    sync
    sudo umount "$new_mp"
    mounted_new=0
    sudo umount "$stock_mp"
    mounted_stock=0

    cp -f "$stock_dmg" "${stock_dmg}.pre-wsl-port.bak"
    mv -f "$new_img" "$stock_dmg"
    rm -rf "$td"
    trap - RETURN
    echo 'ramdisk linux: APFS clone/inject OK'
}
EOF
    chmod 755 "$ROOT/scripts/ramdisk_expand.sh"
}

patch_build_and_boot() {
    log 'Applying WSL/Linux source changes'
    local backup="$ROOT/.wsl-port-backup"
    ensure_dir "$backup"
    for f in env.sh build.sh boot.sh scripts/ramdisk_expand.sh; do
        [[ -f "$backup/${f//\//__}" ]] || cp "$ROOT/$f" "$backup/${f//\//__}"
    done

    write_linux_env
    write_linux_ramdisk

    "$VENV/bin/python" - "$ROOT/build.sh" "$ROOT/boot.sh" <<'PY'
from pathlib import Path
import re
import sys

build = Path(sys.argv[1])
boot = Path(sys.argv[2])

s = build.read_text()
s = s.replace(
    'for tool in "$IRECOVERY" "$PZB" "$IMG4" "$GTAR" "$TC" "$JQ" curl ipsw python3 hdiutil diskutil; do',
    'for tool in "$IRECOVERY" "$PZB" "$IMG4" "$GTAR" "$TC" "$JQ" curl ipsw python3 sudo mount umount; do'
)
s = s.replace('[[ "$PWND" == "usbliter8" ]] || {', '[[ "${PWND,,}" == "usbliter8" ]] || {')
start = s.find('# --- Expand stock RestoreRamDisk, inject SSH (method A/B) ---')
end = s.find('# Trustcache: stock RestoreTrustCache + append injected SSH CDHashes.')
if start < 0 or end < 0 or end <= start:
    raise SystemExit('build.sh ramdisk markers changed; refusing an unsafe patch')
replacement = '''# --- Expand stock RestoreRamDisk, inject SSH (WSL/Linux APFS) ---\n# nr_expand_inject_ramdisk also installs resources/restored_external when present.\nnr_expand_inject_ramdisk \\\n    "$WORK/ramdisk.dmg" \\\n    "$NR_RESOURCES/ssh.tar.gz" \\\n    /tmp/NewRamdiskRD \\\n    "$GTAR"\n\n'''
s = s[:start] + replacement + s[end:]
build.write_text(s)

s = boot.read_text()
s = s.replace('[[ "$PWND" == "usbliter8" ]]', '[[ "${PWND,,}" == "usbliter8" ]]')
boot.write_text(s)
PY

    chmod 755 "$ROOT/build.sh" "$ROOT/boot.sh" "$ROOT/env.sh"
    touch "$STATE/port-applied"
    ok 'WSL port applied'
}

verify_tools() {
    log 'Verifying Linux toolchain'
    local fail=0 t
    for t in irecovery pzb img4 gtar trustcache jq usbliter8ctl usbliter8_boot iproxy sshpass ibootim mkapfs ipsw; do
        if [[ -x "$TOOLS/$t" ]]; then
            printf '    [OK] %-18s %s\n' "$t" "$TOOLS/$t"
        else
            printf '    [MISS] %s\n' "$t" >&2
            fail=1
        fi
    done
    "$VENV/bin/python" -c 'import pyimg4,capstone,usb,remotezip' || fail=1
    ((fail == 0)) || die 'Toolchain verification failed'
}

install_all() {
    require_wsl
    apt_install
    checkout_ich
    setup_venv
    link_system_tools
    install_irecovery
    install_ipsw
    install_img4
    install_trustcache
    install_ibootim
    install_apfsprogs
    install_usbliter8ctl
    install_pzb_wrapper
    patch_build_and_boot
    verify_tools

    log 'Host-side WSL port installed'
    printf 'Root: %s\n' "$ROOT"
    printf 'Next: %s apfs\n' "$0"
}

build_apfs_module() {
    require_wsl
    [[ -d "$ROOT/.git" ]] || die "Run '$0 install' first"
    sudo -v

    log 'Checking APFS module'
    if grep -qw apfs /proc/filesystems && lsmod | awk '$1=="apfs"{found=1} END{exit !found}'; then
        ok 'APFS module already loaded'
        return 0
    fi

    local krel base tag ksrc apfs_src kbuild
    krel="$(uname -r)"
    base="${krel%%-microsoft*}"
    [[ "$base" != "$krel" ]] || die "Unexpected WSL kernel release: $krel"
    tag="linux-msft-wsl-$base"
    apfs_src="$VENDOR/linux-apfs-rw"

    clone_once 'https://github.com/linux-apfs/linux-apfs-rw.git' "$apfs_src"

    if [[ -e "/lib/modules/$krel/build/Makefile" ]]; then
        kbuild="$(readlink -f "/lib/modules/$krel/build")"
        ok "using installed WSL kernel build tree: $kbuild"
    else
        ksrc="$VENDOR/WSL2-Linux-Kernel-$base"
        log "Preparing exact Microsoft WSL kernel build tree: $tag"
        if [[ ! -d "$ksrc/.git" ]]; then
            git clone --depth 1 --branch "$tag" https://github.com/microsoft/WSL2-Linux-Kernel.git "$ksrc"
        fi
        cd "$ksrc"
        if [[ ! -f .config ]]; then
            cp Microsoft/config-wsl .config
        fi
        make olddefconfig
        # CONFIG_MODVERSIONS requires Module.symvers from a real kernel build.
        if [[ ! -s Module.symvers || ! -s arch/x86/boot/bzImage ]]; then
            log 'Building matching WSL kernel symbols for the external APFS module'
            make -j"$JOBS"
        fi
        kbuild="$ksrc"
    fi

    log 'Building linux-apfs-rw'
    make -C "$apfs_src" clean KERNEL_DIR="$kbuild" >/dev/null 2>&1 || true
    make -C "$apfs_src" -j"$JOBS" KERNEL_DIR="$kbuild" KERNELRELEASE="$krel"
    [[ -s "$apfs_src/apfs.ko" ]] || die 'apfs.ko was not produced'

    printf '    module vermagic: %s\n' "$(modinfo -F vermagic "$apfs_src/apfs.ko" 2>/dev/null || echo unknown)"
    printf '    running kernel:  %s\n' "$krel"

    sudo mkdir -p "/lib/modules/$krel/extra"
    sudo install -m 644 "$apfs_src/apfs.ko" "/lib/modules/$krel/extra/apfs.ko"
    sudo depmod -a "$krel" || true
    sudo modprobe libcrc32c 2>/dev/null || true

    if ! sudo modprobe apfs 2>/tmp/ich-apfs-modprobe.err; then
        warn 'The module did not load into the Microsoft-provided kernel.'
        cat /tmp/ich-apfs-modprobe.err >&2 || true
        if [[ -n "${ksrc:-}" && -s "$ksrc/arch/x86/boot/bzImage" ]]; then
            local winprofile kernel_dst kernel_win
            winprofile="$(powershell.exe -NoProfile -Command '[Environment]::GetFolderPath("UserProfile")' 2>/dev/null | tr -d '\r')"
            if [[ -n "$winprofile" ]]; then
                kernel_dst="$(wslpath -u "$winprofile")/.wsl-kernels/ich-apfs-$base-bzImage"
                mkdir -p "$(dirname "$kernel_dst")"
                cp "$ksrc/arch/x86/boot/bzImage" "$kernel_dst"
                kernel_win="$(wslpath -w "$kernel_dst")"
                printf '\nA matching custom WSL kernel was built at:\n  %s\n' "$kernel_win"
                printf 'Add/merge this into %%USERPROFILE%%\\.wslconfig, then run `wsl --shutdown` from PowerShell:\n\n'
                printf '[wsl2]\nkernel=%s\n\n' "${kernel_win//\\/\\\\}"
                printf 'Then start WSL and rerun: %s apfs\n' "$0"
            fi
        fi
        exit 2
    fi

    grep -qw apfs /proc/filesystems || die 'apfs module loaded but filesystem did not register'
    ok 'linux-apfs-rw loaded'
    touch "$STATE/apfs-ready"
}

usb_attach() {
    require_wsl
    command -v usbipd.exe >/dev/null 2>&1 || die 'usbipd.exe is not visible from WSL. Install usbipd-win on Windows first.'

    log 'Locating Apple DFU device on Windows'
    local list busid
    list="$(usbipd.exe list 2>/dev/null | tr -d '\r')"
    printf '%s\n' "$list" | grep -Ei '05ac:1227|Apple.*DFU' || true
    busid="$(printf '%s\n' "$list" | awk 'tolower($0) ~ /05ac:1227|apple.*dfu/ {print $1; exit}')"
    [[ -n "$busid" ]] || die 'No Apple 05ac:1227 DFU device is currently visible to usbipd.'
    ok "BUSID $busid"

    log 'Attaching DFU device to WSL'
    if ! usbipd.exe attach --wsl --auto-attach --busid "$busid"; then
        printf '\nIf this BUSID has never been shared, run this ONCE in elevated Windows PowerShell:\n'
        printf '  usbipd bind --busid %s\n' "$busid"
        printf 'Then rerun: %s usb\n' "$0"
        exit 2
    fi

    sleep 1
    if command -v lsusb >/dev/null 2>&1; then
        lsusb | grep -i '05ac:1227' || warn 'attach returned success but 05ac:1227 is not yet visible in lsusb'
    fi
}

status_all() {
    require_wsl
    [[ -d "$ROOT" ]] || die "Run '$0 install' first"
    source "$ROOT/env.sh"
    verify_tools

    log 'WSL/APFS status'
    printf '    kernel: %s\n' "$(uname -r)"
    if lsmod | awk '$1=="apfs"{found=1} END{exit !found}'; then
        ok 'apfs module loaded'
    else
        warn "apfs module not loaded; run: $0 apfs"
    fi

    log 'USB status'
    if command -v lsusb >/dev/null 2>&1; then
        lsusb | grep -Ei '05ac|Apple' || warn 'No Apple USB device visible inside WSL'
    fi

    log 'irecovery status'
    if "$TOOLS/irecovery" -q; then
        local info pwn
        info="$("$TOOLS/irecovery" -q 2>/dev/null || true)"
        pwn="$(awk -F': ' '$1=="PWND"{print $2;exit}' <<<"$info")"
        if [[ "${pwn,,}" == usbliter8 ]]; then
            ok 'PWND: usbliter8'
        else
            warn "PWND field is '${pwn:-missing}'"
        fi
    else
        warn 'irecovery cannot currently open the device'
    fi
}

run_build() {
    require_wsl
    [[ -f "$STATE/port-applied" ]] || die "Run '$0 install' first"
    lsmod | awk '$1=="apfs"{found=1} END{exit !found}' || die "Run '$0 apfs' first"
    source "$ROOT/env.sh"
    cd "$ROOT"
    exec ./build.sh "$@"
}

run_boot() {
    require_wsl
    [[ -f "$STATE/port-applied" ]] || die "Run '$0 install' first"
    source "$ROOT/env.sh"
    cd "$ROOT"
    exec ./boot.sh "$@"
}

main() {
    local cmd="${1:-}"
    [[ $# -gt 0 ]] && shift || true
    case "$cmd" in
        install) install_all "$@" ;;
        apfs) build_apfs_module "$@" ;;
        usb) usb_attach "$@" ;;
        status) status_all "$@" ;;
        build) run_build "$@" ;;
        boot) run_boot "$@" ;;
        -h|--help|help|'') usage ;;
        *) usage >&2; exit 64 ;;
    esac
}

main "$@"
