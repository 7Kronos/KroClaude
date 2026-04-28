# Contract: sshd Configuration

**Branch**: `003-ssh-access` | **Date**: 2026-04-28

This contract pins the exact directives shipped in
[`scripts/sshd_config_kroclaude`](../../../scripts/sshd_config_kroclaude)
(written at task time per task T004 / T005). Any directive not listed
here MUST NOT be set by KroClaude — accept the upstream OpenSSH
default for unmentioned options.

## Required directives

```sshd_config
# KroClaude SSH server — key-only, claude-only, hardened.
# Authoritative spec: specs/003-ssh-access/spec.md
# Authoritative research: specs/003-ssh-access/research.md §R2

# ----- Listen -----
Port 2221
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# ----- Host keys (persisted in the kroclaude-config volume) -----
HostKey /home/claude/.claude/.ssh-host-keys/ssh_host_ed25519_key
HostKey /home/claude/.claude/.ssh-host-keys/ssh_host_rsa_key

# ----- Authentication -----
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
HostbasedAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
AllowUsers claude
AuthenticationMethods publickey

# ----- PAM (session-only; NOT an auth path here) -----
UsePAM yes

# ----- Session features -----
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
PermitTunnel no
PrintMotd no
PrintLastLog no
TCPKeepAlive yes
ClientAliveInterval 60
ClientAliveCountMax 3

# ----- Logging -----
LogLevel VERBOSE
SyslogFacility AUTH

# ----- Cryptography (Mozilla "modern") -----
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,sntrup761x25519-sha512@openssh.com
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,umac-128-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256

# ----- Misc -----
StrictModes yes
Subsystem sftp internal-sftp
```

## Forbidden directives

The following MUST NOT appear in our config (and the absence of any
`PasswordAuthentication yes` / `PermitRootLogin yes` / etc. line is
itself a compliance check):

- `PasswordAuthentication yes`
- `KbdInteractiveAuthentication yes`
- `ChallengeResponseAuthentication yes`
- `HostbasedAuthentication yes`
- `PermitRootLogin yes` / `PermitRootLogin without-password`
- `PermitEmptyPasswords yes`
- `AuthenticationMethods` set to anything other than `publickey`
- Any `Match` block that re-enables a disabled auth method

## Verification

A passing run of [`tests/smoke/test_us4.sh`](../../../tests/smoke/test_us4.sh)
must include:

1. **Positive auth**: `ssh -i $TMP_KEY -p 2221 claude@127.0.0.1` →
   exits 0; produces a working interactive shell.
2. **Negative — password offer**: `ssh -p 2221 -o
   PreferredAuthentications=password -o NumberOfPasswordPrompts=0
   claude@127.0.0.1` → exits non-zero with no password prompt
   appearing in the client's TTY.
3. **Negative — root**: `ssh -i $TMP_KEY -p 2221 root@127.0.0.1` →
   exits non-zero, sshd logs an `Invalid user root` line.
4. **Negative — wrong key**: connect with a key not in
   `authorized_keys` → exits non-zero with `Permission denied
   (publickey)`.
5. **Cipher**: client connects with the ed25519 host key (sshd offers
   it among the configured `HostKeyAlgorithms`), and a `chacha20`
   or `aes-gcm` cipher is negotiated (visible in `ssh -vv`).

The CI smoke test runs items 1–4 unconditionally; item 5 is a manual
spot-check during PR review.
