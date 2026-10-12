# locspeedtest

Live local-network connections + speed monitor in a single Bash file. No install, no sudo, no dependencies beyond `curl` / `awk` / `netstat` / `ping`.

## Run it

```bash
# Option A — process substitution (recommended: keeps [t]/[q] keys working)
bash <(curl -fsSL https://raw.githubusercontent.com/USER/locspeedtest/v1.0.0/locspeed.sh)

# Option B — pipe (non-interactive, keys disabled, use flags)
curl -fsSL https://raw.githubusercontent.com/USER/locspeedtest/v1.0.0/locspeed.sh | bash -s -- --once

# Option C — clone
git clone https://github.com/USER/locspeedtest.git && cd locspeedtest && bash locspeed.sh
```

> Replace `USER` with the GitHub owner. Pin a tag (`v1.0.0`), never `main`, for anything you share.

### Verify before running (recommended for `curl | bash`)

```bash
curl -fsSL https://raw.githubusercontent.com/USER/locspeedtest/v1.0.0/locspeed.sh -o locspeed.sh
shasum -a 256 locspeed.sh   # compare with SHA256SUMS in Releases
bash locspeed.sh --once
```

## What it shows

- **local** — interface, local IP, gateway, DNS, Wi-Fi SSID (or `(wired)`), public IP (cached 5 min in `$TMPDIR`, `offline` when unreachable)
- **conns** — total / established / wait / listen TCP counts + top 5 remote talkers
- **ping** — gateway, `1.1.1.1`, `8.8.8.8` per-refresh RTT with a 30-sample sparkline trend
- **speed** — live down/up from per-interface byte counters every refresh; press `t` for a full 25 MB Cloudflare download probe

## Options

```
--interval N   refresh seconds (default 2, min 1)
--iface NAME   force interface (default: default route)
--once         one human snapshot, exit
--json         one JSON snapshot, exit (for scripting)
--no-color     disable ANSI colors (also honors NO_COLOR=1)
--no-pubip     skip public-IP lookup (faster, offline-safe)
-h, --help     help     -v, --version  version
```

Keys (interactive TTY only): `t` full speed test, `q` quit.

## Requirements

- `bash` 3.2+ (stock macOS Bash works), macOS or Linux
- Standard tools only: `curl`, `awk`, `netstat` (or `ss`), `ping`
- No sudo, no writes outside `${TMPDIR:-/tmp}`, HTTPS with `--proto '=https'` everywhere

## Security model

- Single file at repo root so the remote-run artifact is exactly what you audit
- `set -euo pipefail`, quoted expansions, no `eval` on network data, no `rm -rf`, no credential reads
- Pipe mode (`curl | bash`) auto-detects non-TTY stdin and disables key handling/prompts
