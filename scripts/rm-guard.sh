#!/usr/bin/env bash
# PreToolUse hook for the Bash tool.
#
# bypassPermissions removes Claude Code's safety net everywhere except
# the hardcoded `rm -rf /` and `rm -rf ~` circuit breakers. The two
# persistent volumes (/workspace, ~/.claude) are exactly what we don't
# want nuked accidentally — this hook restores a narrow targeted guard
# for state that survives container recreation.
#
# Reads PreToolUse JSON on stdin, denies recursive deletes that target
# anything inside /workspace or ~/.claude. Allows everything else.

set -u

input="$(cat)"

command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"

if [ -z "$command" ]; then
  exit 0
fi

# Bash -c, eval, and pipelines etc. — scan the raw command string for
# `rm` invocations with a recursive flag. Cheap, syntactic, deliberately
# over-eager: false-positives prompt rather than corrupt persistent state.
read -r -a tokens <<<"$command"

is_recursive_rm=0
i=0
n=${#tokens[@]}
recursive_pattern='^-[a-zA-Z]*[rR][a-zA-Z]*$'

while [ "$i" -lt "$n" ]; do
  tok="${tokens[$i]}"
  case "$tok" in
    rm|/bin/rm|/usr/bin/rm)
      j=$((i + 1))
      while [ "$j" -lt "$n" ]; do
        next="${tokens[$j]}"
        if [ "$next" = "--recursive" ]; then
          is_recursive_rm=1
          break
        fi
        if [[ "$next" =~ $recursive_pattern ]]; then
          is_recursive_rm=1
          break
        fi
        case "$next" in
          --) break ;;
          -*) j=$((j + 1)); continue ;;
          *) break ;;
        esac
      done
      ;;
  esac
  i=$((i + 1))
done

if [ "$is_recursive_rm" -eq 0 ]; then
  exit 0
fi

home_claude="${HOME:-/home/claude}/.claude"

protected_hit=""
for tok in "${tokens[@]}"; do
  case "$tok" in
    rm|/bin/rm|/usr/bin/rm|--|--*) continue ;;
    -*) continue ;;
  esac
  resolved="$(realpath -m -- "$tok" 2>/dev/null || true)"
  [ -z "$resolved" ] && continue
  case "$resolved" in
    /workspace|/workspace/*|"$home_claude"|"$home_claude"/*)
      protected_hit="$resolved"
      break
      ;;
  esac
done

if [ -n "$protected_hit" ]; then
  jq -n --arg reason "rm-guard: recursive delete blocked on persistent volume target: $protected_hit" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
fi

exit 0
