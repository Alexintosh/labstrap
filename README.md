# labstrap

`labstrap` is a phase-based, idempotent, local-only CLI for provisioning and hardening fresh Ubuntu-family installs (including Zorin OS) with no cloud-init and no remote controller.

## Design Guarantees

- Local execution only (`ansible_connection=local`)
- Idempotent phases
- Re-runnable after partial failure
- Safe SSH hardening order to reduce lockout risk
- No interactive prompts during provisioning
- Inspectable Bash + Ansible implementation
- Structured JSONL logging for every phase/task step

## Project Layout

```text
labstrap/
├── labstrap
├── bootstrap.sh
├── install.sh
├── ansible/
│   ├── playbook.yml
│   ├── inventory.ini
│   ├── roles/
│   │   ├── base/
│   │   ├── hardening/
│   │   └── extras/
├── defaults/
│   └── config.yml
├── checks/
│   └── preflight.sh
└── README.md
```

## Install

First-install (no repo clone required):

```bash
curl -fsSL https://raw.githubusercontent.com/Alexintosh/labstrap/main/bootstrap.sh | sudo bash
```

or

```bash
wget -qO- https://raw.githubusercontent.com/Alexintosh/labstrap/main/bootstrap.sh | sudo bash
```

Local install (from a checked-out repo):

```bash
sudo ./install.sh
```

This installs:

- dependencies (including `ansible`)
- project files to `/opt/labstrap`
- command symlink at `/usr/local/bin/labstrap`

Bootstrap configuration overrides (optional):

- `LABSTRAP_REPO_URL` (default: `https://github.com/Alexintosh/labstrap.git`)
- `LABSTRAP_REF` (default: `main`)
- `LABSTRAP_ARCHIVE_URL` (explicit archive URL override)

Homebrew installer mode override (optional):

- `LABSTRAP_HOMEBREW_INTERACTIVE=1` to use interactive Homebrew install mode

## Commands

```bash
labstrap init
labstrap harden
labstrap extras [component|all|--interactive|select]
labstrap allow-key <path_to_pubkey>
labstrap doctor [--fix]
labstrap status
```

Every command emits JSON lines to stdout and also writes a JSONL file under `/var/log/labstrap` (fallback `/tmp/labstrap`).
Set `LABSTRAP_LOG_DIR` to override the log directory.

## Phase Behavior

### `init`

- Verifies Ubuntu-based OS
- Creates provisioning user
- Configures sudo for that user
- Installs required base packages
- Does not modify SSH daemon config
- Does not apply restrictive firewall SSH policy

### `harden`

Before running `harden`, add at least one SSH public key for the target user:

```bash
sudo LABSTRAP_USER="$(logname)" labstrap allow-key /path/to/key.pub
sudo LABSTRAP_USER="$(logname)" labstrap harden
```

Use an explicit username instead of `$(logname)` when running from a root-only session:

```bash
sudo LABSTRAP_USER=alexintosh labstrap allow-key /path/to/key.pub
sudo LABSTRAP_USER=alexintosh labstrap harden
```

Execution order is enforced:

1. Ensure SSH key(s) exist
2. Install Tailscale
3. Bring up Tailscale with Tailscale SSH disabled
4. Allow firewall traffic on `tailscale0`
5. Remove non-Tailscale SSH access
6. Change SSH port and enforce key auth settings
7. Restart SSH
8. Verify service/listener/firewall state
9. Disable root SSH login

On systems using socket-activated OpenSSH, `harden` reconciles `ssh.socket` as part of the listener restart and verification path.

### `extras`

Supported components:

- `homebrew`
- `dokploy`
- `zsh`
- `ohmyzsh`
- `starship`
- `yazi`
- `node`
- `codex`
- `claudecode`
- `kimi`
- `camoufox`
- `cargo`
- `pm2`
- `pnpm`
- `tcs`
- `tsx`
- `openclaw`
- `clawvault`
- `bun`
- `whisper`
- `rbw`
- `llamacpp`
- `herdr`
- `dotfiles`
- `all`

Each component is independently idempotent.
`extras all` attempts every enabled component and reports a consolidated failure summary at the end if any component fails.
Running `labstrap extras` with no component on an interactive TTY opens a selector so you can enable, disable, save, and run a chosen set of extras.
`labstrap extras --interactive` and `labstrap extras select` open the same selector explicitly.
The `llamacpp` component installs the Homebrew `llama.cpp` formula and verifies that `llama-cli` is available.
The `herdr` component runs the upstream installer and verifies that `herdr` is available in the target user's shell.

Examples:

```bash
sudo LABSTRAP_USER="$(logname)" labstrap extras llamacpp
sudo LABSTRAP_USER="$(logname)" labstrap extras herdr
sudo LABSTRAP_USER="$(logname)" labstrap extras --interactive
```

`tcs` installs TypeScript and provides a `tcs` wrapper that delegates to `tsc`.
`codex`, `claudecode`, `pm2`, `pnpm`, `tcs`, `tsx`, and `clawvault` depend on the `node` component.

### `allow-key`

- Appends one public key to configured user
- Deduplicates existing key lines
- Enforces `.ssh` and `authorized_keys` permissions
- No service restart

### `status`

Verifies:

- SSH service and configured listener port
- UFW active and `tailscale0` allowance
- Tailscale connected
- Key service state (`ssh`, `fail2ban`, `tailscaled`)
- Enabled extras presence

### `doctor`

Checks common failure causes before/during provisioning:

- Missing SSH key for hardening
- Invalid `sshd_config` or missing `/run/sshd`
- npm/nvm incompatibilities in `~/.npmrc` (`prefix`/`globalconfig`)
- Linuxbrew path ownership/writability for Homebrew installs
- Selected extras presence checks (`claudecode`, `kimi`, `camoufox`, `cargo`, `tsx`, `openclaw`, `bun`, `whisper`, `rbw`, `llamacpp`, `herdr`)

Use auto-fix mode for safe remediations:

```bash
sudo labstrap doctor --fix
```

## Configuration

Default config lives at:

- `/opt/labstrap/defaults/config.yml` (installed)
- `defaults/config.yml` (source)

Override path at runtime by setting `LABSTRAP_CONFIG`.

The default `user: auto` resolves to the target local user at runtime. Resolution order is:
`LABSTRAP_USER`, `SUDO_USER`, `logname`, then the first normal local account from `/etc/passwd`.
Set `LABSTRAP_USER` or replace `user: auto` with an explicit username when bootstrapping from a root-only session.

Dokploy version is configurable via `dokploy.version` (default: `latest`).
OpenClaw version is configurable via `openclaw.version` (default: `latest`).

## Expected Workflow

```bash
sudo ./install.sh
sudo LABSTRAP_USER="$(logname)" labstrap init
sudo LABSTRAP_USER="$(logname)" labstrap allow-key /path/to/key.pub
sudo LABSTRAP_USER="$(logname)" labstrap harden
sudo LABSTRAP_USER="$(logname)" labstrap extras all
sudo reboot
```

After reboot, SSH should be reachable through Tailscale according to config policy.

## VM Smoke Test

Use the automated Multipass smoke test to create a fresh VM, run provisioning, and validate structured logs:

```bash
./tests/vm-smoke.sh
```

The default VM disk is `80G` because `extras all` installs many large toolchains.

Optional hardening run (requires Tailscale first-run auth flow):

```bash
./tests/vm-smoke.sh --with-harden
```

Keep the VM after test for debugging:

```bash
./tests/vm-smoke.sh --keep --name labstrap-debug
```

## Lume VM Smoke Test

Use the separate Lume smoke test when running on Apple Silicon macOS:

```bash
./tests/lume-vm-smoke.sh
```

Examples:

```bash
# Use unattended Setup Assistant preset during creation
./tests/lume-vm-smoke.sh --unattended tahoe

# Keep VM for debugging
./tests/lume-vm-smoke.sh --keep --name labstrap-lume-debug
```

Notes:

- Requires macOS on Apple Silicon (`arm64`)
- Uses Lume's documented create/run flow with `--ipsw latest` by default
- Installs Lume automatically unless `--skip-install` is set
