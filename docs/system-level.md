# Rebuilding the machine around a restored home directory

`restore.sh` brings back files. This is the other half: what has to exist on a new machine before
those files add up to a working system.

Nothing here is backed up as binaries. Packages, drivers, and Python dependencies are recorded as
lists and reinstalled, because a 227 MB binary built for one architecture is worse than useless on
another, and because reinstalling is the supported path for all of it.

**Order matters.** Each step assumes the one before it.

---

## 0. Before anything, know what you are restoring from

```bash
cat backups/*/latest/MANIFEST.json | head -40
```

`machine.arch`, `machine.os` and `versions.codex` tell you what the source was. If the architecture
differs from the new machine, every compiled artefact below has to be fetched for the new one; the
data and configuration are unaffected.

Source machine as of 2026-09-16: **Ubuntu 24.04.4 LTS, aarch64, NVIDIA DGX Spark (GB10)**.

## 1. Base operating system

Install Ubuntu 24.04 LTS for the target architecture. Create the same username (`dzbohan`) with the
same UID, or the restored file ownership will not match.

```bash
id -u        # must match the source machine, 1000 on spark-5f4a
```

## 2. Packages

`apt-manual.txt` lists the 87 packages that were explicitly installed, dependencies excluded.

```bash
# Review first. It includes CUDA and NVIDIA HWE packages that only apply to this hardware,
# and a machine without that GPU should not install them.
grep -vE 'cuda|nvidia' docs/apt-manual.txt | xargs sudo apt install -y
```

`snap-list.txt` records the snaps. Most are desktop pieces (Firefox, GNOME) and only matter if the
new machine has a desktop session.

Two things are worth installing that were **not** on the source machine:

- `smartmontools` gives the weekly backup its drive-health check, and installing the package is
  not enough on its own. `smartctl` lives in `/usr/sbin`, which is not on a normal user's PATH,
  and reading a raw block device needs root, which the backup does not have. Run
  `sudo ~/Scripts/setup-smart-monitoring.sh`, which installs the package and adds a sudoers rule
  scoped to `/usr/sbin/smartctl` alone. Without it the backup still works, but the only layer that
  warns *before* data is lost stays inert.
- `ffmpeg` was absent on the source machine, which is why the codex assistant's foreground command
  ban lists commands that do not exist there. Install it only if media work is needed.

## 3. NVIDIA and CUDA

Not reinstallable from a list in any meaningful sense: driver and CUDA versions are tied to the
kernel and the hardware. Follow NVIDIA's instructions for the specific machine. The packages under
`cuda*` and `*nvidia*` in `apt-manual.txt` show what the source machine had, as a reference point,
not as a command to run.

Verify before continuing, because the STT service will not start without a working GPU stack:

```bash
nvidia-smi
python3 -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

## 4. Sandbox prerequisites for the codex assistant

```bash
sudo apt install -y bubblewrap
bwrap --version                      # 0.9.0 on the source machine
```

Ubuntu 24.04 blocks unprivileged user namespaces, which the codex sandbox needs. The source machine
carried a narrow AppArmor exception rather than disabling the restriction globally. Recreate
`/etc/apparmor.d/codex-userns`:

```
abi <abi/4.0>,
include <tunables/global>

profile codex-userns /home/dzbohan/.local/bin/codex flags=(unconfined) {
  userns,
  include if exists <local/codex-userns>
}

profile codex-userns-helper /home/dzbohan/.codex/tmp/arg0/*/codex-linux-sandbox flags=(unconfined) {
  userns,
  include if exists <local/codex-userns>
}
```

Then `sudo apparmor_parser -r /etc/apparmor.d/codex-userns`.

⚠️ **Do not test this with bare `bwrap`.** The profile is scoped to the codex binary's path, so a
direct `bwrap` call still fails with `setting up uid map: Permission denied`, which looks like the
exception did not work. Test the thing that matters instead:

```bash
cd ~/Codex && codex sandbox -c 'sandbox_mode="read-only"' -- /bin/echo SANDBOX_OK
```

## 5. Binaries that are not packages

| What | Where it goes | How to get it |
|---|---|---|
| `codex`, `codex-code-mode-host` | `~/.local/bin/` | GitHub release `rust-v<version>`, the pair must match. See `codex-assistant-upgrade-*.md` under `~/codex-assistant/` for the exact procedure and sha256 handling |
| `claude` | `~/.local/bin/claude` → `~/.local/share/claude/versions/<v>` | Claude Code installer |
| `bun` | `~/.bun/bin/bun` | Needed by the Telegram plugin |

Both codex files are architecture-specific. The manifest records which architecture the snapshot
came from.

## 6. Python environments

Only one virtualenv exists, for the speech-to-text service:

```bash
cd ~/Claude/stt-api
python3 -m venv venv
./venv/bin/pip install -r <path to>/docs/stt-api-requirements.txt
```

The Whisper model itself lives under `~/Claude/stt-api/models/` and **is** in the backup. It is not
re-downloadable on this network: the Hugging Face CDN is blocked here, which is also why
`~/.deepcell` is backed up rather than excluded.

## 7. Services

Unit files are restored to `~/.config/systemd/user/` but left disabled, so a half-built machine
does not start a Telegram bridge and answer messages with stale state. Copies are in
`docs/systemd-units/` for comparison.

```bash
loginctl enable-linger $USER          # or services stop when you log out
systemctl --user daemon-reload
systemctl --user enable --now stt-api.service
systemctl --user enable --now claude-tg.service claude-tg-watchdog.service
systemctl --user enable --now codex-tg.service
systemctl --user enable --now dgx-backup.timer
```

Start the STT service first: both assistants' voice handling depends on it.

Check each unit's `ExecStart` path exists before enabling it. The paths are absolute and assume the
same username.

## 8. Credentials, and what will not work immediately

| Credential | File | State after restore |
|---|---|---|
| Claude OAuth | `~/.claude/.credentials.json` | Refresh token lasts 30 days. Expect to run `/login` |
| Telegram bot tokens | `~/.claude/channels/telegram/.env`, `~/.codex/telegram/.env` | Do not expire |
| codex account | `~/.codex/auth.json` | May need `codex login` |
| SSH key | `~/.ssh/id_ed25519` | Works if mode is still 600. Verify with `ssh -T git@github.com` |

## 9. Network facts that will not be obvious

If the new machine is on the same institutional network:

- Outbound NTP (udp/123) is blocked. Time syncs against internal servers instead; see
  `/etc/systemd/timesyncd.conf.d/10-internal-ntp.conf` in the backup, and `~/Scripts/fix-clock-ntp.sh`.
- The Hugging Face CDN is blocked, so model downloads fail in ways that look like network faults.
- The system timezone was set to `America/Los_Angeles` on 2026-09-15. Log file names assume local
  dates; set the timezone before writing any.

---

## Keeping this file honest

These inventories are snapshots of one machine on one day, regenerated when they drift:

```bash
apt-mark showmanual > docs/apt-manual.txt
snap list | awk 'NR>1{print $1"\\t"$2}' > docs/snap-list.txt
(cd ~/Claude/stt-api && ./venv/bin/pip freeze) > docs/stt-api-requirements.txt
cp ~/.config/systemd/user/*.service ~/.config/systemd/user/*.timer docs/systemd-units/
```

**This procedure has not been executed end to end on a clean machine.** It is assembled from what
the current machine actually has, not from a rehearsal. Treat step counts and ordering as
carefully reasoned, not as measured.
