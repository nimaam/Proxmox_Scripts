#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# VM Migration Script: SOURCE <-> Destination (Cross-Datacenter)
# =============================================================================
#
# Cross-datacenter Proxmox cluster VM migration script.
# Works between different nodes/datacenters.
#
# WHY vzdump/scp/qmrestore?
# ---------------------------
# Proxmox's native "qm remote-migrate" command does not support migration
# between different storage backends (e.g., ZFS vs LVM-Thin).
# Therefore, we use the storage-agnostic method:
# vzdump (backup) -> scp (transfer) -> qmrestore (restore).
#
# HOW IT WORKS:
# ----------------
# 1. Takes a zstd-compressed backup of the VM on the source node using vzdump.
# 2. Copies the backup file to the destination node via scp.
# 3. Restores the VM on the destination node using qmrestore.
# 4. Cleans up temporary files.
#
# USAGE:
#   ./move.sh <VMID> <TARGET_IP> <TARGET_STORAGE> [TARGET_VMID]
#   ./move.sh --help
#
# EXAMPLES:
#   ./move.sh 9000 149.102.255.11 local-zfs           # Move VM 9000 to target with same ID
#   ./move.sh 9000 149.102.255.11 local 9001          # Move VM 9000 to target as VM 9001
#
# NOTE: This script must be run on the SOURCE node (where the VM currently resides)
# =============================================================================

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# --- Check for Help Flag ---
case "${1:-}" in
    --help|-h)
        echo "============================================================================="
        echo " Proxmox Cross-Datacenter VM Migration Script"
        echo "============================================================================="
        echo " USAGE:"
        echo "   ./move.sh <VMID> <TARGET_IP> <TARGET_STORAGE> [TARGET_VMID]"
        echo "   ./move.sh --help"
        echo ""
        echo " ABOUT STORAGE (Target Storage):"
        echo "   The <TARGET_STORAGE> parameter specifies where the VM disks will be stored"
        echo "   on the destination Proxmox node (e.g., 'local', 'local-lvm', 'local-zfs',"
        echo "   or a shared storage pool name like 'ceph-storage')."
        echo ""
        echo " EXAMPLES:"
        echo "   ./move.sh 9000 149.102.255.11 local-zfs           # Migrate with same ID"
        echo "   ./move.sh 9000 149.102.255.11 local 9001          # Migrate and change ID to 9001"
        echo "============================================================================="
        exit 0
        ;;
esac

# --- Parameters ---
VMID=${1:?"ERROR: VMID not specified! For help, run: ./move.sh --help"}
TARGET_HOST=${2:?"ERROR: Target IP (TARGET_IP) not specified! For help, run: ./move.sh --help"}
TARGET_STORAGE=${3:?"ERROR: Target Storage not specified! For help, run: ./move.sh --help"}
TARGET_VMID=${4:-$VMID}

# --- Check and Install sshpass if missing ---
if ! command -v sshpass &> /dev/null; then
    echo "INFO: 'sshpass' is not installed. Installing it automatically..."
    apt-get update -y && apt-get install -y sshpass
fi

# --- Interactive Password Prompt ---
TARGET_PASSWORD=""
echo -n "Enter root password for target Proxmox ($TARGET_HOST) (Press ENTER if using SSH keys): "
read -rs TARGET_PASSWORD
echo ""

# --- SSH / SCP Helper Functions (For password support) ---
run_ssh() {
    if [ -n "$TARGET_PASSWORD" ]; then
        sshpass -p "$TARGET_PASSWORD" ssh $SSH_OPTS "$@"
    else
        ssh $SSH_OPTS "$@"
    fi
}

run_scp() {
    if [ -n "$TARGET_PASSWORD" ]; then
        sshpass -p "$TARGET_PASSWORD" scp $SSH_OPTS "$@"
    else
        scp $SSH_OPTS "$@"
    fi
}

# --- Temporary directory: Using /tmp (safer than RAM disk for large VMs) ---
DUMP_DIR="/tmp/vm-migrate"

echo "============================================"
echo "  VM Migration: $VMID -> $TARGET_VMID"
echo "  Target IP: $TARGET_HOST"
echo "  Storage: $TARGET_STORAGE"
echo "============================================"

# --- 1. Check if VM exists ---
if ! STATUS=$(qm status "$VMID" 2>&1); then
    echo "ERROR: VM $VMID not found!"
    exit 1
fi
echo "[1/6] VM status: $STATUS"

# --- 2. If it's a template, temporarily convert it to a normal VM ---
# vzdump cannot back up template VMs directly; it needs to be a regular VM first.
IS_TEMPLATE=$(qm config "$VMID" | grep -c "^template: 1" || true)
if [ "$IS_TEMPLATE" -eq 1 ]; then
    echo "[2/6] Converting Template -> Normal VM (required for vzdump)..."
    qm set "$VMID" --template 0
else
    echo "[2/6] Not a template, continuing."
fi

# --- 3. Stop running VM ---
if echo "$STATUS" | grep -q "running"; then
    echo "[3/6] VM is running, stopping..."
    qm stop "$VMID" --timeout 60
    sleep 3
else
    echo "[3/6] VM is already stopped."
fi

# --- 4. Take backup with vzdump ---
# --compress zstd: fast compression, reduces file size significantly
# --mode stop: takes a consistent backup while VM is stopped
mkdir -p "$DUMP_DIR"
echo "[4/6] Creating backup (vzdump --compress zstd)..."
vzdump "$VMID" --dumpdir "$DUMP_DIR" --mode stop --compress zstd 2>&1

# Find the generated backup file (the newest one)
DUMP_FILE=$(ls -t "$DUMP_DIR"/vzdump-qemu-"$VMID"-*.vma.zst 2>/dev/null | head -1)
if [ -z "$DUMP_FILE" ]; then
    echo "ERROR: Backup file could not be created!"
    [ "$IS_TEMPLATE" -eq 1 ] && qm set "$VMID" --template 1
    exit 1
fi
DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
echo "        Backup: $(basename "$DUMP_FILE") ($DUMP_SIZE)"

# --- 5. Copy to target via scp ---
echo "[5/6] Copying to target (scp -> $TARGET_HOST)..."
run_ssh root@"$TARGET_HOST" "mkdir -p $DUMP_DIR"
run_scp "$DUMP_FILE" root@"$TARGET_HOST":"$DUMP_DIR"/

DUMP_BASE=$(basename "$DUMP_FILE")

# --- 6. Restore on target using qmrestore ---
# --storage: target storage backend
# --unique 1: generates new MAC addresses to prevent IP conflicts
echo "[6/6] Restoring on target (qmrestore -> $TARGET_STORAGE)..."
run_ssh root@"$TARGET_HOST" "qmrestore '$DUMP_DIR/$DUMP_BASE' $TARGET_VMID --storage $TARGET_STORAGE --unique 1"

# --- Cleanup ---
echo ""
echo "Cleaning up temporary files..."
rm -f "$DUMP_FILE"
run_ssh root@"$TARGET_HOST" "rm -f '$DUMP_DIR/$DUMP_BASE'"

# --- Revert source template status if applicable ---
if [ "$IS_TEMPLATE" -eq 1 ]; then
    echo "Reverting source VM back to template..."
    qm set "$VMID" --template 1
fi

echo ""
echo "============================================"
echo "  COMPLETED!"
echo "  VM $TARGET_VMID -> $TARGET_HOST ($TARGET_STORAGE)"
echo "============================================"
