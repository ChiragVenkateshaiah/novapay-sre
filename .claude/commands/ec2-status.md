---
description: Check payment-api and fake-psp service status on EC2 via Ansible
allowed-tools: Bash
---

Check the status of both systemd services on EC2.

```
ansible -i infrastructure/ansible/inventory.ini novapay \
  -m command \
  -a "systemctl is-active payment-api fake-psp"
```

Then get the full status for payment-api:
```
ansible -i infrastructure/ansible/inventory.ini novapay \
  -m command \
  -a "systemctl status payment-api --no-pager -l"
```

And for fake-psp:
```
ansible -i infrastructure/ansible/inventory.ini novapay \
  -m command \
  -a "systemctl status fake-psp --no-pager -l"
```

Report:
- Is payment-api active (running)? ✓/✗
- Is fake-psp active (running)? ✓/✗
- Any error lines in the status output?
- How long have the services been running (uptime)?

If any service is not active, flag it immediately.
