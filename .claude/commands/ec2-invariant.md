---
description: Run the ledger invariant check against EC2's Postgres database
allowed-tools: Bash
---

Run the ledger balance invariant check against EC2's PostgreSQL database via Ansible.

```
ansible -i infrastructure/ansible/inventory.ini novapay \
  -m command \
  -a "psql postgresql://novapay:novapay@localhost:5432/novapay -t -c \"
SELECT payment_id,
  SUM(CASE WHEN direction='debit'  THEN amount_minor ELSE 0 END) AS debits,
  SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END) AS credits
FROM ledger_entries GROUP BY payment_id
HAVING SUM(CASE WHEN direction='debit' THEN amount_minor ELSE 0 END) !=
       SUM(CASE WHEN direction='credit' THEN amount_minor ELSE 0 END);\""
```

Also get a payment count:
```
ansible -i infrastructure/ansible/inventory.ini novapay \
  -m command \
  -a "psql postgresql://novapay:novapay@localhost:5432/novapay -t -c 'SELECT COUNT(*) FROM payments;'"
```

Report:
- Invariant result: PASS (0 rows) or FAIL (rows returned = broken ledger)
- Total payment count on EC2

If the invariant returns ANY rows, flag it as CRITICAL immediately.
A broken invariant means money is out of balance in production.
