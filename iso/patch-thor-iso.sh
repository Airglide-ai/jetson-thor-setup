#!/usr/bin/env bash
# Patch an NVIDIA Jetson Thor ISO so the NVMe install leaves room for a DATA partition.
#
#   sudo ./patch-thor-iso.sh <input.iso> <output.iso> [APP_GIB] [DISK_BYTES]
#
#   APP_GIB     Size of the system partition (APP, p1) in GiB. Default: 180.
#   DISK_BYTES  Disk size used for the dry-run check. Default: size of /dev/nvme0n1
#               if present, otherwise 1 TB.
#
# Changes made inside the installer squashfs (*.nvidia.squashfs):
#   1. /opt/nvidia/ptable.thor.nvme.dynamic
#        - APP (p1) gets a fixed size instead of filling the disk.
#        - New p12 "DATA" partition right after APP, filling the rest (1 MiB aligned).
#   2. /ai/jetsoniso_setup.bash
#        - The APP size is read with `grep 'p1 ' | cut -d' ' -f5`, which returns the
#          START sector once a wider partition exists after APP. Replaced with awk.
# Then repacks the squashfs, updates md5sum.txt and rebuilds a bootable ISO
# (procedure from NVIDIA's "Jetson ISO Customization Guide").
#
# Host: Ubuntu/Debian (arm64 or x86_64), root, ~20 GB free.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo; echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ $# -ge 2 ]] || die "usage: sudo $0 <input.iso> <output.iso> [APP_GIB] [DISK_BYTES]"

INPUT_ISO=$(realpath "$1")
OUTPUT_ISO=$(realpath -m "$2")
APP_GIB=${3:-180}
if [[ -n "${4:-}" ]]; then
  DISK_BYTES=$4
elif [[ -b /dev/nvme0n1 ]]; then
  DISK_BYTES=$(lsblk -bdno SIZE /dev/nvme0n1)
else
  DISK_BYTES=1000204886016
fi

[[ -f "$INPUT_ISO" ]] || die "input ISO not found: $INPUT_ISO"
[[ "$APP_GIB" =~ ^[0-9]+$ ]] || die "APP_GIB must be an integer"

for cmd in xorriso unsquashfs mksquashfs sfdisk md5sum awk; do
  command -v "$cmd" >/dev/null || die "missing $cmd (apt install squashfs-tools xorriso fdisk)"
done

WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/thor-iso.XXXXXX")
MNT="$WORK/mnt"; ISO_DIR="$WORK/iso"; SQ_DIR="$WORK/sq"; TEST="$WORK/test"
mkdir -p "$MNT" "$ISO_DIR" "$SQ_DIR" "$TEST"
cleanup() { mountpoint -q "$MNT" && umount "$MNT"; rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------- extract
log "Extracting $INPUT_ISO"
BOOT_OPTS=$(xorriso -indev "$INPUT_ISO" -report_el_torito as_mkisofs 2>/dev/null \
  | sed 's/-partition_offset 0/-partition_offset 16/')
mount -o loop,ro "$INPUT_ISO" "$MNT"
cp -a "$MNT/." "$ISO_DIR/"
umount "$MNT"
chmod -R u+w "$ISO_DIR"

NVIDIA_SQ=$(find "$ISO_DIR/casper" -name '*.nvidia.squashfs' | head -1)
[[ -n "$NVIDIA_SQ" ]] || die "no *.nvidia.squashfs in casper/"
SQ_NAME=$(basename "$NVIDIA_SQ")
COMP=$(unsquashfs -s "$NVIDIA_SQ" | awk '/^Compression/ {print $2}')
unsquashfs -q -p "$(nproc)" -f -d "$SQ_DIR/fs" "$NVIDIA_SQ"

PTABLE="$SQ_DIR/fs/opt/nvidia/ptable.thor.nvme.dynamic"
SETUP="$SQ_DIR/fs/ai/jetsoniso_setup.bash"
[[ -f "$PTABLE" ]] || die "missing $PTABLE (NVIDIA changed the layout?)"
[[ -f "$SETUP" ]] || die "missing $SETUP (NVIDIA changed the layout?)"

# ---------------------------------------------------------------- ptable
log "Patching partition table (APP = ${APP_GIB} GiB, DATA = rest)"
grep -q 'name="DATA"' "$PTABLE" && die "ptable already has a DATA partition (ISO already patched?)"

APP_LINE=$(grep -E '^/dev/CHANGE_BOOT_DISK_NAME_1p1 ' "$PTABLE") || die "APP (p1) line not found"
echo "$APP_LINE" | grep -q 'name="APP"' || die "p1 is not APP: $APP_LINE"
echo "$APP_LINE" | grep -q 'size=' && die "APP already has size= (ISO already patched?)"
APP_START=$(echo "$APP_LINE" | sed -E 's/.*start= *([0-9]+),.*/\1/')
[[ "$APP_START" =~ ^[0-9]+$ ]] || die "could not parse APP start"

# APP must be the last partition on disk (highest start), otherwise DATA can't follow it.
MAX_START=$(grep -oE 'start= *[0-9]+' "$PTABLE" | grep -oE '[0-9]+' | sort -n | tail -1)
[[ "$APP_START" == "$MAX_START" ]] || die "APP is not the last partition on disk; layout changed"

ALIGN=2048                                   # 1 MiB in 512-byte sectors
APP_MIN=$(( APP_GIB * 1024 * 1024 * 2 ))     # GiB -> sectors
DATA_START=$(( ( (APP_START + APP_MIN + ALIGN - 1) / ALIGN ) * ALIGN ))
APP_SIZE=$(( DATA_START - APP_START ))
echo "APP  start=$APP_START size=$APP_SIZE sectors ($(( APP_SIZE / 2048 )) MiB)"
echo "DATA start=$DATA_START (fills the rest)"

sed -i -E "s|^(/dev/CHANGE_BOOT_DISK_NAME_1p1 *: *start= *${APP_START},)|\1 size= ${APP_SIZE},|" "$PTABLE"
printf '%s\n' "/dev/CHANGE_BOOT_DISK_NAME_1p12 : start= ${DATA_START}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=\"DATA\"" >> "$PTABLE"

# ---------------------------------------------------------------- setup script
log "Patching APP size detection in jetsoniso_setup.bash"
OLD="grep 'p1 ' | cut -d' ' -f5"
NEW="awk '\$1 ~ /p1\$/ {print \$4}'"
if grep -qF "$OLD" "$SETUP"; then
  OLD_RE=$(printf '%s' "$OLD" | sed 's/[]\/$*.^[]/\\&/g')
  NEW_RE=$(printf '%s' "$NEW" | sed 's/[\/&]/\\&/g')
  sed -i "s/${OLD_RE}/${NEW_RE}/g" "$SETUP"
else
  echo "WARNING: fragile pattern not found; NVIDIA may have changed it. Review NVME_DYNAMIC_APP_SIZE logic:"
fi
grep -n -B1 'NVME_DYNAMIC_APP_SIZE' "$SETUP" | sed 's/^/    /'

# ---------------------------------------------------------------- dry run
log "Dry run on a sparse ${DISK_BYTES}-byte fake disk"
truncate -s "$DISK_BYTES" "$TEST/nvme0n1"
sed "s#/dev/CHANGE_BOOT_DISK_NAME_1#$TEST/nvme0n1#g" "$PTABLE" > "$TEST/pt"
sfdisk -q "$TEST/nvme0n1" < "$TEST/pt" >/dev/null 2>&1 || die "sfdisk rejected the patched table"
sfdisk -l "$TEST/nvme0n1" | grep -E 'p1 |p12 ' | sed "s#$TEST/##"
# Evaluate the exact command the installer will run for NVMe.
NVME_CMD=$(grep -A3 '"nvme"' "$SETUP" | grep 'app_part_size_sectors=' | head -1 \
  | sed -E 's/.*app_part_size_sectors=\$\((.*)\)\s*$/\1/' \
  | sed "s#/dev/\${BOOT_DISK}#$TEST/nvme0n1#")
[[ -n "$NVME_CMD" ]] || die "could not extract the installer's NVMe size command"
GOT=$(bash -c "$NVME_CMD")
echo "installer would compute APP = $GOT sectors (expected $APP_SIZE)"
[[ "$GOT" == "$APP_SIZE" ]] || die "installer size detection is wrong; not building ISO"
DATA_SECTORS=$(sfdisk -l "$TEST/nvme0n1" | awk '$1 ~ /p12$/ {print $4}')
echo "DATA on this disk: $(( DATA_SECTORS / 2 / 1024 / 1024 )) GiB"

# ---------------------------------------------------------------- repack
log "Repacking squashfs ($COMP)"
mksquashfs "$SQ_DIR/fs" "$WORK/new.squashfs" -b 1048576 -noappend -comp "${COMP:-gzip}" -quiet
mv "$WORK/new.squashfs" "$NVIDIA_SQ"

NEW_HASH=$(md5sum "$NVIDIA_SQ" | awk '{print $1}')
sed -i "s|^[0-9a-f]\+  \./casper/${SQ_NAME}$|${NEW_HASH}  ./casper/${SQ_NAME}|" "$ISO_DIR/md5sum.txt"
BAD=$(cd "$ISO_DIR" && md5sum -c md5sum.txt 2>/dev/null | grep -v ': OK$' || true)
[[ -z "$BAD" ]] || die "md5sum.txt mismatch: $BAD"

log "Building $OUTPUT_ISO"
eval xorriso -as mkisofs "$BOOT_OPTS" -o "\"$OUTPUT_ISO\"" "\"$ISO_DIR/\"" 2>&1 | tail -3
[[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER:" "$OUTPUT_ISO"

# Keep a copy of the patched files next to the ISO for documentation / diffing.
OUT_BASE="${OUTPUT_ISO%.iso}"
cp "$PTABLE" "${OUT_BASE}.ptable.thor.nvme.dynamic"
cp "$SETUP" "${OUT_BASE}.jetsoniso_setup.bash"
[[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER:" "${OUT_BASE}".ptable.* "${OUT_BASE}".jetsoniso_setup.bash

log "Done"
ls -lh "$OUTPUT_ISO"
echo "Write it to a USB stick (GNOME Disks 'Restore Disk Image' or dd) and install with"
echo "'Flash Jetson AGX Thor Developer Kit on NVMe'."
