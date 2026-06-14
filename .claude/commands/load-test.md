---
description: Fire 10 sequential charges locally with PSP_ERROR_RATE=0.5 and verify invariant holds
allowed-tools: Bash
---

Set PSP_ERROR_RATE=0.5 and run 10 sequential charges with unique idempotency keys:

for i in $(seq 1 10); do
  curl -s -X POST localhost:8080/charge \
    -H "Content-Type: application/json" \
    -d "{\"idempotency_key\":\"load-test-$i\",\"amount_minor\":1000,\"currency\":\"CAD\",\"customer_id\":\"cust-1\"}"
done

Then run the invariant check. Report:
- How many charges succeeded vs returned 503
- Invariant result (must be 0 rows)
- Any unexpected errors in the logs
