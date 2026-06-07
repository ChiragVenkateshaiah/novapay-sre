---
description: Stage all changes, commit with a message, and push to main
allowed-tools: Bash
---

The user will provide a commit message as $ARGUMENTS.

If no message is provided, stop and ask for one. Do not generate a commit message automatically.

Run:
```
git add -A
git status
```

Show the staged files and ask the user to confirm before committing.

Once confirmed, run:
```
git commit -m "$ARGUMENTS"
git push origin main
```

Report the result. If push fails, show the error and do not retry automatically.
