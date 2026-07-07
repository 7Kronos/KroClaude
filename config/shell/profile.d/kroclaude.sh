# Land interactive logins in /workspace (feature 003-ssh-access).
# /etc/profile sources /etc/profile.d/*.sh for login shells (interactive
# SSH login, `bash -l`). Non-interactive `ssh user@host cmd` invocations
# stay in the user's HOME per standard SSH convention.
if [ -d /workspace ] && [ "$PWD" = "$HOME" ]; then cd /workspace; fi
