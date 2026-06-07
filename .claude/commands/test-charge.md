---
description: Run a test charge and verify idempotency and the ledger invariant
allowed-tools: Bash
---

Clear any stale test data first:
```
psql postgresql://novapay:novapay@localhost:5432/novapay \
  -c "DELETE FROM ledger_entries; DELETE FROM payments;"
```

Send the first charge:
```
curl -s -X POST localhost:8080/charge \
  -H "Content-Type: application/json" \
  -d '{"idempotency_key":"test-001","amount_minor":1000,"currency":"CAD","customer_id":"cust-1"}'
```

Send the same charge again (idempotency check):
```
curl -s -X POST localhost:8080/charge \
  -H "Content-Type: application/json" \
  -d '{"idempotency_key":"test-001","amount_minor":1000,"currency":"CAD","customer_id":"cust-1"}'
```

Verify both responses returned the same payment_id.

Check the database:
```
psql postgresql://novapay:novapay@localhost:5432/novapay \
  -c "SELECT COUNT(*) as payment_count FROM payments;"

psql postgresql://novapay:novapay@localhost:5432/novapay \
  -c "SELECT direction, amount_minor FROM ledger_entries;"
```

Run the invariant check (must return 0 rows):
```
psql postgresql://novapay:novapay@localhost:5432/novapay -c "
SELECT payment_id,
  SUM(CASE WHEN direction='debit'  THEN amount_minor ELSE 0 END) AS debits,
  SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END) AS credits
FROM ledger_entries GROUP BY payment_id
HAVING SUM(CASE WHEN direction='debit' THEN amount_minor ELSE 0 END) !=
       SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END);"
```

Report pass/fail for each check:
- Both curl calls returned the same payment_id ✓/✗
- payments COUNT = 1 ✓/✗
- ledger_entries = 1 debit + 1 credit ✓/✗
- Invariant = 0 rows ✓/✗
