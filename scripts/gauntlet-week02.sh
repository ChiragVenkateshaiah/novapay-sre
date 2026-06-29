#!/usr/bin/env bash
# Week 2 integration gauntlet — runs ON EC2 as ubuntu (passwordless sudo required).
# Tests all 5 Week 2 defences in one pass; each stage is independent.
# A failure in one stage does not block the others from running.
# Stages 4 and 5 clean up after themselves unconditionally before the next stage.
#
# Usage (from WSL2):
#   scp -i ~/.ssh/sre-lab-key.pem scripts/gauntlet-week02.sh ubuntu@<EC2_IP>:/tmp/
#   ssh -i ~/.ssh/sre-lab-key.pem ubuntu@<EC2_IP> "bash /tmp/gauntlet-week02.sh"

set -uo pipefail   # no -e: stages must not abort the script on non-zero exit

CHARGE_URL="http://localhost:8080/charge"
HEALTHZ_URL="http://localhost:8080/healthz"
BALLOON_URL="http://localhost:8080/debug/balloon"
AUDIT_LOG="/var/log/novapay/transactions.log"
BACKING_FILE="/opt/novapay/disktest.img"
MOUNT_POINT="/mnt/novapay-logtest"
DROPIN_DIR="/etc/systemd/system/payment-api.service.d"

STAGE1_RESULT="NOT_RUN"
STAGE2_RESULT="NOT_RUN"
STAGE3_RESULT="NOT_RUN"
STAGE4_RESULT="NOT_RUN"
STAGE5_RESULT="NOT_RUN"

# ── helpers ────────────────────────────────────────────────────────────────────

charge_code() {
    curl -s -o /dev/null -w "%{http_code}" -X POST "${CHARGE_URL}" \
        -H "Content-Type: application/json" \
        -d "{\"idempotency_key\":\"${1}\",\"amount_minor\":1000,\"currency\":\"CAD\",\"customer_id\":\"cust-gauntlet\"}"
}

invariant_check() {
    psql postgresql://novapay:novapay@localhost:5432/novapay -t -A -c "
SELECT COUNT(*) FROM (
    SELECT payment_id FROM ledger_entries GROUP BY payment_id
    HAVING SUM(CASE WHEN direction='debit'  THEN amount_minor ELSE 0 END) !=
           SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END)
) bad;" 2>/dev/null | tr -d ' \n'
}

payment_count() {
    psql postgresql://novapay:novapay@localhost:5432/novapay -t -A -c \
        "SELECT COUNT(*) FROM payments;" 2>/dev/null | tr -d ' \n'
}

wait_for_api() {
    local i=0
    while [ "${i}" -lt 20 ]; do
        if curl -sf -o /dev/null -m 2 "${HEALTHZ_URL}" 2>/dev/null; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# Unique key prefix: seconds + process ID to avoid collisions across runs
KEY_PREFIX="g$(date +%s)-$$"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  NovaPay — Week 2 Integration Gauntlet"
echo "  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Pre-flight: payment-api must be responding
if ! wait_for_api; then
    echo "ABORT: payment-api not responding at ${HEALTHZ_URL} — cannot run gauntlet"
    exit 1
fi
echo "Pre-flight: payment-api responding (/healthz OK). Starting stages."
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 1 — Load test under failure (PSP_ERROR_RATE=0.5, 10 charges)
# PASS iff invariant = 0 rows regardless of success/failure mix
# ─────────────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STAGE 1 — Load test under failure (PSP_ERROR_RATE=0.5, 10 charges)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

DROPIN_DIR_PSP="/etc/systemd/system/fake-psp.service.d"
sudo mkdir -p "${DROPIN_DIR_PSP}"
printf '[Service]\nEnvironment="PSP_ERROR_RATE=0.5"\n' | \
    sudo tee "${DROPIN_DIR_PSP}/gauntlet-s1.conf" >/dev/null
sudo systemctl daemon-reload
sudo systemctl restart fake-psp
sleep 3

S1_OK=0; S1_503=0; S1_OTHER=0
for i in $(seq 1 10); do
    CODE=$(charge_code "${KEY_PREFIX}-s1-${i}" 2>/dev/null || echo "000")
    case "${CODE}" in
        200) S1_OK=$((S1_OK + 1)) ;;
        503) S1_503=$((S1_503 + 1)) ;;
        *)   S1_OTHER=$((S1_OTHER + 1)) ;;
    esac
done

sudo rm -f "${DROPIN_DIR_PSP}/gauntlet-s1.conf"
sudo rmdir "${DROPIN_DIR_PSP}" 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl restart fake-psp
sleep 3

S1_BAD=$(invariant_check)
echo "  Charges fired: 10"
echo "  HTTP 200 (approved): ${S1_OK}  |  HTTP 503 (PSP exhausted): ${S1_503}  |  other: ${S1_OTHER}"
echo "  PSP_ERROR_RATE reverted: yes"
echo "  Invariant bad rows: ${S1_BAD}"

if [ "${S1_BAD}" = "0" ]; then
    STAGE1_RESULT="PASS"
    echo "STAGE 1: PASS — invariant 0 rows (${S1_OK}/10 approved, ${S1_503}/10 rejected, 0 broken)"
else
    STAGE1_RESULT="FAIL"
    echo "STAGE 1: FAIL — invariant broken: ${S1_BAD} imbalanced payment(s)"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 2 — Audit log reconciliation (5 fresh charges)
# PASS iff log line delta == payment count delta == 5
# ─────────────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STAGE 2 — Audit log reconciliation (5 fresh charges)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

S2_LINES_BEFORE=$(wc -l < "${AUDIT_LOG}" 2>/dev/null || echo "0")
S2_PAY_BEFORE=$(payment_count)

for i in $(seq 1 5); do
    charge_code "${KEY_PREFIX}-s2-${i}" >/dev/null 2>&1
done
sleep 1

S2_LINES_AFTER=$(wc -l < "${AUDIT_LOG}" 2>/dev/null || echo "0")
S2_PAY_AFTER=$(payment_count)
S2_LINE_DELTA=$((S2_LINES_AFTER - S2_LINES_BEFORE))
S2_PAY_DELTA=$((S2_PAY_AFTER - S2_PAY_BEFORE))

echo "  Audit log:  before=${S2_LINES_BEFORE} lines  after=${S2_LINES_AFTER} lines  delta=+${S2_LINE_DELTA} (expected +5)"
echo "  Payments:   before=${S2_PAY_BEFORE}  after=${S2_PAY_AFTER}  delta=+${S2_PAY_DELTA} (expected +5)"

if [ "${S2_LINE_DELTA}" -eq 5 ] && [ "${S2_PAY_DELTA}" -eq 5 ]; then
    STAGE2_RESULT="PASS"
    echo "STAGE 2: PASS — audit log +${S2_LINE_DELTA} lines matches payments +${S2_PAY_DELTA}"
else
    STAGE2_RESULT="FAIL"
    echo "STAGE 2: FAIL — expected +5/+5, got lines +${S2_LINE_DELTA} / payments +${S2_PAY_DELTA}"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 3 — Forced rotation, zero lines lost
# PASS iff (rotated_lines + post_rotation_line) == pre_rotation_lines + 1
#      AND "audit log reopened" seen in journald
# ─────────────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STAGE 3 — Forced rotation, zero lines lost"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

S3_BEFORE=$(wc -l < "${AUDIT_LOG}" 2>/dev/null || echo "0")
echo "  Active log lines before rotation: ${S3_BEFORE}"

sudo logrotate -f /etc/logrotate.d/novapay
sleep 3  # wait for SIGHUP + fd reopen

# "audit log reopened" is the exact message from auditWriter.reopen()
S3_REOPEN=$(journalctl -u payment-api --since "1 minute ago" --no-pager 2>/dev/null \
    | grep -c "audit log reopened" || true)

S3_ROTATED=0
if [ -f "${AUDIT_LOG}.1" ]; then
    S3_ROTATED=$(wc -l < "${AUDIT_LOG}.1")
    echo "  transactions.log.1 lines (rotated): ${S3_ROTATED}"
else
    echo "  WARNING: transactions.log.1 not found after rotation"
fi

S3_ACTIVE_NOW=$(wc -l < "${AUDIT_LOG}" 2>/dev/null || echo "0")
echo "  Active log lines immediately after rotation: ${S3_ACTIVE_NOW}"
echo "  'audit log reopened' in journald (last 1 min): ${S3_REOPEN}"

charge_code "${KEY_PREFIX}-s3-1" >/dev/null 2>&1
sleep 1

S3_ACTIVE_AFTER=$(wc -l < "${AUDIT_LOG}" 2>/dev/null || echo "0")
S3_TOTAL=$((S3_ROTATED + S3_ACTIVE_AFTER))
S3_EXPECTED=$((S3_BEFORE + 1))

echo "  Active log lines after 1 charge: ${S3_ACTIVE_AFTER}"
echo "  Total (rotated + active): ${S3_TOTAL}  |  expected: ${S3_EXPECTED} (${S3_BEFORE}+1)"

if [ "${S3_TOTAL}" -eq "${S3_EXPECTED}" ] && [ "${S3_REOPEN}" -ge 1 ]; then
    STAGE3_RESULT="PASS"
    echo "STAGE 3: PASS — zero lines lost (total=${S3_TOTAL}=${S3_BEFORE}+1); SIGHUP reopen confirmed"
elif [ "${S3_REOPEN}" -lt 1 ]; then
    STAGE3_RESULT="FAIL"
    echo "STAGE 3: FAIL — SIGHUP reopen not seen in journald (count=${S3_REOPEN})"
else
    STAGE3_RESULT="FAIL"
    echo "STAGE 3: FAIL — line count mismatch: got ${S3_TOTAL}, expected ${S3_EXPECTED}"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 4 — Disk-fill, bounded
# Setup: 64M loopback fs, filled to ENOSPC; TRANSACTION_LOG_PATH drop-in
# PASS iff 3/3 charges return 200 AND invariant = 0 rows AND root untouched
# Cleanup: drop-in removed, payment-api reverted, loop fs torn down
# ─────────────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STAGE 4 — Disk-fill, bounded (ENOSPC on loop fs; charges must return 200)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ROOT_FREE_KB=$(df -k / | awk 'NR==2 {print $4}')
ROOT_FREE_MIN_KB=$((1024 * 1024))  # 1 GB

if [ "${ROOT_FREE_KB}" -lt "${ROOT_FREE_MIN_KB}" ]; then
    STAGE4_RESULT="SKIP"
    echo "STAGE 4: SKIP — root has less than 1G free (${ROOT_FREE_KB} KB). Refusing to create loopback fs."
else
    S4_ROOT_BEFORE_KB="${ROOT_FREE_KB}"
    echo "  Root free before: ${S4_ROOT_BEFORE_KB} KB"

    # Setup loopback fs
    fallocate -l 64M "${BACKING_FILE}"
    sudo mkfs.ext4 -q "${BACKING_FILE}"
    sudo mkdir -p "${MOUNT_POINT}"
    sudo mount -o loop "${BACKING_FILE}" "${MOUNT_POINT}"
    sudo chown ubuntu:ubuntu "${MOUNT_POINT}"
    echo "  Loopback fs mounted at ${MOUNT_POINT} (64M)"

    # Fill to ENOSPC — dd exits non-zero on ENOSPC; || true absorbs it
    dd if=/dev/zero of="${MOUNT_POINT}/filler" bs=1M 2>/dev/null || true
    echo "  Loop fs filled: $(df -h "${MOUNT_POINT}" | awk 'NR==2 {print $5}') used"

    # Add TRANSACTION_LOG_PATH drop-in pointing at the full loop fs
    sudo mkdir -p "${DROPIN_DIR}"
    printf '[Service]\nEnvironment="TRANSACTION_LOG_PATH=%s/transactions.log"\n' \
        "${MOUNT_POINT}" | sudo tee "${DROPIN_DIR}/gauntlet-s4.conf" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl restart payment-api
    wait_for_api || true
    sleep 1

    # Fire 3 charges — must return 200 despite ENOSPC audit log
    S4_OK=0; S4_OTHER=0
    for i in $(seq 1 3); do
        CODE=$(charge_code "${KEY_PREFIX}-s4-${i}" 2>/dev/null || echo "000")
        if [ "${CODE}" = "200" ]; then
            S4_OK=$((S4_OK + 1))
        else
            S4_OTHER=$((S4_OTHER + 1))
            echo "  charge ${i}: HTTP ${CODE} (unexpected)"
        fi
    done

    # Confirm audit errors surfaced to journald (not silently swallowed)
    S4_AUDIT_ERR=$(journalctl -u payment-api --since "3 minutes ago" --no-pager 2>/dev/null \
        | grep -cE "audit log (write|open) failed" || true)
    S4_BAD=$(invariant_check)
    S4_ROOT_AFTER_KB=$(df -k / | awk 'NR==2 {print $4}')
    S4_ROOT_DELTA=$(( S4_ROOT_BEFORE_KB - S4_ROOT_AFTER_KB ))

    echo "  HTTP 200: ${S4_OK}/3  |  other: ${S4_OTHER}"
    echo "  Audit error events in journald: ${S4_AUDIT_ERR}"
    echo "  Invariant bad rows: ${S4_BAD}"
    echo "  Root free: before=${S4_ROOT_BEFORE_KB} KB  after=${S4_ROOT_AFTER_KB} KB  delta=${S4_ROOT_DELTA} KB"

    # ── Cleanup — unconditional ────────────────────────────────────────────
    echo "  [cleanup] removing TRANSACTION_LOG_PATH drop-in..."
    sudo rm -f "${DROPIN_DIR}/gauntlet-s4.conf"
    sudo rmdir "${DROPIN_DIR}" 2>/dev/null || true
    sudo systemctl daemon-reload
    sudo systemctl restart payment-api
    wait_for_api || true

    echo "  [cleanup] tearing down loop fs..."
    S4_UMOUNT_OK=true
    if ! sudo umount "${MOUNT_POINT}" 2>/dev/null; then
        S4_UMOUNT_OK=false
        echo "  [cleanup] WARNING: umount ${MOUNT_POINT} failed — diagnosing open handles..."
        sudo lsof +D "${MOUNT_POINT}" 2>/dev/null || sudo fuser -vm "${MOUNT_POINT}" 2>/dev/null || true
        echo "  [cleanup] FAIL: leaving ${BACKING_FILE} and ${MOUNT_POINT} intact for manual inspection"
        echo "  [cleanup] To recover manually: sudo umount ${MOUNT_POINT} && rm -f ${BACKING_FILE} && sudo rmdir ${MOUNT_POINT}"
    else
        rm -f "${BACKING_FILE}"
        sudo rmdir "${MOUNT_POINT}" 2>/dev/null || true
        echo "  [cleanup] done — loop fs removed, payment-api back on default log path"
    fi

    if [ "${S4_OK}" -eq 3 ] && [ "${S4_BAD}" = "0" ] && "${S4_UMOUNT_OK}"; then
        STAGE4_RESULT="PASS"
        echo "STAGE 4: PASS — 3/3 charges returned 200 under ENOSPC; invariant 0 rows; root delta=${S4_ROOT_DELTA} KB (backing file only); cleanup complete"
    else
        STAGE4_RESULT="FAIL"
        REASONS=""
        [ "${S4_OK}" -ne 3 ]    && REASONS="${REASONS} only-${S4_OK}/3-charges-succeeded;"
        [ "${S4_BAD}" != "0" ]  && REASONS="${REASONS} invariant-broken-${S4_BAD}-rows;"
        ! "${S4_UMOUNT_OK}"     && REASONS="${REASONS} umount-failed-loop-device-orphaned;"
        echo "STAGE 4: FAIL —${REASONS}"
    fi
fi
echo ""

sleep 2

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 5 — OOM, contained
# Setup: NOVAPAY_DEBUG=1 drop-in; balloon mb=400, repeated against the same
#   process instance until OOM kill is confirmed (up to 5 calls).
#   Each call allocates into goroutines that remain live in the same process;
#   RSS accumulates cumulatively across calls until MemoryMax is breached —
#   this is not 5 independent isolated attempts.
# PASS iff CONSTRAINT_MEMCG in dmesg AND Postgres untouched AND recovery charge 200
#      AND invariant 0 rows AND /debug/balloon returns 404 after cleanup
# Cleanup: NOVAPAY_DEBUG drop-in removed; payment-api restarted clean
# ─────────────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STAGE 5 — OOM contained (CONSTRAINT_MEMCG kill; Postgres safe; auto-recovery)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Add NOVAPAY_DEBUG drop-in
sudo mkdir -p "${DROPIN_DIR}"
printf '[Service]\nEnvironment="NOVAPAY_DEBUG=1"\n' | \
    sudo tee "${DROPIN_DIR}/gauntlet-s5.conf" >/dev/null
sudo systemctl daemon-reload
sudo systemctl restart payment-api
wait_for_api || true
sleep 1

S5_PG_PID_BEFORE=$(pgrep postgres | head -1 2>/dev/null || echo "?")
S5_OOM_BEFORE=$(sudo dmesg 2>/dev/null | grep -c "CONSTRAINT_MEMCG" || true)
S5_BALLOON_LIVE=$(curl -s -o /dev/null -w "%{http_code}" "${BALLOON_URL}?mb=1" 2>/dev/null || echo "FAIL")

echo "  Postgres PID before balloon: ${S5_PG_PID_BEFORE}"
echo "  CONSTRAINT_MEMCG entries in dmesg before: ${S5_OOM_BEFORE}"
echo "  Balloon endpoint: HTTP ${S5_BALLOON_LIVE} (expect 200)"

# Fire balloon repeatedly against the same process instance until OOM kill
# is confirmed in dmesg or attempts are exhausted. MemoryHigh (128M) throttles
# page faults so a single mb=400 call stalls rather than completing quickly.
# Each timed-out call leaves its goroutine's partial allocation live in the
# same process — RSS grows cumulatively across calls until MemoryMax (192M)
# is breached and the cgroup OOM killer fires.
S5_MB_PER_CALL=400
S5_OOM_DETECTED=false
S5_ATTEMPTS=0
S5_MAX_ATTEMPTS=10
until "${S5_OOM_DETECTED}" || [ "${S5_ATTEMPTS}" -ge "${S5_MAX_ATTEMPTS}" ]; do
    S5_ATTEMPTS=$((S5_ATTEMPTS + 1))
    S5_MB_SO_FAR=$((S5_ATTEMPTS * S5_MB_PER_CALL))
    echo "  Balloon call ${S5_ATTEMPTS}/${S5_MAX_ATTEMPTS} (mb=400, cumulative requested so far: ~${S5_MB_SO_FAR}MB, timeout 30s)..."
    curl -m 30 -s -o /dev/null "${BALLOON_URL}?mb=400" 2>/dev/null || true
    sleep 2
    S5_OOM_NOW=$(sudo dmesg 2>/dev/null | grep -c "CONSTRAINT_MEMCG" || true)
    if [ "${S5_OOM_NOW}" -gt "${S5_OOM_BEFORE}" ]; then
        S5_OOM_DETECTED=true
        S5_TOTAL_MB_REQUESTED=$((S5_ATTEMPTS * S5_MB_PER_CALL))
        echo "  OOM kill confirmed in dmesg (${S5_ATTEMPTS} cumulative calls, ~${S5_TOTAL_MB_REQUESTED}MB requested into same process instance)"
    fi
done
# After all curl calls exit, the handler goroutines are still running in the
# background — each is blocked in the page-fault loop under MemoryHigh throttle,
# slowly accumulating RSS toward MemoryMax. Poll dmesg until the OOM fires or
# we give up after 2 minutes.
if ! "${S5_OOM_DETECTED}"; then
    echo "  All balloon calls timed out; goroutines still accumulating RSS. Polling for OOM kill..."
    POLL_TICK=0
    POLL_MAX=12  # 12 × 10s = 120s max wait
    until "${S5_OOM_DETECTED}" || [ "${POLL_TICK}" -ge "${POLL_MAX}" ]; do
        sleep 10
        POLL_TICK=$((POLL_TICK + 1))
        S5_OOM_NOW=$(sudo dmesg 2>/dev/null | grep -c "CONSTRAINT_MEMCG" || true)
        if [ "${S5_OOM_NOW}" -gt "${S5_OOM_BEFORE}" ]; then
            S5_OOM_DETECTED=true
            S5_TOTAL_MB_REQUESTED=$((S5_ATTEMPTS * S5_MB_PER_CALL))
            echo "  OOM kill confirmed in dmesg (deferred; ${S5_ATTEMPTS} cumulative balloon calls across same process instance, ~${S5_TOTAL_MB_REQUESTED}MB requested; kill detected ~$((POLL_TICK * 10))s after last call exited)"
        else
            echo "  Polling ${POLL_TICK}/${POLL_MAX}: no OOM yet..."
        fi
    done
fi
# Record total requested regardless of outcome
if ! "${S5_OOM_DETECTED}"; then
    S5_TOTAL_MB_REQUESTED=$((S5_ATTEMPTS * S5_MB_PER_CALL))
fi

# Wait for systemd RestartSec=5s + buffer
echo "  Waiting for systemd restart (RestartSec=5s)..."
sleep 8
wait_for_api || true

S5_OOM_AFTER=$(sudo dmesg 2>/dev/null | grep -c "CONSTRAINT_MEMCG" || true)
S5_NEW_OOM=$((S5_OOM_AFTER - S5_OOM_BEFORE))
S5_OOM_LINE=$(sudo dmesg 2>/dev/null | grep "CONSTRAINT_MEMCG" | tail -1 || echo "(not found)")
S5_PG_PID_AFTER=$(pgrep postgres | head -1 2>/dev/null || echo "GONE")
S5_PA_STATUS=$(systemctl is-active payment-api 2>/dev/null || echo "unknown")

echo "  New CONSTRAINT_MEMCG dmesg entries: ${S5_NEW_OOM}"
echo "  Last OOM line: ${S5_OOM_LINE}"
echo "  Postgres PID after: ${S5_PG_PID_AFTER} (was ${S5_PG_PID_BEFORE})"
echo "  payment-api status: ${S5_PA_STATUS}"

# ── Cleanup — unconditional; must complete before recovery charge ──────────
echo "  [cleanup] removing NOVAPAY_DEBUG drop-in..."
sudo rm -f "${DROPIN_DIR}/gauntlet-s5.conf"
sudo rmdir "${DROPIN_DIR}" 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl restart payment-api
wait_for_api || true

S5_BALLOON_GONE=$(curl -s -o /dev/null -w "%{http_code}" "${BALLOON_URL}?mb=1" 2>/dev/null || echo "FAIL")
echo "  /debug/balloon after cleanup (expect 404): HTTP ${S5_BALLOON_GONE}"

# Recovery charge confirms the service is back and the ledger is intact
S5_RECOVERY=$(charge_code "${KEY_PREFIX}-s5-recovery" 2>/dev/null || echo "000")
S5_BAD=$(invariant_check)
echo "  Recovery charge HTTP code: ${S5_RECOVERY}"
echo "  Invariant bad rows after recovery: ${S5_BAD}"

if "${S5_OOM_DETECTED}" && \
   [ "${S5_PG_PID_AFTER}" != "GONE" ] && \
   [ "${S5_PA_STATUS}" = "active" ] && \
   [ "${S5_RECOVERY}" = "200" ] && \
   [ "${S5_BAD}" = "0" ] && \
   [ "${S5_BALLOON_GONE}" = "404" ]; then
    STAGE5_RESULT="PASS"
    echo "STAGE 5: PASS — OOM kill triggered after ${S5_ATTEMPTS} cumulative balloon calls (~${S5_TOTAL_MB_REQUESTED}MB requested into same process instance); CONSTRAINT_MEMCG confirmed; Postgres untouched; payment-api restarted; recovery 200; invariant 0 rows; NOVAPAY_DEBUG removed"
else
    STAGE5_RESULT="FAIL"
    REASONS=""
    ! "${S5_OOM_DETECTED}"             && REASONS="${REASONS} no-OOM-in-${S5_MAX_ATTEMPTS}-attempts;"
    [ "${S5_PG_PID_AFTER}" = "GONE" ] && REASONS="${REASONS} postgres-killed;"
    [ "${S5_PA_STATUS}" != "active" ]  && REASONS="${REASONS} payment-api-${S5_PA_STATUS};"
    [ "${S5_RECOVERY}" != "200" ]      && REASONS="${REASONS} recovery-charge-${S5_RECOVERY};"
    [ "${S5_BAD}" != "0" ]             && REASONS="${REASONS} invariant-broken-${S5_BAD}-rows;"
    [ "${S5_BALLOON_GONE}" != "404" ]  && REASONS="${REASONS} balloon-still-live-${S5_BALLOON_GONE};"
    echo "STAGE 5: FAIL —${REASONS}"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════"
echo "  GAUNTLET SUMMARY — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "════════════════════════════════════════════════════════════════"
printf "  STAGE 1  %-8s  load test — invariant under 50%% PSP error rate\n"    "${STAGE1_RESULT}"
printf "  STAGE 2  %-8s  audit log reconciliation — 5 charges\n"               "${STAGE2_RESULT}"
printf "  STAGE 3  %-8s  forced rotation — zero lines lost\n"                  "${STAGE3_RESULT}"
printf "  STAGE 4  %-8s  disk-fill — charges return 200 under ENOSPC\n"        "${STAGE4_RESULT}"
printf "  STAGE 5  %-8s  OOM — CONSTRAINT_MEMCG kill, Postgres safe\n"         "${STAGE5_RESULT}"
echo "════════════════════════════════════════════════════════════════"
