### AnyKernel3 Ramdisk Mod Script
## thyme (Mi 10S) / SM8250 — Droidspaces 内核
##
## 只替换 boot 分区里的 kernel Image：
##   - ramdisk 原样保留（现有 Magisk / MIUI init 不受影响）
##   - 不写 dtb（原厂 DTB 在 vendor_boot 里，必须保持不动）
##   - 不写 dtbo / vbmeta

### AnyKernel setup
properties() { '
kernel.string=Droidspaces Kernel for Xiaomi thyme (Mi 10S, MIUI 14)
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=thyme
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;
NO_BLOCK_DISPLAY=1;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

ui_print "  -> thyme Droidspaces kernel (Image only, DTB/ramdisk untouched)";

# boot install
split_boot;

if [ ! -f "$AKHOME/Image" ]; then
    ui_print "  -> Image missing in this zip! Aborting...";
    exit 1;
fi;

flash_boot;
## end boot install
