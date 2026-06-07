---
description: Preview what the Ansible deploy would change on EC2 — touches nothing
allowed-tools: Bash
---

Run the Ansible deploy playbook in check (dry-run) mode. This shows exactly what would change on EC2 without making any changes.

```
ansible-playbook \
  -i infrastructure/ansible/inventory.ini \
  infrastructure/ansible/deploy.yml \
  --check \
  --diff
```

The `--diff` flag shows exactly what file content would change.

Report the output clearly. Highlight:
- Any `changed` tasks (these would actually run in a real deploy)
- Any `failed` tasks (these must be fixed before deploying)
- Any `unreachable` hosts (EC2 connectivity issue)

If all tasks show `ok` or `changed` with no failures, the deploy is safe to run with /deploy.
If anything shows `failed`, stop and fix it before proceeding.
