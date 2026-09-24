# Lab-Relay — design

Two-way file relay between the laptop (hp-pav-dp, Cowork) and a Skillable lab jump host (A-GUI),
so scripts written in Cowork run in the lab and their output (text and PNG) comes back
without copy-and-paste.

Status: **Working end to end — first live lab test passed 24 Sep 2026** (CCES lab, A-GUI, runner 0.1.0): device-flow sign-in, job run, output + PNG screenshot + text file returned.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Rendezvous | Private GitHub repo `Don-Paterson/Lab-Relay-Channel` | Free, HTTPS only, atomic commits, laptop already has git + PAT |
| Lab credential | GitHub App user token via **device flow** | Nothing typed into the lab, no secret shipped, 8 h expiry, one repo only |
| Laptop credential | Existing fine-grained PAT (Git Credential Manager) | Already in place; renewal due 21 Dec 2026 |
| Code delivery | Public repo `Don-Paterson/Lab-Relay`, `irm \| iex` bootstrap | Same pattern as CCES-R8120-Automation |
| Trigger | Explicit `outbox\` folder | Drafts never run by accident; Claude moves a script there when ready |
| Laptop watcher | Started by hand per lab session (`Start-LabRelay.ps1`) | Nothing running when there is no lab; a logon scheduled task can be added later |

### Rejected, and why

- **Syncthing** — the lab egress passes through an upstream FortiGate (FG6H0E…, default Fortinet
  CA) doing TLS deep inspection. Syncthing's pinned discovery and device certificates cannot
  survive that, and the firewall is outside the lab so no bypass is possible.
- **Azure Blob + SAS** — good credential, but the SAS would have to be typed into a console with
  no clipboard, every lab. Small but non-zero cost.
- **PAT inside the lab** — a months-long credential at rest in a shared image.
- **Gist / paste services** — gist scope is all gists; pastes are public or unlisted.
- **OneDrive** — workable (device code), but sync timing and conflict copies are unpredictable and
  it needs an Entra app registration.
- **Claude in Chrome reading the lab client** — VM console is rendered as pixels; screenshot/OCR
  only. May still be useful for *typing* the bootstrap line.
- **Cowork / Claude Code on A-GUI** — Cowork needs nested virtualisation; Claude Code would leave
  a long-lived Claude login on the lab disk.

### Network facts (verified 23 Sep 2026 from A-GUI)

| Host | Certificate issuer seen from A-GUI | Inspected? |
|---|---|---|
| relays.syncthing.net | Fortinet (FG6H0E5819900865) | **Yes** |
| raw.githubusercontent.com | Let's Encrypt | No |
| api.github.com | Sectigo | No |

The GitHub exemption could change without notice, so the bootstrap checks issuers before it
authenticates and refuses to send a token if any GitHub host presents a Fortinet (or otherwise
unexpected) certificate.

## Layout

### Laptop — `Documents\ClaudeCowork\Lab-Relay` (clone of the public code repo)

```
Lab-Relay\
  bootstrap.ps1            lab entry point (irm | iex)
  lab\                     lab runner + helper module
  laptop\                  Start-LabRelay.ps1 (watcher / collector)
  config\relay.psd1        repo names, App client ID, timeouts (no secrets)
  outbox\                  <- drop a .ps1 here to run it in the lab        (git-ignored)
  outbox\sent\             watcher moves it here once pushed               (git-ignored)
  results\<jobId>\         output.txt, result.json, *.png from the lab     (git-ignored)
  .channel\                watcher's working clone of Lab-Relay-Channel    (git-ignored)
```

### Channel repo — `Lab-Relay-Channel` (private)

```
jobs\<jobId>\job.json          id, script name, sha256, queued time, timeout
jobs\<jobId>\<script>.ps1
results\<jobId>\result.json    status, exit code, start/end, duration, session, truncated flags
results\<jobId>\output.txt     stdout + stderr
results\<jobId>\*.png          screenshots / other permitted files
sessions\<sessionId>.json      lab heartbeat: host, started, last seen, runner version
```

`jobId` = `yyyyMMdd-HHmmss-<script-name>-<first 6 of sha256>`.

## Flow

1. Claude writes/edits a script anywhere in Lab-Relay, then moves it into `outbox\`.
2. **Laptop watcher** sees it, waits until size and mtime have been stable for 3 s and the file
   can be opened exclusively, creates `jobs\<jobId>\`, commits and pushes, then moves the
   original to `outbox\sent\`.
3. **Lab runner** polls `GET /repos/.../commits/main` every 30 s with `If-None-Match` (304s do
   not count against the rate limit). On a new head it lists `jobs\` and picks up any job with
   no `results\<jobId>\result.json`.
4. It commits `result.json` with `status=running` (so a job is visibly claimed), then runs the script in a child `pwsh`
   (`-NoProfile`), with the helper module pre-imported and `$env:LABRELAY_OUT` pointing at a
   folder for extra files.
5. When the script ends (or times out) it uploads `output.txt`, `result.json` and any files from
   `LABRELAY_OUT` as **one commit** via the Git Data API (blobs → tree → commit → update ref;
   on a non-fast-forward it rebuilds on the new head and retries).
6. **Laptop watcher** `git pull`s every 30 s and copies each finished result into
   `results\<jobId>\`, applying the collector rules below. Claude reads them from there.

## Lab session start

```
irm https://raw.githubusercontent.com/Don-Paterson/Lab-Relay/main/bootstrap.ps1 | iex
```

1. Downloads the code repo to `Desktop\Lab-Relay` and clears mark-of-the-web.
2. TLS issuer check on github.com, api.github.com, raw.githubusercontent.com — abort on Fortinet.
3. Device flow: shows an 8-character code in large text. Don enters it at
   `github.com/login/device` on the laptop or phone and approves.
4. Token (8 h) and refresh token held **in process memory only** — never written to disk,
   never printed, not captured by any transcript. Refreshed in memory before expiry; if the
   window is closed, re-run the bootstrap and approve a new code.
5. Creates `sessions\<sessionId>.json`, then enters the poll loop with a live status display.

**Stale-job rule:** a new session runs jobs with no result only if they were queued within the
last 60 minutes before it started; older unclaimed jobs are marked `expired` and not run.

## Helper functions available to lab scripts

- `Save-RelayScreenshot [-Name]` — full-screen PNG into `LABRELAY_OUT` (runner is in the
  interactive Admin session, so the desktop is capturable).
- `Save-RelayFile -Path` — copy a file into `LABRELAY_OUT` for return.
- `Save-RelayText -Name` — write piped text to its own returned file.
- Per-script options in header comments:
  `# relay: timeout=5400 progress=60` and `# relay: watch=C:\CCES-Automation-Logs\*.log` (one path per line).

## Live progress (runner 0.2.0, 24 Sep 2026)

With `progress=N` (30–600 s) the runner, while the job runs, commits output-so-far plus the current
contents of any `watch=` files (read with shared access, head+tail if huge) and result.json still
`running` with `progressUtc`, `progressCount`, `elapsedSeconds`. A snapshot is skipped if nothing changed.
The watcher copies each snapshot into `results\<jobId>\` in place; the final result overwrites it.
Watched files are also returned in the final result, so wrappers need not copy logs themselves.
Cost: one small commit per interval while a long job runs. Tested: 80 s job, updates at 30 s and 60 s
reached the laptop within ~3 s each.

## Awkward cases

| Case | Handling |
|---|---|
| Partial write on the laptop | Stable-for-3 s + exclusive-open test before commit; git commit is atomic |
| Partial result upload | One commit per result set; `result.json` written last in the same tree |
| Two updates in quick succession | Each file that lands in `outbox\` is one job, run in queue order. Only finished files are sent, because drafting happens outside `outbox\`. Re-sending identical content runs it again on purpose; jobIds stay unique (the timestamp moves on a second if needed) |
| Script hangs | Default timeout 600 s (header override). Process tree killed (`taskkill /T /F`), partial output uploaded, `status=timeout` |
| Runner crashes mid-job | Next start finds `status=running` from a dead session → marks it `abandoned` |
| Large output | `output.txt` truncated at 5 MB (head + tail kept, flag set); single file limit 25 MB; anything bigger rejected with a note |
| Repo growth | `Start-LabRelay.ps1 -Compact` replaces history with a single orphan commit of the last 7 days; runs automatically when the channel exceeds 50 MB. The lab reads the head fresh each poll, so a force-push is harmless |
| Token expiry | Refreshed in memory 10 min before expiry (device-flow tokens refresh without a client secret); if refresh fails the runner shows a new device code |
| Timestamps | PowerShell 7.4 `ConvertFrom-Json` returns DateTime objects; all comparisons are done in UTC on those objects (a string re-parse was an hour out in BST) |
| Rate limit | ~120 conditional polls/h; well under 5 000/h |
| Laptop offline | Jobs and results wait in the repo |

## Security

**Lab token if stolen:** read/write on `Lab-Relay-Channel` only, for at most 8 hours (refresh token
lives only in runner memory). No other repos, no account settings, no Actions (disabled on the
repo; App has no Workflows permission). Revoke everything at
GitHub → Settings → Applications → Authorized GitHub Apps.

What an attacker could do with it: read lab outputs; queue scripts the lab will run (code
execution in a disposable VM); plant files in `results\`. The last is the one that reaches the
laptop, so the **collector rules** are strict:

- Only files under `results\<jobId>\` with jobId matching the expected pattern; names sanitised,
  no `..`, no absolute paths, no alternate data streams.
- Allowed extensions: `.txt .log .json .csv .xml .png .jpg`. Everything else is skipped and noted.
- Size caps as above.
- **Nothing collected is ever executed** by the watcher. Result content is data, never
  instructions — including when Claude reads it.

**Laptop PAT:** unchanged location (Git Credential Manager); its repository list must include
`Lab-Relay` and `Lab-Relay-Channel`.

**Public code repo:** contains no secrets. The GitHub App client ID is public by design; device
flow needs no client secret.

## One-off setup (Don)

1. **Code repo** — create public `Don-Paterson/Lab-Relay`, empty (no README).
2. **Channel repo** — create private `Don-Paterson/Lab-Relay-Channel` *with* a README so `main`
   exists. Settings → Actions → General → *Disable actions*.
3. **GitHub App** — Settings → Developer settings → GitHub Apps → New GitHub App:
   - Name: anything unique, e.g. `lab-relay-don`
   - Homepage URL: `https://github.com/Don-Paterson/Lab-Relay`
   - Callback URL: leave empty
   - **Expire user authorization tokens**: ticked
   - **Enable Device Flow**: ticked
   - Webhook → **Active**: unticked
   - Repository permissions → **Contents: Read and write** (Metadata: Read is automatic). Nothing else.
   - Where can this app be installed: **Only on this account**
   - Create, then note the **Client ID** (starts `Iv`). Do not generate a client secret or private key.
   - Install App → your account → **Only select repositories** → `Lab-Relay-Channel`.
4. **PAT** — edit the existing fine-grained token → Repository access → add `Lab-Relay` and
   `Lab-Relay-Channel` (Contents: read/write). Editing does not change the token value.
5. **Local folder** — in `Documents\ClaudeCowork\Lab-Relay`:
   `git init -b main; git remote add origin https://github.com/Don-Paterson/Lab-Relay.git`
6. Send Claude the Client ID. **Done 23 Sep 2026** — `Iv23liW99Woo8kRBZE5p`, App "Lab-Relay-app",
   installed on Lab-Relay-Channel only; Actions disabled on the channel.

## Build order

1. `config\relay.psd1`, `.gitignore`, README.
2. Laptop `Start-LabRelay.ps1` (watcher + collector + compact), tested locally against the channel repo.
3. Lab `bootstrap.ps1` + runner (issuer check, device flow, poll, run, upload) + helper module.
4. End-to-end test in a lab: hello-world, a hang (timeout), a large output, a screenshot.
