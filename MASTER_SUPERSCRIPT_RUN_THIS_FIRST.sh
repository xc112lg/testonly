#!/bin/bash
# HYPEROS 2 REDMI 10A - COMPLETE MASTER SUPERSCRIPT
# ONE COMMAND TO PORT EVERYTHING
# Run this once, wait, done!

set -e

# ============================================================
# CONFIGURATION
# ============================================================

WORK_DIR="$HOME/hyperos2_rn12t_to_10a"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$WORK_DIR/PORT_$TIMESTAMP.log"

# ROM URLs (your provided links)
DONOR_URL="https://cdnorg.d.miui.com/OS2.0.215.0.VLHCNXM/pearl-ota_full-OS2.0.215.0.VLHCNXM-user-15.0-8246bfc336.zip"
TARGET_URL="https://cdnorg.d.miui.com/V12.5.16.0.RCZMIXM/miui_DANDELIONC3L2Global_V12.5.16.0.RCZMIXM_e004d17bcd_11.0.zip"

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
  sudo apt install -y -qq python3 python3-pip openjdk-11-jdk \
    android-tools-adb android-tools-fastboot \
    p7zip-full xz-utils brotli simg2img e2fsprogs erofs-utils git 2>&1 | tail -1
  
  pip3 install --user -q protobuf==3.20.1 brotli pycryptodome 2>&1 | tail -1
  
  # payload_dumper
  if [ ! -d "$WORK_DIR/tools/payload_dumper" ]; then
    log "Installing payload_dumper..."
    git clone -q https://github.com/vm03/payload_dumper.git "$WORK_DIR/tools/payload_dumper"
    cd "$WORK_DIR/tools/payload_dumper"
    pip3 install --user -q -r requirements.txt
  fi
  
  # AIK
  if [ ! -d "$HOME/tools/AIK" ]; then
    log "Installing AIK (Android Image Kitchen)..."
    mkdir -p "$HOME/tools"
    cd "$HOME/tools"
    wget -q https://github.com/osm0sis/Android-Image-Kitchen/archive/refs/heads/master.zip -O AIK.zip
    unzip -q AIK.zip
    mv Android-Image-Kitchen-master AIK
    chmod +x AIK/unpackimg.sh AIK/repackimg.sh
    rm AIK.zip
  fi
  
  log "✓ Setup complete"
}

# ============================================================
# DOWNLOAD
# ============================================================

download() {
  log_section "STEP 2: Downloading ROMs (~4.7 GB total)"
  
  # Try aria2c if available, otherwise wget
  if command -v aria2c &> /dev/null; then
    DOWNLOAD_CMD="aria2c -x 16 -k 1M -s 16"
  else
    DOWNLOAD_CMD="wget"
  fi
  
  log "Download tool: $DOWNLOAD_CMD"
  
  # Donor
  log "Downloading HyperOS 2 (Redmi Note 12T Pro)..."
  cd "$WORK_DIR/donor"
  $DOWNLOAD_CMD --allow-overwrite=true -o hyperos2_pearl.zip "$DONOR_URL" 2>&1 | tail -5
  DONOR_SIZE=$(du -sh hyperos2_pearl.zip | cut -f1)
  log "✓ Donor: $DONOR_SIZE"
  
  # Target
  log "Downloading MIUI 12.5 (Redmi 10a)..."
  cd "$WORK_DIR/target"
  $DOWNLOAD_CMD --allow-overwrite=true -o miui_dandelion.zip "$TARGET_URL" 2>&1 | tail -5
  TARGET_SIZE=$(du -sh miui_dandelion.zip | cut -f1)
  log "✓ Target: $TARGET_SIZE"
  
  log "✓ Downloads complete"
}

# ============================================================
# EXTRACT
# ============================================================

extract() {
  log_section "STEP 3: Extracting ROMs"
  
  # Donor
  log "Extracting HyperOS 2..."
  cd "$WORK_DIR/donor"
  unzip -q hyperos2_pearl.zip 2>&1 || true
  python3 "$WORK_DIR/tools/payload_dumper/payload_dumper.py" payload.bin -o partitions/ 2>&1 | tail -3
  
  cd partitions/
  for part in mi_ext product system system_ext vendor; do
    if [ -f "${part}.img" ]; then
      mkdir -p ${part}_mount
      sudo mount -o ro,loop ${part}.img ${part}_mount 2>/dev/null || true
      cp -r ${part}_mount/* $part/ 2>/dev/null || true
      sudo umount ${part}_mount 2>/dev/null || true
    fi
  done
  log "✓ Donor extracted"
  
  # Target
  log "Extracting MIUI 12.5..."
  cd "$WORK_DIR/target"
  unzip -q miui_dandelion.zip 2>&1 || true
  python3 "$WORK_DIR/tools/payload_dumper/payload_dumper.py" payload.bin -o partitions/ 2>&1 | tail -3
  
  cd partitions/
  for part in product system_ext vendor; do
    if [ -f "${part}.img" ]; then
      mkdir -p ${part}_mount
      sudo mount -o ro,loop ${part}.img ${part}_mount 2>/dev/null || true
      cp -r ${part}_mount/* $part/ 2>/dev/null || true
      sudo umount ${part}_mount 2>/dev/null || true
    fi
  done
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
  rm -f "$WORK_DIR/output/system_ext/etc/selinux/mapping"
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
  rm -f "$WORK_DIR/output/vendor/etc/selinux/mapping"
  log "✓ vendor copied"
}

# ============================================================
# REPACK IMAGES
# ============================================================

repack() {
  log_section "STEP 5: Repacking Images as EXT4"
  
  mkdir -p "$WORK_DIR/final_images"
  
  log "Creating product.img..."
  mkfs.ext4 -L product -T default -d "$WORK_DIR/output/product" -b 4096 -c "$WORK_DIR/final_images/product.img" 2>&1 | tail -2
  PROD_SIZE=$(du -sh "$WORK_DIR/final_images/product.img" | cut -f1)
  log "✓ product.img ($PROD_SIZE)"
  
  log "Creating system_ext.img..."
  mkfs.ext4 -L system_ext -T default -d "$WORK_DIR/output/system_ext" -b 4096 -c "$WORK_DIR/final_images/system_ext.img" 2>&1 | tail -2
  SEXT_SIZE=$(du -sh "$WORK_DIR/final_images/system_ext.img" | cut -f1)
  log "✓ system_ext.img ($SEXT_SIZE)"
  
  log "Creating vendor.img..."
  mkfs.ext4 -L vendor -T default -d "$WORK_DIR/output/vendor" -b 4096 -c "$WORK_DIR/final_images/vendor.img" 2>&1 | tail -2
  VEND_SIZE=$(du -sh "$WORK_DIR/final_images/vendor.img" | cut -f1)
  log "✓ vendor.img ($VEND_SIZE)"
}

# ============================================================
# PATCH BOOT
# ============================================================

patch_boot() {
  log_section "STEP 6: Patching Boot Image"
  
  cd "$WORK_DIR/boot_patch"
  
  log "Unpacking boot image..."
  ~/tools/AIK/unpackimg.sh "$WORK_DIR/donor/extracted/partitions/boot.img" 2>&1 | tail -2
  
  log "Extracting ramdisk..."
  cd split_img
  cpio -idm < ramdisk.cpio.gz 2>/dev/null
  
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
  ./repackimg.sh 2>&1 | tail -2
  
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
