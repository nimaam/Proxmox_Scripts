#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Proxmox VM Migration Script (Interactive Mode)
# =============================================================================
#
# This script migrates a VM between two independent Proxmox servers.
# All parameters are asked interactively during execution.
#
# USAGE:
#   ./migrate.sh
#
# The script will prompt for:
#   - Source server IP, password
#   - Target server IP, password
#   - VMID (source) and Target VMID
#   - Target storage name
# =============================================================================

# --- Colors for better output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Default values ---
SOURCE_USER="root"
TARGET_USER="root"
DUMP_DIR="/tmp/vm-migrate"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

# --- Function to read password securely ---
read_password() {
    local prompt="$1"
    local password=""
    local char=""
    local input=""
    
    echo -n "$prompt"
    stty -echo
    while IFS= read -r -s -n1 char; do
        if [[ -z "$char" ]]; then
            break
        elif [[ "$char" == $'\x7f' ]]; then
            if [[ -n "$password" ]]; then
                password="${password%?}"
                echo -ne "\b \b"
            fi
        else
            password+="$char"
            echo -n "*"
        fi
    done
    stty echo
    echo
    echo "$password"
}

# --- Header ---
clear
echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}      Proxmox VM Migration Script (Interactive)${NC}"
echo -e "${GREEN}======================================================${NC}"
echo ""
echo -e "${CYAN}This script will migrate a VM from one Proxmox server to another.${NC}"
echo -e "${CYAN}You will be asked for all required information step by step.${NC}"
echo ""

# --- Get source server information ---
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}📡 SOURCE SERVER INFORMATION${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

read -p "Source Server IP (e.g., 31.172.80.199): " SOURCE_IP
while [[ -z "$SOURCE_IP" ]]; do
    echo -e "${RED}❌ IP cannot be empty.${NC}"
    read -p "Source Server IP: " SOURCE_IP
done

SOURCE_PASS=$(read_password "Source Server Password: ")
while [[ -z "$SOURCE_PASS" ]]; do
    echo -e "${RED}❌ Password cannot be empty.${NC}"
    SOURCE_PASS=$(read_password "Source Server Password: ")
done

echo ""

# --- Get VM ID ---
read -p "VM ID on Source Server (e.g., 101): " VMID
while [[ -z "$VMID" || ! "$VMID" =~ ^[0-9]+$ ]]; do
    echo -e "${RED}❌ Please enter a valid numeric VM ID.${NC}"
    read -p "VM ID on Source Server: " VMID
done

echo ""

# --- Get target server information ---
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}🎯 TARGET SERVER INFORMATION${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

read -p "Target Server IP (e.g., 31.172.80.11): " TARGET_IP
while [[ -z "$TARGET_IP" ]]; do
    echo -e "${RED}❌ IP cannot be empty.${NC}"
    read -p "Target Server IP: " TARGET_IP
done

TARGET_PASS=$(read_password "Target Server Password: ")
while [[ -z "$TARGET_PASS" ]]; do
    echo -e "${RED}❌ Password cannot be empty.${NC}"
    TARGET_PASS=$(read_password "Target Server Password: ")
done

echo ""

# --- Get target VM ID ---
read -p "New VM ID on Target Server (e.g., 100): " TARGET_VMID
while [[ -z "$TARGET_VMID" || ! "$TARGET_VMID" =~ ^[0-9]+$ ]]; do
    echo -e "${RED}❌ Please enter a valid numeric VM ID.${NC}"
    read -p "New VM ID on Target Server: " TARGET_VMID
done

echo ""

# --- Get target storage ---
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}💾 TARGET STORAGE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}Common storage names: local, local-lvm, vm-lvm, vm_storage${NC}"
echo -e "${YELLOW}To see available storages on target, run: pvesm status${NC}"
echo ""

read -p "Target Storage Name (e.g., vm-lvm): " TARGET_STORAGE
while [[ -z "$TARGET_STORAGE" ]]; do
    echo -e "${RED}❌ Storage name cannot be empty.${NC}"
    read -p "Target Storage Name: " TARGET_STORAGE
done

echo ""

# --- Summary and confirmation ---
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}📋 MIGRATION SUMMARY${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}Source Server:${NC}     $SOURCE_IP"
echo -e "  ${CYAN}Source VM ID:${NC}      $VMID"
echo -e "  ${CYAN}Target Server:${NC}     $TARGET_IP"
echo -e "  ${CYAN}Target VM ID:${NC}      $TARGET_VMID"
echo -e "  ${CYAN}Target Storage:${NC}    $TARGET_STORAGE"
echo ""
echo -e "${YELLOW}⚠️  Important:${NC}"
echo -e "  - Source VM will be ${RED}stopped${NC} during migration"
echo -e "  - Destination VM will get ${YELLOW}new MAC addresses${NC} (--unique 1)"
echo -e "  - Temporary files will be ${GREEN}automatically cleaned up${NC}"
echo ""

read -p "Proceed with migration? (y/N): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}❌ Migration cancelled.${NC}"
    exit 0
fi

echo ""

# =============================================================================
# MIGRATION STARTS HERE
# =============================================================================

# --- Helper functions ---
run_remote() {
    local ip="$1"
    local user="$2"
    local pass="$3"
    local cmd="$4"
    sshpass -p "$pass" ssh $SSH_OPTS "$user@$ip" "$cmd"
}

# --- Start migration ---
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}           Proxmox VM Migration Started${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "${BLUE}Source:${NC}       $SOURCE_IP ($SOURCE_USER)"
echo -e "${BLUE}Destination:${NC}  $TARGET_IP ($TARGET_USER)"
echo -e "${BLUE}Storage:${NC}      $TARGET_STORAGE"
echo -e "${BLUE}Source VMID:${NC}  $VMID -> ${BLUE}Target VMID:${NC} $TARGET_VMID"
echo -e "${GREEN}======================================================${NC}"
echo ""

# --- 1. Check SSH connectivity ---
echo -e "${YELLOW}[1/8] Testing SSH connectivity...${NC}"
if ! run_remote "$SOURCE_IP" "$SOURCE_USER" "$SOURCE_PASS" "echo 'OK'" &>/dev/null; then
    echo -e "${RED}❌ Cannot connect to source server! Check IP and password.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Source SSH OK${NC}"

if ! run_remote "$TARGET_IP" "$TARGET_USER" "$TARGET_PASS" "echo 'OK'" &>/dev/null; then
    echo -e "${RED}❌ Cannot connect to target server! Check IP and password.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Target SSH OK${NC}"

# --- 2. Check VM exists on source ---
echo -e "${YELLOW}[2/8] Checking VM $VMID on source...${NC}"
if ! run_remote "$SOURCE_IP" "$SOURCE_USER" "$SOURCE_PASS" "test -f /etc/pve/qemu-server/${VMID}.conf"; then
    echo -e "${RED}❌ VM $VMID not found on source server!${NC}"
    exit 1
fi
echo -e "${GREEN}✅ VM config found.${NC}"

# --- 3. Check if VM is a template ---
echo -e "${YELLOW}[3/8] Checking if VM is a template...${NC}"
IS_TEMPLATE=$(run_remote "$SOURCE_IP" "$SOURCE_USER" "$SOURCE_PASS" "qm config $VMID 2>/dev/null | grep -c '^template: 1' || true")
if [[ "$IS_TEMPLATE" -eq 1 ]]; then
    echo -e "${YELLOW}⚠️  Template detected. Converting to normal VM temporarily...${NC}"
    run_remote "$SOURCE_IP" "$SOURCE_USER" "$SOURCE_PASS" "qm set $VMID --template 0"
fi
echo -e "${GREEN}✅ Done.${NC}"

# --- 4. Stop VM if running ---
echo -e "${YELLOW}[4/8] Checking VM status...${NC}"
STATUS=$(run_remote "$SOURCE_IP" "$SOURCE_USER" "$SOURCE_PASS" "qm status $VMID 2>/dev/null | grep -o 'running\|stopped' || echo 'stopped'")
echo "VM Status: $STATUS"

if [[ "$STATUS" == "running" ]]; then
    echo -e "${YELLOW}⚠️  VM is running. Stopping...${NC}"
    run_remote "$SOURCE_IP" "$SOURCE_USER" "$SOURCE_PASS" "qm stop $VMID --timeout 60"
    sleep 5
    echo -e "${GREEN}✅ VM stopped.${NC}"
else
    echo -e "${GREEN}✅ VM already stopped.${NC}"
fi

# --- 5. Create backup ---
echo -e "${YELLOW}[5/8] Creating vzdump backup (this may take a while)...${NC}"
run_remote "$SOURCE_IP" "$SOURCE_USER" "$SOURCE_PASS" "mkdir -p $DUMP_DIR"
run_remote "$SOURCE_IP" "$SOURCE_USER" "$SOURCE_PASS" "vzdump $VMID --dumpdir $DUMP_DIR --mode stop --compress zstd"
echo -e "${GREEN}✅ Backup created.${NC}"

# --- 6. Locate backup file ---
echo -e "${YELLOW}[6/8] Locating backup file...${NC}"
DUMP_FILE=$(run_remote "$SOURCE_IP" "$SOURCE_USER" "$SOURCE_PASS" "ls -t $DUMP_DIR/vzdump-qemu-${VMID}-*.vma.zst 2>/dev/null | head -1")
if [[ -z "$DUMP_FILE" ]]; then
    echo -e "${RED}❌ Backup file not found!${NC}"
    [[ "$IS_TEMPLATE" -eq 1 ]] && run_remote "$SOURCE_IP" "$SOURCE_USER" "$SOURCE_PASS" "qm set $VMID --template 1"
    exit 1
fi
DUMP_BASE=$(basename "$DUMP_FILE")
DUMP_SIZE=$(run_remote "$SOURCE_IP" "$SOURCE_USER" "$SOURCE_PASS" "du -h '$DUMP_FILE' | cut -f1")
echo -e "${GREEN}✅ Backup: $DUMP_BASE ($DUMP_SIZE)${NC}"

# --- 7. Transfer to destination ---
echo -e "${YELLOW}[7/8] Transferring backup to destination (scp)...${NC}"
run_remote "$TARGET_IP" "$TARGET_USER" "$TARGET_PASS" "mkdir -p $DUMP_DIR"

echo "   ⬇️  Downloading from source..."
sshpass -p "$SOURCE_PASS" scp $SSH_OPTS "$SOURCE_USER@$SOURCE_IP:$DUMP_FILE" "$DUMP_DIR/"

echo "   ⬆️  Uploading to destination..."
sshpass -p "$TARGET_PASS" scp $SSH_OPTS "$DUMP_DIR/$DUMP_BASE" "$TARGET_USER@$TARGET_IP:$DUMP_DIR/"

echo -e "${GREEN}✅ Transfer completed.${NC}"

# --- 8. Restore on destination ---
echo -e "${YELLOW}[8/8] Restoring VM on destination (qmrestore)...${NC}"
run_remote "$TARGET_IP" "$TARGET_USER" "$TARGET_PASS" "qmrestore '$DUMP_DIR/$DUMP_BASE' $TARGET_VMID --storage $TARGET_STORAGE --unique 1"
echo -e "${GREEN}✅ Restore completed.${NC}"

# --- Cleanup ---
echo -e "${YELLOW}🧹 Cleaning up temporary files...${NC}"
rm -f "$DUMP_DIR/$DUMP_BASE"
run_remote "$SOURCE_IP" "$SOURCE_USER" "$SOURCE_PASS" "rm -f '$DUMP_FILE'"
run_remote "$TARGET_IP" "$TARGET_USER" "$TARGET_PASS" "rm -f '$DUMP_DIR/$DUMP_BASE'"

# --- Restore template state on source ---
if [[ "$IS_TEMPLATE" -eq 1 ]]; then
    echo -e "${YELLOW}Restoring source VM back to template...${NC}"
    run_remote "$SOURCE_IP" "$SOURCE_USER" "$SOURCE_PASS" "qm set $VMID --template 1"
fi

# --- Done ---
echo ""
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}               ✅ MIGRATION COMPLETED!${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "${BLUE}Source VMID:${NC}      $VMID (on $SOURCE_IP)"
echo -e "${BLUE}Target VMID:${NC}      $TARGET_VMID (on $TARGET_IP)"
echo -e "${BLUE}Target Storage:${NC}   $TARGET_STORAGE"
echo -e "${GREEN}======================================================${NC}"
echo ""
echo -e "${CYAN}You can now start the VM on destination:${NC}"
echo -e "  ssh root@$TARGET_IP 'qm start $TARGET_VMID'"
echo ""
