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
