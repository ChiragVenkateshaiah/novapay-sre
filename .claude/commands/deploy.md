---
description: Build Go binaries and deploy to EC2 via Ansible
allowed-tools: Bash
---

Deploy NovaPay to EC2. Run from the repo root.

1. Confirm you are in the repo root:
```
pwd
```

2. Run the Ansible deploy playbook:
```
ansible-playbook -i infrastructure/ansible/inventory.ini infrastructure/ansible/deploy.yml
```

3. After a successful deploy, verify the services are running on EC2 by checking the playbook output for any failed tasks.

If the deploy.yml playbook does not exist yet (Day 3), stop and tell the user it needs to be created first.

Report the full Ansible output. Flag any `failed=1` or `unreachable=1` results as errors.
