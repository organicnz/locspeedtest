# locspeedtest

Live local-network connections + speed monitor in a single Bash file. No install, no sudo, no dependencies beyond `curl` / `awk` / `netstat` / `ping`.

## Run it

```bash
# Option A — process substitution (recommended: keeps [t]/[q] keys working)
bash <(curl -fsSL https://raw.githubusercontent.com/organicnz/locspeedtest/HEAD/locspeed.sh)

# Option B — pipe (non-interactive, keys disabled, use flags)
curl -fsSL https://raw.githubusercontent.com/organicnz/locspeedtest/HEAD/locspeed.sh | bash -s -- --once

# Option C — clone
git clone https://github.com/organicnz/locspeedtest.git && cd locspeedtest && bash locspeed.sh
```

> The URLs use `HEAD` so they always track the latest commit on the default branch — no tag to bump, nothing to update. If you want a reproducible snapshot (same bytes every run), swap `HEAD` for a tag, e.g. `.../v1.4.0/locspeed.sh`.

### Verify before running (recommended for `curl | bash`)

```bash
curl -fsSL https://raw.githubusercontent.com/organicnz/locspeedtest/HEAD/locspeed.sh -o locspeed.sh
shasum -a 256 locspeed.sh   # compare with a pinned tag if you want a stable hash
bash locspeed.sh --once
```

Note: with `HEAD`, the file changes whenever the repo does, so its hash changes too — `SHA256SUMS` in the repo is a snapshot of whatever commit it was generated on. If you need to verify an exact, unchanging artifact, fetch by tag (`.../v1.4.0/locspeed.sh`) and compare against the hash recorded on that tag.

## What it shows

Output is a bordered table that fits your terminal width (default 80, min 56) with automatic wrapping — nothing is ever truncated or misaligned:

```
┌─ locspeed  │  iface en0  │  11:34:23 ───────────────────────────────┐
├─ SPEED ────────────────────────────────────────────────────────────────────┤
│ down 469 Kb/s    up 286 Kb/s                                               │
├─ LOCAL ────────────────────────────────────────────────────────────────────┤
│ ip 10.0.0.194    gateway 10.0.0.1    dns 100.100.100.100                   │
│ wifi — (wired)                                                             │
├─ PUBLIC ───────────────────────────────────────────────────────────────────┤
│ 203.0.113.42                                                               │
├─ CONNECTIONS ──────────────────────────────────────────────────────────────┤
│ total 129    established 85    time-wait 7    listen 36                    │
│ · 22x 127.0.0.1    · 4x 172.65.90.22    · 4x 142.250.141.188               │
│ · 3x 57.144.4.145    · 3x 172.67.142.245    · 3x 172.65.90.23              │
├─ TOP PROCESSES ────────────────────────────────────────────────────────────┤
│ PROCESS            DOWN       UP         SHARE                             │
│ opencode           610 Kb/s   28.8 Mb/s  ██████████                        │
│ Browser Helper     114 Kb/s   0 Kb/s     █░░░░░░░░░                        │
│ mDNSResponder      34 Kb/s    5 Kb/s     ░░░░░░░░░░                        │
│ IPNExtension       23 Kb/s    15 Kb/s    ░░░░░░░░░░                        │
│ netbiosd           19 Kb/s    0 Kb/s     ░░░░░░░░░░                        │
├─ PING ─────────────────────────────────────────────────────────────────────┤
│ gateway 6.084 ms    1.1.1.1 18.315 ms    8.8.8.8 28.145 ms                 │
│ trend ▁▁▂                                                                  │
└── [t] speed test   [q] quit ───────────────────────────────────────────────┘
```

- **SPEED** — live down/up from per-interface byte counters every refresh, plus the last full-probe result
- **LOCAL / PUBLIC** — interface, local IP, gateway, DNS, Wi-Fi SSID (or `(wired)`), public IP (cached 5 min in `$TMPDIR`, `offline` when unreachable)
- **CONNECTIONS** — total / established / time-wait / listen TCP counts + top remote talkers
- **TOP PROCESSES** — live per-process bandwidth with a relative share bar (macOS `nettop`; falls back to connection counts elsewhere)
- **PING** — gateway, `1.1.1.1`, `8.8.8.8` per-refresh RTT with a 30-sample sparkline trend
- Colors: green < 30 ms, yellow < 100 ms, red above; thresholds apply to RTT and process rates

## Options

```
--interval N   refresh seconds (default 2, min 1)
--iface NAME   force interface (default: default route)
--once         one human snapshot, exit
--json         one JSON snapshot, exit (for scripting)
--no-color     disable ANSI colors (also honors NO_COLOR=1)
--no-pubip     skip public-IP lookup (faster, offline-safe)
--no-top       hide the TOP PROCESSES section
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
