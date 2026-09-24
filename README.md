# Lab-Relay

Two-way file relay between a laptop running Claude Cowork and a Skillable lab jump host (A-GUI).
Scripts dropped in `outbox\` on the laptop run in the lab; their output and screenshots come back
to `results\`. Transport is a private GitHub repo; the lab signs in with a short-lived GitHub App
token via device flow, so no credential is ever typed into or stored in the lab.

See [DESIGN.md](DESIGN.md) for the full design, security model and edge cases.

## Laptop

```powershell
cd $HOME\Documents\ClaudeCowork\Lab-Relay
.\laptop\Start-LabRelay.ps1
```

Leave the window open while a lab is in use. Drop a `.ps1` into `outbox\` to run it; results land
in `results\<jobId>\` (`output.txt`, `result.json`, any PNGs).

Per-script options go in a header comment:

```powershell
# relay: timeout=1800
```

## Lab (A-GUI)

In **PowerShell 7** (`pwsh`), as Admin:

```powershell
irm https://raw.githubusercontent.com/Don-Paterson/Lab-Relay/main/bootstrap.ps1 | iex
```

1. It checks that github.com, api.github.com and raw.githubusercontent.com present genuine
   public certificates, and refuses to sign in if any is being inspected.
2. It shows an 8-character code. On the laptop or phone open <https://github.com/login/device>,
   enter it, and approve **Lab-Relay-app**.
3. It polls the channel and runs each job. Leave the window open; Ctrl+C stops it.

The token exists only in that window's memory (8 h, refreshed automatically) and can reach
only Lab-Relay-Channel.

## Writing scripts for the lab

Everything a script writes to any output stream lands in `output.txt`. These helpers are
pre-loaded, and anything they save comes back alongside it:

| Helper | Does |
|---|---|
| `Save-RelayScreenshot [-Name x] [-PrimaryOnly]` | PNG of the lab desktop |
| `Save-RelayFile -Path C:\path\file.log` | Return an existing file (.txt .log .json .csv .xml .png .jpg) |
| `... \| Save-RelayText -Name report.txt` | Write piped text to its own returned file |

Header options: `# relay: timeout=1800` (seconds, default 600, max 7200).

A job is `done` (exit 0), `failed` (non-zero exit or a terminating error), `timeout` (process
tree killed, partial output kept), `expired` (queued over 60 min before the lab session
started), `abandoned` (runner stopped mid-job) or `rejected` (integrity check failed).
