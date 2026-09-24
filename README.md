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

```powershell
irm https://raw.githubusercontent.com/Don-Paterson/Lab-Relay/main/bootstrap.ps1 | iex
```

Enter the code it shows at <https://github.com/login/device>, and approve. *(Lab side: in progress.)*
