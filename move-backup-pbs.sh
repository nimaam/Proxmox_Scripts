#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# VM Migration Script with PBS Support: SOURCE <-> Destination (Cross-Datacenter)
# =============================================================================
#
# USAGE:
#   ./move-pbs.sh <VMID> <TARGET_IP> <TARGET_STORAGE> [TARGET_VMID] [OPTIONS]
#   ./move-pbs.sh --help
#
# OPTIONS:
#   --pbs-source <STORAGE_NAME>      Use specified PBS storage for backup on source
#   --pbs-dest <STORAGE_NAME>        Use specified PBS storage for restore on target
#
# EXAMPLES:
#   ./move-pbs.sh 9000 149.102.255.11 local-zfs --pbs-source pbs-backup --pbs-dest pbs-backup
# =============================================================================

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# --- Parse Arguments ---
VMID=""
TARGET_HOST=""
TARGET_STORAGE=""
TARGET_VMID=""
PBS_SOURCE=""
PBS_DEST=""

# Check for help flag early
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            echo "============================================================================="
            echo " Proxmox Cross-Datacenter VM Migration Script with PBS Support"
            echo "============================================================================="
            echo " USAGE:"
            echo "   ./move-pbs.sh <VMID> <TARGET_IP> <TARGET_STORAGE> [TARGET_VMID] [OPTIONS]"
            echo ""
            echo " OPTIONS:"
            echo "   --pbs-source <NAME>   PBS storage name on source for backup"
            echo "   --pbs-dest <NAME>     PBS storage name on target for restore"
            echo ""
            echo " EXAMPLES:"
            echo "   ./move-pbs.sh 9000 149.102.255.11 local-zfs"
            echo "   ./move-pbs.sh 9000 149.102.255.11 local-zfs --pbs-source my-pbs --pbs-dest my-pbs"
            echo "============================================================================="
            exit 0
            ;;
    esac
done

# Positional arguments collection
POSITIONAL_ARGS=()
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --pbs-source) PBS_SOURCE="$2"; shift 2 ;;
        --pbs-dest) PBS_DEST="$2"; shift 2 ;;
        *) POSITIONAL_ARGS+=("$1"); shift ;;
    esac
done

VMID="${POSITIONAL_ARGS[0]:?ERROR: VMID not specified! For help, run: ./move-pbs.sh --help}"
TARGET_HOST="${POSITIONAL_ARGS[1]:?ERROR: Target IP not specified!}"
TARGET_STORAGE="${POSITIONAL_ARGS[2]:?ERROR: Target Storage not specified!}"
TARGET_VMID="${POSITIONAL_ARGS[3]:-$VMID}"

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

# --- SSH Helper Functions ---
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

DUMP_DIR="/tmp/vm-migrate"

echo "============================================"
echo "  VM Migration: $VMID -> $TARGET_VMID"
echo "  Target IP: $TARGET_HOST"
echo "  Storage: $TARGET_STORAGE"
if [ -n "$PBS_SOURCE" ]; then echo "  PBS Source: $PBS_SOURCE"; fi
if [ -n "$PBS_DEST" ]; then echo "  PBS Destination: $PBS_DEST"; fi
echo "============================================"

# --- 1. Check if VM exists ---
if ! STATUS=$(qm status "$VMID" 2>&1); then
    echo "ERROR: VM $VMID not found!"[cite: 1]
    exit 1
fi
echo "[1/6] VM status: $STATUS"[cite: 1]

# --- 2. Template handling ---
IS_TEMPLATE=$(qm config "$VMID" | grep -c "^template: 1" || true)
if [ "$IS_TEMPLATE" -eq 1 ]; then
    echo "[2/6] Converting Template -> Normal VM..."[cite: 1]
    qm set "$VMID" --template 0
else
    echo "[2/6] Not a template, continuing."[cite: 1]
fi

# --- 3. Stop running VM ---
if echo "$STATUS" | grep -q "running"; then
    echo "[3/6] VM is running, stopping..."[cite: 1]
    qm stop "$VMID" --timeout 60[cite: 1]
    sleep 3
else
    echo "[3/6] VM is already stopped."[cite: 1]
fi

# --- 4. Backup Execution (PBS vs Local Zstd) ---
if [ -n "$PBS_SOURCE" ]; then
    echo "[4/6] Creating backup directly to PBS storage ($PBS_SOURCE)..."
    vzdump "$VMID" --storage "$PBS_SOURCE" --mode stop 2>&1
    
    # Retrieve latest snapshot identifier from PBS API/CLI for this VM
    # Proxmox stores PBS snapshots in format: vzdump:backup/qemu/VMID/YYYY-MM-DDTHH:MM:SSZ
    # Let's query the newest snapshot string using pvesm
    PBS_SNAPSHOT=$(pvesm list "$PBS_SOURCE" --content backup | grep "qemu/$VMID/" | sort -r | head -n1 | awk '{print $1}')
    if [ -z "$PBS_SNAPSHOT" ]; then
        echo "ERROR: Could not find backup snapshot on PBS storage $PBS_SOURCE!"
        [ "$IS_TEMPLATE" -eq 1 ] && qm set "$VMID" --template 1
        exit 1
   [cite: 1] fi
    echo "        PBS Snapshot found: $PBS_SNAPSHOT"
else
    echo "[4/6] Creating local compressed backup (vzdump --compress zstd)..."[cite: 1]
    mkdir -p "$DUMP_DIR"
    vzdump "$VMID" --dumpdir "$DUMP_DIR" --mode stop --compress zstd 2>&1[cite: 1]

    DUMP_FILE=$(ls -t "$DUMP_DIR"/vzdump-qemu-"$VMID"-*.vma.zst 2>/dev/null | head -1)
    if [ -z "$DUMP_FILE" ]; then
        echo "ERROR: Backup file could not be created!"[cite: 1]
        [ "$IS_TEMPLATE" -eq 1 ] && qm set "$VMID" --template 1[cite: 1]
        exit 1
   [cite: 1] fi
    DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)[cite: 1]
    echo "        Backup: $(basename "$DUMP_FILE") ($DUMP_SIZE)"[cite: 1]
fi

# --- 5. Transfer Step ---
if [ -n "$PBS_SOURCE" ]; then
    echo "[5/6] Skipping SCP transfer (Using shared PBS datastore)..."
else
    echo "[5/6] Copying file to target (scp -> $TARGET_HOST)..."[cite: 1]
    run_ssh root@"$TARGET_HOST" "mkdir -p $DUMP_DIR"[cite: 1]
    run_scp "$DUMP_FILE" root@"$TARGET_HOST":"$DUMP_DIR"/[cite: 1]
    DUMP_BASE=$(basename "$DUMP_FILE")[cite: 1]
fi

# --- 6. Restore on Target ---
echo "[6/6] Restoring on target (qmrestore -> $TARGET_STORAGE)..."[cite: 1]
if [ -n "$PBS_DEST" ]; then
    # Restore straight from PBS storage name & snapshot reference
    run_ssh root@"$TARGET_HOST" "qmrestore '$PBS_DEST:$PBS_SNAPSHOT' $TARGET_VMID --storage $TARGET_STORAGE --unique 1"
else
    # Restore from local archive file transferred via scp
    run_ssh root@"$TARGET_HOST" "qmrestore '$DUMP_DIR/$DUMP_BASE' $TARGET_VMID --storage $TARGET_STORAGE --unique 1"[cite: 1]
fi

# --- Cleanup ---
echo ""
echo "Cleaning up temporary files..."[cite: 1]
if [ -n "$PBS_SOURCE" ]; then
    # Optional: If you want to prune old snapshots you can handle it here, but we leave the PBS snapshot intact for safety.
    true
else
    rm -f "$DUMP_FILE"[cite: 1]
    run_ssh root@"$TARGET_HOST" "rm -f '$DUMP_DIR/$DUMP_BASE'"[cite: 1]
fi

# --- Revert Template Status ---
if [ "$IS_TEMPLATE" -eq 1 ]; then
    echo "Reverting source VM back to template..."[cite: 1]
    qm set "$VMID" --template 1[cite: 1]
fi

echo ""
echo "============================================"
echo "  COMPLETED!"[cite: 1]
echo "  VM $TARGET_VMID -> $TARGET_HOST ($TARGET_STORAGE)"[cite: 1]
echo "============================================"
