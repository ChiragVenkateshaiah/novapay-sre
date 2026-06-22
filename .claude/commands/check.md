---
description: Build both services, run go vet, and verify the ledger invariant holds
allowed-tools: Bash
---

Run the following checks in order. Stop and report immediately if any step fails.

1. Build payment-api:
```
cd app/payment-api && go build ./...
```

2. Build fake-psp:
```
cd app/fake-psp && go build ./...
```

3. Run go vet on payment-api:
```
cd app/payment-api && go vet ./...
```

4. Run the ledger invariant check — this MUST return 0 rows:
```
psql postgresql://novapay:novapay@localhost:5432/novapay -c "
SELECT payment_id,
  SUM(CASE WHEN direction='debit'  THEN amount_minor ELSE 0 END) AS debits,
  SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END) AS credits
FROM ledger_entries GROUP BY payment_id
HAVING SUM(CASE WHEN direction='debit' THEN amount_minor ELSE 0 END) !=
       SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END);"
```

Report the result of each step clearly. If the invariant returns any rows, flag it as a CRITICAL issue — money is out of balance.

5. Optional — EC2 reachability check (non-blocking):
Read the EC2 IP from infrastructure/ansible/inventory.ini, then run:
```
EC2_IP=$(grep ansible_host infrastructure/ansible/inventory.ini | grep -oP 'ansible_host=\K[^ ]+')
HTTP_CODE=$(curl -m 5 -s -o /dev/null -w "%{http_code}" "http://${EC2_IP}:8080/healthz" 2>/dev/null || echo "FAIL")
if [ "${HTTP_CODE}" = "200" ]; then
  echo "EC2:8080 PASS (HTTP 200)"
else
  echo "EC2:8080 FAIL (got '${HTTP_CODE}') — check security group inbound rules for port 8080; SSH access does not guarantee app-port reachability — see ADR-013"
fi
```
Report PASS or FAIL but do not block the other checks from completing.
