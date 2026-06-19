Tail and pretty-print the local transaction audit log.

Run:
```
AUDIT_LOG="${TRANSACTION_LOG_PATH:-/tmp/novapay-audit/transactions.log}"
if [ ! -f "$AUDIT_LOG" ]; then
  echo "Audit log not found: $AUDIT_LOG"
  echo "Set TRANSACTION_LOG_PATH or ensure payment-api has written at least one line."
  exit 1
fi
N="${1:-20}"
echo "=== Last $N audit lines from $AUDIT_LOG ==="
tail -n "$N" "$AUDIT_LOG" | jq .
echo "=== Total lines: $(wc -l < "$AUDIT_LOG") ==="
```

If $ARGUMENTS is provided, use it as N (number of lines). Default is 20.
