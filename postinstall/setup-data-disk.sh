#!/usr/bin/env bash
# Encrypt the DATA partition with LUKS2, auto-unlock it with Clevis + Tang, mount it at
# /data, and put all Docker/containerd storage on it.
#
#   sudo ./setup-data-disk.sh http://IP-SYNOLOGY:7500
#
# Safe to re-run: every step checks whether it was already done.
# Interactive: asks for the LUKS backup passphrase (keep it in a password manager).
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo; echo "==> $*"; }

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ $# -eq 1 ]] || die "usage: sudo $0 http://TANG-HOST:PORT"

TANG_URL=${1%/}
DEV=/dev/disk/by-partlabel/DATA
NAME=data
MAPPER=/dev/mapper/$NAME
MNT=/data
CRYPTTAB_LINE="$NAME  $DEV  none  luks,_netdev,nofail"
FSTAB_LINE="$MAPPER  $MNT  ext4  defaults,_netdev,nofail  0  2"
BIND_DIRS=(docker containerd)

[[ -b "$DEV" ]] || die "$DEV not found. Was the Thor installed with the patched ISO? (lsblk -o NAME,SIZE,PARTLABEL)"

# ------------------------------------------------------------------ packages
log "Installing packages"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q cryptsetup clevis clevis-luks clevis-systemd curl jq rsync

log "Checking Tang at $TANG_URL"
curl -fsS --max-time 5 "$TANG_URL/adv" | grep -q payload \
  || die "Tang not reachable at $TANG_URL/adv (container running? firewall rule?)"
echo "Tang OK"

# ------------------------------------------------------------------ LUKS
if cryptsetup isLuks "$DEV"; then
  log "$DEV is already LUKS"
else
  log "Formatting $DEV with LUKS2 -- THIS ERASES THE DATA PARTITION"
  lsblk -o NAME,SIZE,PARTLABEL,FSTYPE "$(readlink -f "$DEV")"
  read -r -p "Type YES to continue: " ok
  [[ "$ok" == "YES" ]] || die "aborted"
  echo "Choose the BACKUP passphrase (store it in your password manager)."
  cryptsetup luksFormat --type luks2 --label DATA_LUKS "$DEV"
fi

if [[ ! -e "$MAPPER" ]]; then
  log "Opening $DEV (enter the backup passphrase)"
  cryptsetup open "$DEV" "$NAME"
fi

if ! blkid -o value -s TYPE "$MAPPER" | grep -q ext4; then
  log "Creating ext4 on $MAPPER"
  mkfs.ext4 -L data "$MAPPER"
fi

# ------------------------------------------------------------------ Clevis + Tang
if clevis luks list -d "$DEV" 2>/dev/null | grep -q tang; then
  log "Tang binding already present"
else
  log "Binding $DEV to Tang (enter the backup passphrase; accept the advertisement keys)"
  clevis luks bind -d "$DEV" tang "{\"url\":\"$TANG_URL\"}"
fi
clevis luks list -d "$DEV"
systemctl enable clevis-luks-askpass.path

# ------------------------------------------------------------------ crypttab / fstab
log "Configuring /etc/crypttab and /etc/fstab"
touch /etc/crypttab
grep -qE "^$NAME\s" /etc/crypttab || echo "$CRYPTTAB_LINE" >> /etc/crypttab
grep -qE "^$MAPPER\s" /etc/fstab || echo "$FSTAB_LINE" >> /etc/fstab
mkdir -p "$MNT"
systemctl daemon-reload
mountpoint -q "$MNT" || mount "$MNT"
chmod 755 "$MNT"

# ------------------------------------------------------------------ Docker / containerd on /data
log "Moving Docker and containerd storage to $MNT (bind mounts)"
systemctl stop docker.socket docker.service containerd.service 2>/dev/null || true
for d in "${BIND_DIRS[@]}"; do
  src=/var/lib/$d; dst=$MNT/$d
  mkdir -p "$dst" "$src"
  if ! findmnt -rno TARGET "$src" >/dev/null; then
    if [[ -n "$(ls -A "$src")" ]]; then
      echo "copying existing $src -> $dst"
      rsync -aHAX "$src/" "$dst/"
      mv "$src" "$src.pre-data"; mkdir -p "$src"
      echo "WARNING: unencrypted copy left at $src.pre-data -- delete it once everything works."
    fi
  fi
  line="$dst  $src  none  bind,nofail,x-systemd.requires-mounts-for=$MNT  0  0"
  grep -qE "^$dst\s+$src\s" /etc/fstab || echo "$line" >> /etc/fstab
done
systemctl daemon-reload
for d in "${BIND_DIRS[@]}"; do findmnt -rno TARGET "/var/lib/$d" >/dev/null || mount "/var/lib/$d"; done

# Docker/containerd must not start (and write unencrypted data) if /data is not mounted.
for unit in docker containerd; do
  mkdir -p "/etc/systemd/system/$unit.service.d"
  cat > "/etc/systemd/system/$unit.service.d/10-data-disk.conf" <<EOF
[Unit]
RequiresMountsFor=$MNT /var/lib/docker /var/lib/containerd
EOF
done

# Docker log rotation (keeps existing daemon.json, e.g. the NVIDIA runtime).
if [[ -d /etc/docker ]] || command -v dockerd >/dev/null; then
  mkdir -p /etc/docker
  [[ -s /etc/docker/daemon.json ]] || echo '{}' > /etc/docker/daemon.json
  cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
  jq '.["log-driver"] //= "json-file" | .["log-opts"] //= {"max-size":"50m","max-file":"3"}' \
    /etc/docker/daemon.json.bak > /etc/docker/daemon.json
fi

# ------------------------------------------------------------------ journald
log "Limiting journald to 2G"
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=2G\n' > /etc/systemd/journald.conf.d/10-size.conf
systemctl restart systemd-journald

systemctl daemon-reload
systemctl start containerd.service docker.service 2>/dev/null || true

# ------------------------------------------------------------------ summary
log "Summary"
lsblk -o NAME,SIZE,PARTLABEL,FSTYPE,MOUNTPOINTS "$(readlink -f "$DEV")"
findmnt "$MNT"; findmnt /var/lib/docker; findmnt /var/lib/containerd
if command -v docker >/dev/null; then
  docker info 2>/dev/null | grep -iE 'docker root dir|storage driver|driver-type' || true
fi
cat <<EOF

Next: reboot and verify (see README, "Pruebas"):
  1. Normal reboot      -> /data mounted, docker running.
  2. Tang down + reboot -> system boots, /data closed, docker stopped.
     Unlock manually:   sudo cryptsetup open $DEV $NAME && sudo mount -a && sudo systemctl start docker
EOF
