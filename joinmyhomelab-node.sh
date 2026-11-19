#!/usr/bin/env bash
#
# Join My Homelab — Proxmox VE node installer.
#
# Creates one VM that boots your personal Join My Homelab image, installs
# itself and joins the community cluster. The VM is the node: stop it to stop
# lending, delete it to leave. Nothing else on the host is touched.
#
#   bash joinmyhomelab-node.sh --iso https://.../joinmyhomelab-<acct>.iso
#
# MIT licensed. See README.md.
set -euo pipefail

VERSION="1.0.0"
PREFIX="joinmyhomelab-node"
DEFAULT_CORES=4
DEFAULT_RAM=8192
DEFAULT_DISK=50
DEFAULT_BRIDGE="vmbr0"
ISO_DIR="/var/lib/vz/template/iso"
ISO_STORAGE=""
MIN_ISO_BYTES=$((100 * 1024 * 1024))

VMID=""
NAME=""
CORES="$DEFAULT_CORES"
RAM="$DEFAULT_RAM"
DISK="$DEFAULT_DISK"
BRIDGE="$DEFAULT_BRIDGE"
STORAGE=""
ISO_URL="${RMHL_ISO_URL:-}"
ISO_FILE="${RMHL_ISO_FILE:-}"
DRY_RUN=0
ASSUME_YES=0
ENABLE_NESTED=0
UNINSTALL=0

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: joinmyhomelab-node.sh [options]

  --iso URL        personal ISO from your dashboard (or set RMHL_ISO_URL)
  --iso-file PATH  use an ISO already on this host instead of downloading
  --name NAME      VM name (default: joinmyhomelab-node-<n>)
  --vmid ID        VM id (default: first free id from 900)
  --cores N        cpu cores (default: 4)
  --ram MB         memory in MiB (default: 8192)
  --disk GB        disk in GiB (default: 50)
  --bridge BR      network bridge (default: vmbr0)
  --storage ST     storage for the disk (default: auto)
  --enable-nested  enable nested virtualisation if it is off
  --uninstall      stop and delete the node VM(s), then exit
  --dry-run        print the commands, change nothing
  -y, --yes        do not ask questions
  -h, --help       this text
  -V, --version    print the version

The ISO URL contains your account token. It is never printed or logged.
USAGE
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO_URL="${2:-}"; shift 2 ;;
    --iso-file) ISO_FILE="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; shift 2 ;;
    --vmid) VMID="${2:-}"; shift 2 ;;
    --cores) CORES="${2:-}"; shift 2 ;;
    --ram) RAM="${2:-}"; shift 2 ;;
    --disk) DISK="${2:-}"; shift 2 ;;
    --bridge) BRIDGE="${2:-}"; shift 2 ;;
    --storage) STORAGE="${2:-}"; shift 2 ;;
    --enable-nested) ENABLE_NESTED=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) say "joinmyhomelab-node.sh $VERSION"; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local answer
  read -r -p "$1 [y/N] " answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+ %s\n' "$*"
    return 0
  fi
  "$@"
}

is_pve() { command -v qm >/dev/null 2>&1 && [ -d /etc/pve ]; }

# --- vm id, name, storage -------------------------------------------------

next_vmid() {
  local id=900
  while qm status "$id" >/dev/null 2>&1; do
    id=$((id + 1))
    [ "$id" -gt 999 ] && die "no free VM id between 900 and 999 (use --vmid)"
  done
  printf '%s' "$id"
}

next_name() {
  if [ -n "$NAME" ]; then return; fi
  if ! command -v qm >/dev/null 2>&1; then NAME="$PREFIX-1"; return; fi
  local max=0 n
  for n in $(qm list 2>/dev/null | awk -v p="$PREFIX" '$2 == p || $2 ~ "^"p"-[0-9]+$" { print $2 }' | sed -E "s/^${PREFIX}-?//"); do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$n" -gt "$max" ] && max="$n"
  done
  NAME="$PREFIX-$((max + 1))"
}

pick_storage() {
  [ -n "$STORAGE" ] && return
  command -v pvesm >/dev/null 2>&1 || { STORAGE="local-lvm"; return; }
  local s
  for s in $(pvesm status --content images 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1 }'); do
    STORAGE="$s"
    return
  done
  STORAGE="local-lvm"
}

# The ISO has to live on a storage that Proxmox knows about, and qm wants
# "storage:iso/file.iso", not a raw path.
pick_iso_storage() {
  [ -n "$ISO_STORAGE" ] && return
  local s
  if command -v pvesm >/dev/null 2>&1; then
    for s in $(pvesm status --content iso 2>/dev/null | awk 'NR > 1 && $3 == "active" { print $1 }'); do
      ISO_STORAGE="$s"
      break
    done
  fi
  [ -n "$ISO_STORAGE" ] || ISO_STORAGE="local"
  if command -v pvesm >/dev/null 2>&1; then
    local p
    p="$(pvesm path "$ISO_STORAGE:iso/.probe" 2>/dev/null || true)"
    if [ -n "$p" ]; then ISO_DIR="$(dirname "$p")"; fi
  fi
}

# --- nested virtualisation ------------------------------------------------

nested_state() {
  local f=""
  [ -r /sys/module/kvm_intel/parameters/nested ] && f=/sys/module/kvm_intel/parameters/nested
  [ -r /sys/module/kvm_amd/parameters/nested ] && f=/sys/module/kvm_amd/parameters/nested
  [ -n "$f" ] || { printf 'unknown'; return; }
  local v
  v="$(cat "$f")"
  case "$v" in Y|1|y) printf 'on' ;; *) printf 'off' ;; esac
}

enable_nested() {
  local vendor
  if grep -qE '(^| )vmx( |$)' /proc/cpuinfo 2>/dev/null; then
    vendor="intel"
  elif grep -qE '(^| )svm( |$)' /proc/cpuinfo 2>/dev/null; then
    vendor="amd"
  else
    die "this cpu reports no virtualisation support (vmx/svm); it cannot host nodes"
  fi
  say "enabling nested virtualisation for kvm_$vendor"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "+ printf 'options kvm_$vendor nested=1' > /etc/modprobe.d/kvm-nested.conf"
    say "+ modprobe -r kvm_$vendor && modprobe kvm_$vendor"
    return 0
  fi
  printf 'options kvm_%s nested=1\n' "$vendor" > /etc/modprobe.d/kvm-nested.conf
  if ! modprobe -r "kvm_$vendor" 2>/dev/null; then
    warn "could not unload kvm_$vendor (VMs may be running) — reboot to apply"
    return 0
  fi
  modprobe "kvm_$vendor" || warn "modprobe failed — reboot to apply"
  if [ "$(nested_state)" = "on" ]; then
    say "nested virtualisation is on"
  else
    warn "nested virtualisation is still off — reboot and re-run if VMs refuse to start"
  fi
}

check_nested() {
  local state
  state="$(nested_state)"
  [ "$state" = "on" ] && return 0
  [ "$state" = "unknown" ] && { warn "cannot tell whether nested virtualisation is enabled"; return 0; }
  warn "nested virtualisation is off: the node can join, but VMs on it will not start"
  if [ "$ENABLE_NESTED" -eq 1 ]; then
    enable_nested
    return 0
  fi
  if [ "$ASSUME_YES" -eq 0 ] && confirm "enable nested virtualisation now?"; then
    enable_nested
    return 0
  fi
  warn "continuing without nested virtualisation (fix later: options kvm_intel nested=1, then reboot)"
}

# --- iso ------------------------------------------------------------------

download_iso() {
  local url="$1" path="$2"
  if [ -n "$ISO_FILE" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
      [ -f "$ISO_FILE" ] || die "no such file: $ISO_FILE"
      [ "$(wc -c < "$ISO_FILE")" -ge "$MIN_ISO_BYTES" ] || die "$ISO_FILE is too small to be an ISO"
      [ "$(dd if="$ISO_FILE" bs=1 skip=32769 count=5 2>/dev/null)" = "CD001" ] || die "$ISO_FILE is not an ISO"
    fi
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    say "+ download <personal iso> -> $path"
    return 0
  fi
  if [ -f "$path" ] && [ "$(wc -c < "$path")" -ge "$MIN_ISO_BYTES" ] \
     && [ "$(dd if="$path" bs=1 skip=32769 count=5 2>/dev/null)" = "CD001" ]; then
    say "using the image already on this host ($(( $(wc -c < "$path") / 1024 / 1024 )) MiB)"
    return 0
  fi
  say "downloading the image (about 350 MiB)…"
  run mkdir -p "$ISO_DIR"
  # The URL carries the account token, so it goes in on stdin (curl -K -)
  # instead of argv, where any user could read it from the process list.
  printf 'url = "%s"\n' "$url" \
    | curl -fsS -L --retry 3 --retry-delay 2 -C - -o "$path.part" -K - \
    || die "download failed (check the ISO link in your dashboard)"
  mv "$path.part" "$path"
  local size
  size="$(wc -c < "$path")"
  [ "$size" -ge "$MIN_ISO_BYTES" ] || die "the image is only $size bytes — download it again"
  [ "$(dd if="$path" bs=1 skip=32769 count=5 2>/dev/null)" = "CD001" ] || die "the file is not an ISO — check the link"
  say "image ready ($((size / 1024 / 1024)) MiB)"
}

# --- uninstall ------------------------------------------------------------

uninstall_nodes() {
  local ids id
  ids="$(qm list 2>/dev/null | awk -v p="$PREFIX" '$2 == p || $2 ~ "^"p"-[0-9]+$" { print $1 }')"
  [ -n "$ids" ] || { say "no node VM found (names: $PREFIX-*)"; return 0; }
  say "this will stop and delete:"
  for id in $ids; do
    say "  $(qm config "$id" 2>/dev/null | awk -F': ' '/^name:/{print $2}') (VM $id)"
  done
  confirm "delete these VMs and their disks?" || { say "nothing changed"; return 0; }
  for id in $ids; do
    run qm stop "$id" || warn "VM $id was not running"
    run qm destroy "$id" --purge 1 --destroy-unreferenced-disks 1
  done
  say "done. Your node disappears from the dashboard shortly."
}

# --- main -----------------------------------------------------------------

[ "$DRY_RUN" -eq 1 ] || need_root

if [ "$DRY_RUN" -eq 0 ] && ! is_pve; then
  die "this does not look like a Proxmox VE host (need qm and /etc/pve)"
fi

if [ "$UNINSTALL" -eq 1 ]; then
  [ "$DRY_RUN" -eq 1 ] || is_pve || die "not a Proxmox host"
  uninstall_nodes
  exit 0
fi

if [ -z "$ISO_URL" ] && [ -z "$ISO_FILE" ]; then
  say "Open your dashboard and copy the personal ISO link:"
  say "  ssh dashboard@joinmyhomelab.com  →  'Download your ISO'"
  read -r -p "ISO URL: " ISO_URL
  [ -n "$ISO_URL" ] || die "an ISO URL is required"
fi

if [ -z "$ISO_FILE" ]; then
  case "$ISO_URL" in
    http://*|https://*) ;;
    *) die "the ISO URL must start with http:// or https://" ;;
  esac
fi

check_nested
pick_storage
pick_iso_storage
next_name

if [ "$DRY_RUN" -eq 0 ]; then
  VMID="${VMID:-$(next_vmid)}"
  qm status "$VMID" >/dev/null 2>&1 && die "VM id $VMID is already in use"
else
  VMID="${VMID:-900}"
fi

if [ -n "$ISO_FILE" ]; then
  iso_path="$ISO_FILE"
else
  iso_path="$ISO_DIR/$PREFIX.iso"
fi
iso_vol="$ISO_STORAGE:iso/$(basename "$iso_path")"

say ""
say "About to create:"
say "  name     $NAME"
say "  vmid     $VMID"
say "  cpu/ram  $CORES cores / $RAM MiB"
say "  disk     $DISK GiB on $STORAGE"
say "  image    $iso_vol"
say "  network  $BRIDGE"
say ""

confirm "create the VM now?" || { say "nothing changed"; exit 0; }

download_iso "$ISO_URL" "$iso_path"

if ! run qm create "$VMID" \
  --name "$NAME" \
  --description "Join My Homelab node — https://joinmyhomelab.com" \
  --tags joinmyhomelab \
  --memory "$RAM" \
  --cores "$CORES" \
  --sockets 1 \
  --cpu host \
  --machine q35 \
  --ostype l26 \
  --scsihw virtio-scsi-single \
  --scsi0 "$STORAGE:$DISK,discard=on,ssd=1" \
  --ide2 "$iso_vol,media=cdrom" \
  --boot "order=scsi0;ide2" \
  --net0 "virtio,bridge=$BRIDGE" \
  --serial0 socket \
  --vga std \
  --onboot 1
then
  die "qm create failed. If it mentions /etc/pve and Permission denied, the cluster is read-only: check 'pvecm status' (it needs quorum)."
fi

run qm start "$VMID"

say ""
say "VM $VMID ($NAME) is starting."
say "It installs itself on first boot, then reboots and joins the cluster."
say ""
say "  watch it:   the Proxmox console (noVNC), or: qm terminal $VMID"
say "  check it:   ssh dashboard@joinmyhomelab.com   →  NODES"
say "  stop it:    qm stop $VMID"
say "  remove it:  $0 --uninstall"
say ""
say "First boot takes a few minutes. Nothing else on this host was changed."