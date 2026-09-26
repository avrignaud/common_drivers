#!/usr/bin/env bash
# Build a CoreELEC Amlogic-no kernel image (KERNEL = Android boot image with
# Image.lzo + initramfs) from the exact CoreELEC revision an official nightly
# was built from, first unmodified and then with common_drivers swapped to a
# commit that adds one patch, and assemble an update tar that is the official
# nightly with only target/KERNEL (+ KERNEL.md5) replaced.
#
# Test build for CoreELEC/common_drivers#42 (drm/meson: hdmitx: don't leak the
# saved state on a repeated plug-out). Runs on Ubuntu 24.04 (GitHub Actions).
set -euo pipefail

: "${CE_COMMIT:=cb01a8989c75486ff0cfc7cbab7bcd6c20cfbc7f}"      # CoreELEC/CoreELEC, nightly_20260926
: "${BASE_CD:=23b23cb6b709d53a5b7cb2cc6984f0c4d16bb125}"        # common_drivers pinned by that commit
: "${PATCHED_CD:=48e62bf2932c98e48d18569ff0a1d73e25924eda}"     # BASE_CD + the fix (PR #42 head)
: "${PATCHED_CD_REPO:=avrignaud/common_drivers}"
: "${OFFICIAL_TAR_URL:=https://archive.coreelec.org/Amlogic-no/CE-22/20260926/CoreELEC-Amlogic-no.aarch64-22.0-Piers_nightly_20260926.tar}"
: "${BUILD_UNPATCHED:=yes}"
: "${TEST_SUFFIX:=hpd-leak-fix-test}"
: "${WORK:=$PWD/work}"
: "${OUT:=$PWD/out}"
CI_DIR=$(cd "$(dirname "$0")" && pwd)

export PROJECT=Amlogic-ce DEVICE=Amlogic-no ARCH=aarch64
mkdir -p "$WORK" "$OUT"
NOTES="$OUT/BUILD-NOTES.md"
log() { printf '\n=== %s  [%s]\n' "$*" "$(date -u +%H:%M:%SZ)"; }
note() { printf '%s\n' "$*" >>"$NOTES"; }
die() { echo "FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- official tar
log "official nightly: $OFFICIAL_TAR_URL"
curl -fsSL --retry 5 --retry-delay 10 -o "$WORK/official.tar" "$OFFICIAL_TAR_URL"
OFF_SHA=$(sha256sum "$WORK/official.tar" | cut -d' ' -f1)
mkdir -p "$WORK/official" && tar -xf "$WORK/official.tar" -C "$WORK/official"
OFF_DIR=$(find "$WORK/official" -mindepth 1 -maxdepth 1 -type d | head -1)
OFF_NAME=$(basename "$OFF_DIR")
( cd "$OFF_DIR" && md5sum -c target/KERNEL.md5 target/SYSTEM.md5 )
OFF_KERNEL_MD5=$(cut -d' ' -f1 "$OFF_DIR/target/KERNEL.md5")
log "official KERNEL boot image"
python3 "$CI_DIR/split_bootimg.py" "$OFF_DIR/target/KERNEL" "$WORK/official-boot" | tee "$OUT/official-KERNEL-header.txt"
lzop -dc "$WORK/official-boot/kernel" >"$WORK/official-boot/Image" 2>/dev/null || true
OFF_LINUX_VERSION=$(strings -n 16 "$WORK/official-boot/Image" | grep -m1 '^Linux version 5\.' || echo '?')
echo "official: $OFF_LINUX_VERSION"
log "official modules (unsquashfs)"
unsquashfs -q -n -d "$WORK/official-sys" "$OFF_DIR/target/SYSTEM" 'usr/lib/kernel-overlays/base/lib/modules' >/dev/null
OFF_MODS=$(find "$WORK/official-sys/usr/lib/kernel-overlays/base/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -n "$OFF_MODS" ] || die "no modules dir in official SYSTEM"
echo "official modules: $OFF_MODS ($(find "$OFF_MODS" -name '*.ko' | wc -l) .ko)"

cat >"$NOTES" <<EON
# Test kernel for CoreELEC/common_drivers#42 (HPD suspend-state leak)

Built $(date -u +%Y-%m-%dT%H:%M:%SZ) by GitHub Actions run ${GITHUB_RUN_ID:-local}
(${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}).

Base: CoreELEC/CoreELEC \`$CE_COMMIT\` (the commit \`$OFF_NAME\` was built from,
its /etc/os-release BUILD_ID), which pins common_drivers \`$BASE_CD\`.
Patched: common_drivers \`$PATCHED_CD\` from \`$PATCHED_CD_REPO\` = \`$BASE_CD\`
+ the one commit under review. Nothing else differs.

Official tar: \`$OFF_NAME.tar\` sha256 \`$OFF_SHA\`, target/KERNEL md5 \`$OFF_KERNEL_MD5\`.
Official kernel: \`$OFF_LINUX_VERSION\`
EON

# ------------------------------------------------------------------- CoreELEC
log "CoreELEC $CE_COMMIT"
git clone -q https://github.com/CoreELEC/CoreELEC.git "$WORK/ce"
cd "$WORK/ce"
git checkout -q "$CE_COMMIT"
CDPKG=projects/Amlogic-ce/packages/linux-drivers/amlogic/common_drivers/package.mk
grep -q "^PKG_VERSION=\"$BASE_CD\"" "$CDPKG" || die "$CDPKG does not pin $BASE_CD"
grep -E '^PKG_VERSION=' projects/Amlogic-ce/packages/linux/package.mk "$CDPKG" projects/Amlogic-ce/packages/lang/clang/package.mk
LINUX_VER=$(grep -E '^PKG_VERSION=' projects/Amlogic-ce/packages/linux/package.mk | cut -d'"' -f2)
[ -n "$LINUX_VER" ] || die "cannot read the linux package version"
yes | ./scripts/checkdeps || true

build_kernel() {   # $1 = label
    local label=$1 rc
    log "build linux ($label)"
    set +o pipefail
    ./scripts/build linux 2>&1 | tee "$OUT/build-$label.log" \
        | grep --line-buffered -E '^\s*(GET|UNPACK|BUILD|INSTALL)\s|error:|Error [0-9]|FAILURE|\*\*\*' || true
    rc=${PIPESTATUS[0]}
    set -o pipefail
    [ "$rc" = 0 ] || { tail -80 "$OUT/build-$label.log"; die "scripts/build linux failed ($label) rc=$rc"; }
    local inst img mods
    inst=$(find "$PWD" -maxdepth 3 -type d -path "*/install_pkg/linux-$LINUX_VER" | head -1)
    [ -n "$inst" ] || die "no install_pkg/linux-$LINUX_VER dir"
    img="$inst/.image/Image.lzo"           # after mkbootimg this *is* the Android boot image
    head -c 8 "$img" | grep -q ANDROID || die "$img is not an Android boot image"
    cp "$img" "$OUT/KERNEL-$label.img"
    cp "$inst/.image/Module.symvers" "$OUT/Module.symvers-$label"
    cp "$inst/.image/.config" "$OUT/config-$label"
    gzip -c "$inst/.image/System.map" >"$OUT/System.map-$label.gz"
    mods=$(find "$inst/usr/lib/kernel-overlays/base/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -1)
    python3 "$CI_DIR/split_bootimg.py" "$OUT/KERNEL-$label.img" "$WORK/boot-$label" | tee "$OUT/KERNEL-$label-header.txt"
    lzop -dc "$WORK/boot-$label/kernel" >"$WORK/boot-$label/Image" 2>/dev/null || true
    local lv; lv=$(strings -n 16 "$WORK/boot-$label/Image" | grep -m1 '^Linux version 5\.' || echo '?')
    echo "$label: $lv"
    log "module ABI check ($label) against the official SYSTEM's modules"
    set +e
    python3 "$CI_DIR/modcompare.py" "$label" "$OUT/Module.symvers-$label" "$OFF_MODS" "$mods" | tee "$OUT/modcompare-$label.txt"
    local crc_rc=${PIPESTATUS[0]}
    set -e
    {
        echo
        echo "## $label build"
        echo
        echo "- kernel: \`$lv\`"
        echo "- KERNEL-$label.img: $(stat -c %s "$OUT/KERNEL-$label.img") bytes, md5 $(md5sum "$OUT/KERNEL-$label.img" | cut -d' ' -f1) (official: $(stat -c %s "$OFF_DIR/target/KERNEL") bytes, md5 $OFF_KERNEL_MD5)"
        echo "- $(grep -m1 kernel= "$OUT/KERNEL-$label-header.txt" | sed 's/^ *//') (official: $(grep -m1 kernel= "$OUT/official-KERNEL-header.txt" | sed 's/^ *//'))"
        echo "- module ABI vs official modules: $(head -1 "$OUT/modcompare-$label.txt" | sed "s/^\[$label\] //")"
        echo "- $(sed -n 3p "$OUT/modcompare-$label.txt" | sed "s/^\[$label\] //")"
        [ "$crc_rc" = 0 ] && echo "- CRC verdict: every official module's symbol CRCs match this kernel (it can boot the official SYSTEM)" \
                           || echo "- CRC verdict: **MISMATCHES** (see modcompare-$label.txt); do not install"
    } >>"$NOTES"
    echo "$crc_rc" >"$OUT/.crc-rc-$label"
}

if [ "$BUILD_UNPATCHED" = yes ]; then
    build_kernel unpatched
    log "clean linux + common_drivers before the patched build"
    ./scripts/clean linux
    ./scripts/clean common_drivers
fi

log "switch common_drivers to $PATCHED_CD_REPO@$PATCHED_CD"
sed -i -e "s|^PKG_VERSION=.*|PKG_VERSION=\"$PATCHED_CD\"|" \
       -e "s|^PKG_URL=.*|PKG_URL=\"https://github.com/$PATCHED_CD_REPO/archive/\${PKG_VERSION}.tar.gz\"|" "$CDPKG"
grep -E '^PKG_(VERSION|URL)=' "$CDPKG"
build_kernel patched

log "verify the patch is in the patched tree"
SRC=$(find "$PWD" -maxdepth 7 -type f -path "*/build/linux-$LINUX_VER/common_drivers/drivers/drm/meson_hdmi.c" | head -1)
[ -n "$SRC" ] || die "meson_hdmi.c not found in build tree"
grep -n 'if (!drm->mode_config.suspend_state)' "$SRC" || die "patched hunk missing from $SRC"
grep -c 'struct drm_mode_config mode_config = drm->mode_config;' "$SRC" | grep -qx 0 || die "old stack copy still present"
note ""
note "Patch presence: \`$(grep -n 'if (!drm->mode_config.suspend_state)' "$SRC" | head -1 | cut -d: -f1,2)\` in the patched build tree's meson_hdmi.c; the common_drivers .scmversion in the tree is \`$(cat "$(dirname "$SRC")/../../.scmversion" 2>/dev/null || echo '?')\`."

if [ "$BUILD_UNPATCHED" = yes ]; then
    log "unpatched vs patched Module.symvers"
    if diff -q <(sort "$OUT/Module.symvers-unpatched") <(sort "$OUT/Module.symvers-patched") >/dev/null; then
        note "Module.symvers of the unpatched and patched builds are identical (the patch changes no exported symbol)."
    else
        note "Module.symvers of the unpatched and patched builds DIFFER:"; note '```'; diff <(sort "$OUT/Module.symvers-unpatched") <(sort "$OUT/Module.symvers-patched") | head -40 >>"$NOTES"; note '```'
    fi
fi

# ------------------------------------------------------------------ test tar
[ "$(cat "$OUT/.crc-rc-patched")" = 0 ] || die "patched kernel's CRCs do not match the official modules; not assembling an update tar"
log "assemble update tar: official $OFF_NAME with target/KERNEL replaced"
NAME="$OFF_NAME-$TEST_SUFFIX"
rm -rf "$WORK/stage" && mkdir -p "$WORK/stage/$NAME"
cp -a "$OFF_DIR/." "$WORK/stage/$NAME/"
cp "$OUT/KERNEL-patched.img" "$WORK/stage/$NAME/target/KERNEL"
( cd "$WORK/stage/$NAME" && md5sum target/KERNEL >target/KERNEL.md5 && md5sum -c target/KERNEL.md5 target/SYSTEM.md5 )
cp "$NOTES" "$WORK/stage/$NAME/BUILD-NOTES.md"
tar -C "$WORK/stage" -cf "$OUT/$NAME.tar" "$NAME"
note ""
note "## Update tar"
note ""
note "\`$NAME.tar\`: the official tar with only \`target/KERNEL\` and \`target/KERNEL.md5\` replaced (SYSTEM is byte-identical to the official nightly; this file added). Install like any CoreELEC update: copy to \`/storage/.update/\` and reboot. Roll back with the official tar."
rm -f "$OUT"/.crc-rc-*
( cd "$OUT" && sha256sum -- * >SHA256SUMS.txt )
log "done"
cat "$NOTES"
ls -la "$OUT"
