#!/usr/bin/env bash
# Day 9 — INC-006 disk-fill runbook (EC2)
# Safely demonstrates ENOSPC on a bounded 64MB loopback fs.
# The guard on / free space runs FIRST and cannot be bypassed.
#
# ADR-013 pre-flight: port 8080 and port 22 have independent SG rules.
# INC-006 produced an 11-min silent hang because SSH worked but the app port
# was blocked by a stale IP allowlist. Run step 4 before firing any charges.
#
# Usage:
#   sudo ./disk-fill-demo.sh            # setup + fill instructions
#   sudo ./disk-fill-demo.sh --teardown # unmount + remove backing file

set -euo pipefail

BACKING_FILE="/opt/novapay/disktest.img"
MOUNT_POINT="/mnt/novapay-logtest"
BACKING_SIZE="64M"
ROOT_FREE_MIN_KB=$((1 * 1024 * 1024))  # 1G in KB

# ── guard ─────────────────────────────────────────────────────────────────────
# Runs unconditionally, before any other action.
# df -k / → field $4 is "Available" in KB (POSIX-portable).
ROOT_FREE_KB=$(df -k / | awk 'NR==2 {print $4}')

if [ "${ROOT_FREE_KB}" -lt "${ROOT_FREE_MIN_KB}" ]; then
    echo "ERROR: root filesystem has less than 1G free (${ROOT_FREE_KB} KB available)." >&2
    echo "       This script refuses to run. Free space on / before proceeding." >&2
    exit 1
fi

# ── teardown mode ─────────────────────────────────────────────────────────────
teardown() {
    echo "=== TEARDOWN ==="
    echo ""

    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        echo "Unmounting ${MOUNT_POINT}..."
        if ! umount "${MOUNT_POINT}" 2>/dev/null; then
            echo "" >&2
            echo "ERROR: umount ${MOUNT_POINT} failed." >&2
            echo "Most likely cause: a process has its working directory or an open" >&2
            echo "file handle inside ${MOUNT_POINT} (e.g. a shell that cd'd in there," >&2
            echo "or journalctl still tailing a file on that mount)." >&2
            echo "" >&2
            echo "Processes holding the mount open:" >&2
            lsof +D "${MOUNT_POINT}" 2>/dev/null || fuser -vm "${MOUNT_POINT}" 2>/dev/null || true
            echo "" >&2
            echo "Close or kill those processes, then re-run:" >&2
            echo "  sudo ./scripts/disk-fill-demo.sh --teardown" >&2
            exit 1
        fi
        echo "Done."
    else
        echo "(${MOUNT_POINT} is not mounted — skipping umount)"
    fi

    if [ -f "${BACKING_FILE}" ]; then
        echo "Removing backing file ${BACKING_FILE}..."
        rm -f "${BACKING_FILE}"
        echo "Done."
    else
        echo "(${BACKING_FILE} not found — skipping)"
    fi

    if [ -d "${MOUNT_POINT}" ]; then
        echo "Removing mount point ${MOUNT_POINT}..."
        rmdir "${MOUNT_POINT}"
        echo "Done."
    else
        echo "(${MOUNT_POINT} not found — skipping)"
    fi

    echo ""
    echo "=== df -h / (AFTER teardown — root must be reclaimed/unchanged) ==="
    df -h /
    echo ""
    echo "Teardown complete. Restore payment-api to its normal state:"
    echo "  sudo systemctl revert payment-api"
    echo "  sudo systemctl daemon-reload && sudo systemctl restart payment-api"
    echo "  sudo journalctl -u payment-api -n 20  # confirm clean startup"
    echo "  # Then verify invariant: /ec2-invariant"
}

if [ "${1:-}" = "--teardown" ]; then
    teardown
    exit 0
fi

# ── setup ─────────────────────────────────────────────────────────────────────
echo "=== NovaPay INC-006 — disk-fill setup ==="
echo "Guard passed: root has ${ROOT_FREE_KB} KB free (minimum ${ROOT_FREE_MIN_KB} KB)."
echo ""

# Capture BEFORE state — this is snapshot 1 of the safety proof.
echo "=== df -h / (BEFORE — snapshot 1 of 3) ==="
df -h /
echo ""

echo "--- Step 1: create 64MB backing file at ${BACKING_FILE} ---"
fallocate -l "${BACKING_SIZE}" "${BACKING_FILE}"
echo "Created: $(ls -lh "${BACKING_FILE}")"
echo ""

echo "--- Step 2: format as ext4 ---"
mkfs.ext4 -q "${BACKING_FILE}"
echo "Formatted."
echo ""

echo "--- Step 3: create mount point and mount via loop device ---"
mkdir -p "${MOUNT_POINT}"
mount -o loop "${BACKING_FILE}" "${MOUNT_POINT}"
echo "Mounted ${BACKING_FILE} → ${MOUNT_POINT}"
echo ""

echo "--- Step 4: set ownership to ubuntu ---"
chown ubuntu:ubuntu "${MOUNT_POINT}"
echo "Ownership set."
echo ""

echo "=== df -h /mnt/novapay-logtest (loop fs — 64MB total) ==="
df -h "${MOUNT_POINT}"
echo ""

echo "=== df -h / (AFTER setup — snapshot 2 of 3, should be ~64MB less than snapshot 1) ==="
echo "(The backing file itself lives on root; fills go into the loop fs.)"
df -h /
echo ""

# ── next steps ────────────────────────────────────────────────────────────────
cat <<'INSTRUCTIONS'
=== SETUP COMPLETE ===

The 64MB loopback filesystem is mounted at /mnt/novapay-logtest.
Root is untouched except for the 64MB backing file.

Next steps — run these MANUALLY (deliberate, one at a time):

  1. Fill the loop fs:
       sudo dd if=/dev/zero of=/mnt/novapay-logtest/filler bs=1M count=60
     This leaves ~4MB for the transactions.log header; the fs will be ~94% full.
     To go to 100% (pure ENOSPC on the next write):
       sudo dd if=/dev/zero of=/mnt/novapay-logtest/filler2 bs=1M
     (Let dd fail with ENOSPC — that's expected.)

  2. Verify the loop fs is full:
       df -h /mnt/novapay-logtest

  3. Point payment-api at the loop fs (on EC2):
       sudo systemctl set-property payment-api.service \
         Environment="TRANSACTION_LOG_PATH=/mnt/novapay-logtest/transactions.log"
       sudo systemctl restart payment-api
       sudo journalctl -u payment-api -n 10   # confirm startup

  4. Pre-flight: confirm port 8080 is reachable from the machine you will fire
     charges FROM (security group rules for different ports can drift independently
     of SSH access — this is exactly what produced an 11-min hang in INC-006):
       curl -m 5 http://<EC2_IP>:8080/healthz
     If this times out or fails, STOP. Check the EC2 security group inbound rules
     for port 8080 and confirm your current public IP is allowed. SSH working does
     NOT guarantee app ports are reachable — see ADR-013.

  5. Fire charges and watch ENOSPC surface in journald:
       # From your local WSL2 session:
       for i in $(seq 1 5); do
         curl -s -X POST http://<EC2_IP>:8080/charge \
           -H "Content-Type: application/json" \
           -d "{\"idempotency_key\":\"inc006-fill-${i}\",\"amount_minor\":1000,\"currency\":\"CAD\",\"customer_id\":\"cust-inc006\"}"
         echo ""
       done
       # On EC2:
       sudo journalctl -u payment-api -f   # watch for "audit log write failed" ERRORs

  6. Verify invariant (must be 0 rows — charges succeeded even during ENOSPC):
       /ec2-invariant   # from your Claude Code session
       # or directly:
       psql postgresql://novapay:novapay@localhost:5432/novapay -c "
         SELECT payment_id,
           SUM(CASE WHEN direction='debit'  THEN amount_minor ELSE 0 END) AS debits,
           SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END) AS credits
         FROM ledger_entries GROUP BY payment_id
         HAVING SUM(CASE WHEN direction='debit' THEN amount_minor ELSE 0 END) !=
                SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END);"

  7. Capture df -h / (snapshot 3 of 3 — root must be unchanged):
       df -h /

  8. When done observing, run teardown:
       sudo ./scripts/disk-fill-demo.sh --teardown
       # Then restore payment-api to its default TRANSACTION_LOG_PATH:
       sudo systemctl revert payment-api
       sudo systemctl daemon-reload && sudo systemctl restart payment-api

INSTRUCTIONS
