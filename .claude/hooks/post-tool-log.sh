#!/usr/bin/env bash
# .claude/hooks/post-tool-log.sh
#
# PostToolUse hook: logs every bash command Claude Code runs.
# Useful for auditing what Claude Code actually executed.
# Does NOT block anything — PostToolUse is observability-only.

LOG_FILE="$HOME/.claude/novapay-activity.log"
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | sed 's/"command":"//;s/"//')
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if [ -n "$COMMAND" ]; then
    echo "[$TIMESTAMP] $COMMAND" >> "$LOG_FILE"
fi

# After a successful ansible-playbook deploy, remind to verify
if echo "$COMMAND" | grep -q "ansible-playbook" && ! echo "$COMMAND" | grep -q "\-\-check"; then
    echo ""
    echo "✓ Deploy completed. Run /ec2-invariant to verify money is still balanced."
    echo ""
fi

exit 0
