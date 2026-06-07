---
description: Fetch recent logs from payment-api on EC2 via Ansible
allowed-tools: Bash
---

Fetch the last 50 lines of payment-api logs from EC2.

```
ansible -i infrastructure/ansible/inventory.ini novapay \
  -m command \
  -a "journalctl -u payment-api --since '10 minutes ago' --no-pager -n 50"
```

If $ARGUMENTS is provided, use it as the service name instead of payment-api.
For example: /ec2-logs fake-psp

Also check for any ERROR lines in the last hour:
```
ansible -i infrastructure/ansible/inventory.ini novapay \
  -m command \
  -a "journalctl -u payment-api --since '1 hour ago' --no-pager | grep ERROR"
```

Report:
- The last 50 log lines
- Count of ERROR lines in the last hour
- Any patterns that look abnormal (repeated errors, unexpected latency, etc.)
