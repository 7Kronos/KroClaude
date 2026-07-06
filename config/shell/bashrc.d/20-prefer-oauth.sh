# Prefer persisted OAuth login over ANTHROPIC_API_KEY.
# claude-code treats ANTHROPIC_API_KEY as overriding the persisted OAuth
# login (~/.claude/.credentials.json). compose `environment:` sets the key
# on PID 1, so it leaks into every `docker exec` / SSH interactive shell
# and silently bypasses `claude login` — making the saved session look
# like it never persists ("login every time"). When a real OAuth
# credential is present, drop the env var for this shell so the persisted
# login wins. Users who never ran `claude login` keep API-key auth (no
# credentials file → no unset). Complements the ANTHROPIC_API_KEY
# exclusion from /etc/environment in the entrypoint.
if [ -s "$HOME/.claude/.credentials.json" ]; then
    unset ANTHROPIC_API_KEY
fi
