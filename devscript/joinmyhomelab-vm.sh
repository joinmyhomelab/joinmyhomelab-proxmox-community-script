#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: BASH3R
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main}"
source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/pve/vm-core.func")
load_functions

GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
METHOD=""
APP="Join My Homelab"
APP_TYPE="vm"
NSAPP="joinmyhomelab-vm"
var_os="talos"
var_version="n.d."

THIN="discard=on,ssd=1,"

header_info
echo -e "\n Loading..."
set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "130"' SIGINT
trap 'post_update_to_api "failed" "143"' SIGTERM
trap 'post_update_to_api "failed" "129"; exit 129' SIGHUP

vm_require_arch amd64

TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

# The image is personal: it is built per account and carries that account's
# join token. It is read from the environment first (VM_UNATTENDED runs), and
# only asked for when it is missing.
var_iso_url="${var_iso_url:-}"

function default_settings() {
  vm_apply_machine_type "q35"
  VMID=$(get_valid_nextid)
  DISK_SIZE="50G"
  HN="joinmyhomelab-node"
  CPU_TYPE=" -cpu host"
  CORE_COUNT="4"
  RAM_SIZE="8192"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  START_VM="yes"
  METHOD="default"
  vm_echo_default_settings
}

function advanced_settings() {
  METHOD="advanced"
  vm_prompt_vmid "${VMID:-$(get_valid_nextid)}"
  vm_prompt_machine_type "q35"
  vm_prompt_disk_size "50G"
  vm_prompt_disk_cache "none"
  vm_prompt_hostname "joinmyhomelab-node"
  vm_prompt_cpu_model "host"
  vm_prompt_cpu_cores "4"
  vm_prompt_ram "8192"
  vm_prompt_bridge "vmbr0"
  vm_prompt_mac "$GEN_MAC"
  vm_prompt_vlan
  vm_prompt_mtu
  vm_prompt_start_vm "yes"

  if vm_confirm_advanced_settings "Ready to create a Join My Homelab node?"; then
    echo -e "${CREATING}${BOLD}${DGN}Creating a Join My Homelab node using the above advanced settings${CL}"
  else
    header_info
    echo -e "${ADVANCED}${BOLD}${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

vm_preflight
vm_start_script "Use Default Settings?\n\nDefaults:\n• 4 CPU Cores\n• 8 GB RAM\n• 50 GB Disk\n• Nested virtualisation required" 14 58
post_to_api_vm

if [[ -z "$var_iso_url" ]]; then
  echo -e "\n${INFO}${BOLD}${YW}Personal image required${CL}"
  echo -e "${TAB}Open ${BL}https://joinmyhomelab.com${CL}, run ${BL}ssh dashboard@joinmyhomelab.com${CL}"
  echo -e "${TAB}and copy the link under ${BL}Download your ISO${CL}."
  read -r -p "${TAB}ISO URL: " var_iso_url
fi
if [[ ! "$var_iso_url" =~ ^https?:// ]]; then
  msg_error "The image URL must start with http:// or https://"
  exit 210
fi

# The node runs KVM inside the VM, so the host must expose nested
# virtualisation. Joining still works without it; starting VMs on the node
# does not. Warn, never change the host.
nested="unknown"
[[ -r /sys/module/kvm_intel/parameters/nested ]] && nested="$(cat /sys/module/kvm_intel/parameters/nested)"
[[ -r /sys/module/kvm_amd/parameters/nested ]] && nested="$(cat /sys/module/kvm_amd/parameters/nested)"
case "$nested" in
Y | 1 | y) ;;
*)
  msg_warn "Nested virtualisation is off: the node joins, but VMs on it will not start."
  echo -e "${TAB}Enable it: echo 'options kvm_intel nested=1' > /etc/modprobe.d/kvm-nested.conf (kvm_amd on AMD), then reboot."
  ;;
esac

vm_select_storage "$HN"

ISO_NAME="joinmyhomelab-node.iso"
vm_select_iso_storage "$ISO_NAME" "$HN"
CACHE_FILE="$ISO_PATH"

msg_info "Downloading the Join My Homelab image (about 350 MB)"
vm_fetch_image "$var_iso_url" "$CACHE_FILE" --cache --min-bytes $((100 * 1024 * 1024)) || exit 115

msg_info "Creating a Join My Homelab node"
qm create "$VMID"${MACHINE}${CPU_TYPE} -cores "$CORE_COUNT" -memory "$RAM_SIZE" -name "$HN" \
  -tags community-script,joinmyhomelab -net0 "virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU" -onboot 1 \
  -ostype l26 -scsihw virtio-scsi-single -serial0 socket -vga std \
  -scsi0 "${STORAGE}:${DISK_SIZE%G},${DISK_CACHE:-}${THIN%,}" \
  -ide2 "$ISO_VOLUME,media=cdrom" -boot order='scsi0;ide2' >/dev/null

set_description
msg_ok "Created a Join My Homelab node ${CL}${BL}(${HN})"

if [ "$START_VM" == "yes" ]; then
  msg_info "Starting the node"
  $STD qm start "$VMID"
  msg_ok "Started the node"
fi

post_update_to_api "done" "none"

echo -e "\n${INFO}${BOLD}${YW}Next Steps:${CL}"
echo -e "${TAB}1. Open the VM console in Proxmox (noVNC) to watch the install."
echo -e "${TAB}2. It installs itself, reboots, and joins the cluster — a few minutes."
echo -e "${TAB}3. ${BL}ssh dashboard@joinmyhomelab.com${CL} → NODES shows it green when ready."
echo -e "${TAB}4. To stop lending, shut the VM down; to leave, delete it."
echo -e "${TAB}   ${BL}qm stop ${VMID}${CL} / ${BL}qm destroy ${VMID} --purge 1${CL}"

msg_ok "Completed successfully!\n"