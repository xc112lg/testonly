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
    p7zip-full xz-utils brotli e2fsprogs erofs-utils git 2>&1 | tee -a "$LOG_FILE"
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
  if [ ! -d "$HOME/tools/AIK" ]; then
    log "Installing AIK (Android Image Kitchen)..."
    mkdir -p "$HOME/tools"
    cd "$HOME/tools"

    wget -q https://github.com/osm0sis/Android-Image-Kitchen/archive/refs/heads/master.zip -O AIK.zip \
      || error "AIK download failed — check network/URL"

    [ -s AIK.zip ] || error "AIK.zip is empty or missing — download did not succeed"

    unzip -q AIK.zip || error "AIK.zip failed to unzip (possibly an HTML error page, not a real zip)"

    # Don't assume the exact folder name — GitHub archive naming can change
    AIK_EXTRACTED_DIR=$(find . -maxdepth 1 -type d -iname "Android-Image-Kitchen-*" | head -n1)
    [ -n "$AIK_EXTRACTED_DIR" ] || error "Could not find extracted Android-Image-Kitchen-* directory"

    mv "$AIK_EXTRACTED_DIR" AIK
    rm -f AIK.zip

    [ -f AIK/unpackimg.sh ] || error "AIK/unpackimg.sh missing after extraction — repo layout may have changed"
    [ -f AIK/repackimg.sh ] || error "AIK/repackimg.sh missing after extraction — repo layout may have changed"

    chmod +x AIK/unpackimg.sh AIK/repackimg.sh
    log "✓ AIK installed"
  fi
  
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

  # Try EROFS first (fsck.erofs --extract reads the image directly, no mount needed)
  if command -v fsck.erofs &> /dev/null; then
    if fsck.erofs --extract="$outdir" "$img" &>> "$LOG_FILE"; then
      [ -n "$(ls -A "$outdir" 2>/dev/null)" ] && return 0
    fi
  fi

  # Try ext4 via debugfs (reads the image directly, no mount needed)
  if command -v debugfs &> /dev/null; then
    debugfs -R "rdump / $outdir" "$img" &>> "$LOG_FILE"
    [ -n "$(ls -A "$outdir" 2>/dev/null)" ] && return 0
  fi

  # Last resort: actual loop mount (needs root + matching kernel fs driver)
  local mnt="${img%.img}_mount_tmp"
  mkdir -p "$mnt"
  if sudo mount -o ro,loop "$img" "$mnt" 2>>"$LOG_FILE"; then
    cp -r "$mnt"/* "$outdir"/ 2>/dev/null
    sudo umount "$mnt" 2>>"$LOG_FILE"
    rmdir "$mnt" 2>/dev/null
    [ -n "$(ls -A "$outdir" 2>/dev/null)" ] && return 0
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
  if [ -f extracted/partitions/vendor.img ] && [ -n "$(ls -A extracted/partitions/vendor 2>/dev/null)" ]; then
    log "✓ Target already extracted — skipping unzip + conversion"
  else
    log "Extracting MIUI 12.5..."
    mkdir -p extracted/partitions

    if [ -f extracted/partitions/vendor.img ]; then
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
    for part in product system_ext vendor; do
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
  
  mkdir -p "$WORK_DIR/output/product/etc" "$WORK_DIR/output/system_ext" "$WORK_DIR/output/vendor"
  
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
  log "Copying framework overlays..."
  mkdir -p "$WORK_DIR/output/product/overlay"
  cp "$WORK_DIR/donor/extracted/partitions/product/overlay"/*.apk "$WORK_DIR/output/product/overlay/" 2>/dev/null || true
  log "✓ Overlays copied"
  
  # system_ext
  log "Merging system_ext..."
  cp -r "$WORK_DIR/donor/extracted/partitions/system_ext"/* "$WORK_DIR/output/system_ext/"
  rm -rf "$WORK_DIR/output/system_ext/etc/selinux/mapping"
  mkdir -p "$WORK_DIR/output/system_ext/usr/keylayout" "$WORK_DIR/output/system_ext/usr/idc"
  cat > "$WORK_DIR/output/system_ext/usr/keylayout/accdet.kl" << 'ACCDET'
key 226   HEADSETHOOK
key 230   NOTIFICATION_LED
ACCDET
  cat > "$WORK_DIR/output/system_ext/usr/idc/accdet.idc" << 'ACCDET'
touch.deviceType = touchScreen
device.internal = 1
keyboard.layout = accdet
ACCDET
  log "✓ system_ext merged"
  
  # vendor
  log "Copying vendor (Redmi 10a drivers)..."
  cp -r "$WORK_DIR/target/extracted/partitions/vendor"/* "$WORK_DIR/output/vendor/"
  rm -rf "$WORK_DIR/output/vendor/etc/selinux/mapping"
  log "✓ vendor copied"
}

# ============================================================
# REPACK IMAGES
# ============================================================

repack() {
  log_section "STEP 5: Repacking Images as EXT4"
  
  mkdir -p "$WORK_DIR/final_images"
  
  log "Creating product.img..."
  if [ -f "$WORK_DIR/final_images/product.img" ]; then
    log "✓ product.img already exists — skipping"
  else
    mkfs.ext4 -L product -T default -d "$WORK_DIR/output/product" -b 4096 -c "$WORK_DIR/final_images/product.img" 2>&1 | tee -a "$LOG_FILE"
    [ "${PIPESTATUS[0]}" -eq 0 ] || error "mkfs.ext4 failed building product.img"
  fi
  PROD_SIZE=$(du -sh "$WORK_DIR/final_images/product.img" | cut -f1)
  log "✓ product.img ($PROD_SIZE)"
  
  log "Creating system_ext.img..."
  if [ -f "$WORK_DIR/final_images/system_ext.img" ]; then
    log "✓ system_ext.img already exists — skipping"
  else
    mkfs.ext4 -L system_ext -T default -d "$WORK_DIR/output/system_ext" -b 4096 -c "$WORK_DIR/final_images/system_ext.img" 2>&1 | tee -a "$LOG_FILE"
    [ "${PIPESTATUS[0]}" -eq 0 ] || error "mkfs.ext4 failed building system_ext.img"
  fi
  SEXT_SIZE=$(du -sh "$WORK_DIR/final_images/system_ext.img" | cut -f1)
  log "✓ system_ext.img ($SEXT_SIZE)"
  
  log "Creating vendor.img..."
  if [ -f "$WORK_DIR/final_images/vendor.img" ]; then
    log "✓ vendor.img already exists — skipping"
  else
    mkfs.ext4 -L vendor -T default -d "$WORK_DIR/output/vendor" -b 4096 -c "$WORK_DIR/final_images/vendor.img" 2>&1 | tee -a "$LOG_FILE"
    [ "${PIPESTATUS[0]}" -eq 0 ] || error "mkfs.ext4 failed building vendor.img"
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

  log "Unpacking boot image..."
  ~/tools/AIK/unpackimg.sh "$WORK_DIR/target/extracted/partitions/boot.img" 2>&1 | tee -a "$LOG_FILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || error "AIK unpackimg.sh failed on boot.img"
  [ -f split_img/ramdisk.cpio.gz ] || error "ramdisk.cpio.gz missing after unpack — boot.img may be a different format (e.g. no separate ramdisk, or vendor_boot split)"

  log "Extracting ramdisk..."
  cd split_img
  cpio -idm < ramdisk.cpio.gz || error "Failed to extract ramdisk.cpio.gz — corrupt or unexpected compression"
  [ -f init.rc ] || error "init.rc not found in extracted ramdisk — cannot patch"

  log "Patching ramdisk (disable AVB, permissive SELinux)..."
  sed -i 's/verity_user_mode=enforcing/verity_user_mode=disabled/g' init.rc
  sed -i 's/ro.boot.veritymode=enforcing/ro.boot.veritymode=disabled/g' init.rc
  sed -i 's/SELINUX=enforcing/SELINUX=permissive/g' init.rc
  sed -i 's/androidboot.selinux=enforcing/androidboot.selinux=permissive/g' init.rc
  
  log "Repacking ramdisk..."
  cd ..
  find split_img -print0 2>/dev/null | cpio --null -ov -H newc 2>/dev/null | gzip -9 > ramdisk.cpio.gz
  rm -f split_img/ramdisk.cpio.gz
  
  log "Rebuilding boot.img..."
  ./repackimg.sh 2>&1 | tee -a "$LOG_FILE"
  [ "${PIPESTATUS[0]}" -eq 0 ] || error "AIK repackimg.sh failed"
  [ -f image-new.img ] || error "repackimg.sh did not produce image-new.img"
  
  cp image-new.img "$WORK_DIR/final_images/boot.img"
  BOOT_SIZE=$(du -sh "$WORK_DIR/final_images/boot.img" | cut -f1)
  log "✓ boot.img patched ($BOOT_SIZE)"
}

# ============================================================
# COMPLETION
# ============================================================

complete() {
  log_section "STEP 7: Complete!"
  
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
  echo "1. Connect Redmi 10a to computer (USB debug enabled)"
  echo ""
  echo "2. Run flash script:"
  echo "   adb reboot bootloader"
  echo "   fastboot flash boot $WORK_DIR/final_images/boot.img"
  echo "   fastboot flash product $WORK_DIR/final_images/product.img"
  echo "   fastboot flash system_ext $WORK_DIR/final_images/system_ext.img"
  echo "   fastboot flash vendor $WORK_DIR/final_images/vendor.img"
  echo "   fastboot reboot"
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
  complete
  
  END=$(date +%s)
  DURATION=$((END - START))
  MINUTES=$((DURATION / 60))
  
  log "Total time: ${MINUTES} minutes"
}

# Run it
main
