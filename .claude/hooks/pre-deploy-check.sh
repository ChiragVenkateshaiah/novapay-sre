#!/usr/bin/env bash
# .claude/hooks/pre-deploy-check.sh
#
# PreToolUse hook: intercepts any ansible-playbook command that does NOT
# include --check and blocks it with exit 2.
#
# This enforces the rule: always dry-run before real deploy.
# Claude Code must use /deploy-dry-run before /deploy.

# Read the tool input from stdin (Claude Code passes it as JSON)
INPUT=$(cat)

# Extract the command string if this is a Bash tool call
COMMAND=$(echo "$INPUT" | grep -o '"command":"[^"]*"' | head -1 | sed 's/"command":"//;s/"//')

# Only act on ansible-playbook calls
if echo "$COMMAND" | grep -q "ansible-playbook"; then

    # If it's a dry-run (--check), allow it
    if echo "$COMMAND" | grep -q "\-\-check"; then
        exit 0
    fi

    # If it's a real deploy without --check, block it
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  PRODUCTION DEPLOY GATE                                      ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  You are about to run a real Ansible deploy against EC2.     ║"
    echo "║  Did you run /deploy-dry-run first and review the output?    ║"
    echo "║                                                              ║"
    echo "║  If yes: re-run /deploy and type CONFIRM when asked.        ║"
    echo "║  If no:  run /deploy-dry-run first.                         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # Block the action — exit 2 is required for Claude Code policy enforcement
    exit 2
fi

# All other bash commands: allow
exit 0
