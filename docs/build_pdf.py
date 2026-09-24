"""Builds Lab-Relay-Reference.pdf - reference guide for the Lab-Relay solution."""
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.enums import TA_LEFT
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph, Spacer, Table,
                                TableStyle, PageBreak, KeepTogether, Preformatted)
from reportlab.graphics.shapes import Drawing, Rect, String, Line, Polygon
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
import sys

F = '/usr/share/fonts/truetype/dejavu/'
pdfmetrics.registerFont(TTFont('Sans', F + 'DejaVuSans.ttf'))
pdfmetrics.registerFont(TTFont('Sans-Bold', F + 'DejaVuSans-Bold.ttf'))
pdfmetrics.registerFont(TTFont('Sans-Oblique', F + 'DejaVuSans-Oblique.ttf'))
pdfmetrics.registerFont(TTFont('Mono', F + 'DejaVuSansMono.ttf'))
from reportlab.pdfbase.pdfmetrics import registerFontFamily
registerFontFamily('Sans', normal='Sans', bold='Sans-Bold', italic='Sans-Oblique', boldItalic='Sans-Bold')

INK = colors.HexColor('#1f2933'); MUTED = colors.HexColor('#5f6b7a'); ACCENT = colors.HexColor('#1d5fa8')
RULE = colors.HexColor('#d5dbe3'); SHADE = colors.HexColor('#f2f5f9'); CODEBG = colors.HexColor('#f5f5f2')
WARN = colors.HexColor('#9a5b00')

ss = {
    'title': ParagraphStyle('title', fontName='Sans-Bold', fontSize=22, leading=27, textColor=INK, spaceAfter=4),
    'sub':   ParagraphStyle('sub', fontName='Sans', fontSize=11, leading=15, textColor=MUTED, spaceAfter=14),
    'h1':    ParagraphStyle('h1', fontName='Sans-Bold', fontSize=14, leading=18, textColor=ACCENT, spaceBefore=14, spaceAfter=6),
    'h2':    ParagraphStyle('h2', fontName='Sans-Bold', fontSize=11, leading=14, textColor=INK, spaceBefore=10, spaceAfter=4),
    'body':  ParagraphStyle('body', fontName='Sans', fontSize=9.5, leading=13.5, textColor=INK, spaceAfter=6),
    'small': ParagraphStyle('small', fontName='Sans', fontSize=8.5, leading=11.5, textColor=MUTED, spaceAfter=4),
    'cell':  ParagraphStyle('cell', fontName='Sans', fontSize=8.5, leading=11.5, textColor=INK),
    'cellb': ParagraphStyle('cellb', fontName='Sans-Bold', fontSize=8.5, leading=11.5, textColor=INK),
    'bul':   ParagraphStyle('bul', fontName='Sans', fontSize=9.5, leading=13.5, textColor=INK, leftIndent=12, bulletIndent=2, spaceAfter=3),
    'code':  ParagraphStyle('code', fontName='Mono', fontSize=8, leading=10.5, textColor=INK),
    'note':  ParagraphStyle('note', fontName='Sans', fontSize=9, leading=12.5, textColor=INK, backColor=SHADE,
                            borderPadding=(6, 8, 6, 8), spaceBefore=4, spaceAfter=10),
}

def P(t, s='body'): return Paragraph(t, ss[s])
def B(items): return [Paragraph(i, ss['bul'], bulletText='•') for i in items]
def H1(t): return P(t, 'h1')
def H2(t): return P(t, 'h2')
def code(t):
    tb = Table([[Preformatted(t.strip('\n'), ss['code'])]], colWidths=[170 * mm])
    tb.setStyle(TableStyle([('BACKGROUND', (0, 0), (-1, -1), CODEBG), ('BOX', (0, 0), (-1, -1), 0.4, RULE),
                            ('LEFTPADDING', (0, 0), (-1, -1), 7), ('TOPPADDING', (0, 0), (-1, -1), 5),
                            ('BOTTOMPADDING', (0, 0), (-1, -1), 5)]))
    return tb
def table(rows, widths, head=True):
    data = [[Paragraph(str(c), ss['cellb' if (head and r == 0) else 'cell']) for c in row] for r, row in enumerate(rows)]
    t = Table(data, colWidths=[w * mm for w in widths], repeatRows=1 if head else 0)
    st = [('GRID', (0, 0), (-1, -1), 0.4, RULE), ('VALIGN', (0, 0), (-1, -1), 'TOP'),
          ('LEFTPADDING', (0, 0), (-1, -1), 5), ('RIGHTPADDING', (0, 0), (-1, -1), 5),
          ('TOPPADDING', (0, 0), (-1, -1), 3), ('BOTTOMPADDING', (0, 0), (-1, -1), 3)]
    if head: st.append(('BACKGROUND', (0, 0), (-1, 0), SHADE))
    t.setStyle(TableStyle(st)); return t

# ------------------------------------------------------------------ diagram --
def arrow(d, x1, y1, x2, y2, col=INK):
    d.add(Line(x1, y1, x2, y2, strokeColor=col, strokeWidth=1.1))
    import math
    a = math.atan2(y2 - y1, x2 - x1); L = 6
    p1 = (x2 - L * math.cos(a - 0.4), y2 - L * math.sin(a - 0.4)); p2 = (x2 - L * math.cos(a + 0.4), y2 - L * math.sin(a + 0.4))
    d.add(Polygon([x2, y2, p1[0], p1[1], p2[0], p2[1]], fillColor=col, strokeColor=col))

def box(d, x, y, w, h, title, lines, fill=SHADE):
    d.add(Rect(x, y, w, h, rx=5, ry=5, fillColor=fill, strokeColor=RULE, strokeWidth=0.8))
    d.add(String(x + 7, y + h - 14, title, fontName='Sans-Bold', fontSize=9, fillColor=INK))
    for i, l in enumerate(lines):
        d.add(String(x + 7, y + h - 27 - i * 11, l, fontName='Sans', fontSize=7.5, fillColor=MUTED))

def diagram():
    W, H = 170 * mm, 88 * mm
    d = Drawing(W, H)
    box(d, 0, 118, 140, 120, 'Laptop  hp-pav-dp', ['Cowork writes a .ps1', '  -> Lab-Relay\\outbox\\', 'Start-LabRelay.ps1 (watcher)', '  git push job (PAT)', '  git pull results', '  -> Lab-Relay\\results\\<job>\\'])
    box(d, 175, 118, 135, 120, 'GitHub', ['Lab-Relay-Channel (private)', '  jobs\\  results\\  sessions\\', '', 'Lab-Relay (public)', '  bootstrap.ps1, runner, helpers', '  (code only, no secrets)'], fill=colors.HexColor('#eef4fb'))
    box(d, 345, 118, 137, 120, 'A-GUI  10.1.1.201', ['Start-LabRunner.ps1', '  TLS check, device-flow sign-in', '  poll every 30 s (ETag)', '  run job in child pwsh', '  commit output + files', '  (token in memory only)'])
    # arrows top: jobs out
    arrow(d, 140, 205, 175, 205, ACCENT); d.add(String(143, 209, 'job', fontName='Sans', fontSize=7, fillColor=ACCENT))
    arrow(d, 310, 205, 345, 205, ACCENT); d.add(String(313, 209, 'poll', fontName='Sans', fontSize=7, fillColor=ACCENT))
    # arrows bottom: results back
    arrow(d, 345, 150, 310, 150, colors.HexColor('#2e7d32')); d.add(String(313, 154, 'result', fontName='Sans', fontSize=7, fillColor=colors.HexColor('#2e7d32')))
    arrow(d, 175, 150, 140, 150, colors.HexColor('#2e7d32')); d.add(String(143, 154, 'pull', fontName='Sans', fontSize=7, fillColor=colors.HexColor('#2e7d32')))
    # bottom band
    d.add(Rect(175, 20, 307, 70, rx=5, ry=5, fillColor=colors.white, strokeColor=RULE, strokeDashArray=[3, 2]))
    d.add(String(183, 74, 'Lab egress: upstream FortiGate (Skillable / hosting)', fontName='Sans-Bold', fontSize=8, fillColor=WARN))
    d.add(String(183, 61, 'Decrypts most HTTPS (e.g. relays.syncthing.net -> Fortinet CA).', fontName='Sans', fontSize=7.5, fillColor=MUTED))
    d.add(String(183, 50, 'GitHub hosts are NOT decrypted (Sectigo / Let\'s Encrypt seen).', fontName='Sans', fontSize=7.5, fillColor=MUTED))
    d.add(String(183, 39, 'Runner refuses to sign in if that ever changes.', fontName='Sans', fontSize=7.5, fillColor=MUTED))
    d.add(String(183, 28, 'Outbound HTTPS only - nothing connects in to the lab.', fontName='Sans', fontSize=7.5, fillColor=MUTED))
    d.add(Rect(0, 20, 140, 70, rx=5, ry=5, fillColor=colors.white, strokeColor=RULE, strokeDashArray=[3, 2]))
    d.add(String(8, 74, 'You, once per lab', fontName='Sans-Bold', fontSize=8, fillColor=INK))
    d.add(String(8, 61, '1. irm ... bootstrap.ps1 | iex', fontName='Sans', fontSize=7.5, fillColor=MUTED))
    d.add(String(8, 50, '   on A-GUI (pwsh 7)', fontName='Sans', fontSize=7.5, fillColor=MUTED))
    d.add(String(8, 39, '2. enter code at', fontName='Sans', fontSize=7.5, fillColor=MUTED))
    d.add(String(8, 28, '   github.com/login/device', fontName='Sans', fontSize=7.5, fillColor=MUTED))
    return d

# ------------------------------------------------------------------ content --
story = []
story += [P('Lab-Relay', 'title'),
          P('Two-way file relay between the laptop (Cowork) and a Skillable lab jump host (A-GUI) &mdash; reference guide', 'sub'),
          table([['Status', 'Working end to end. First live test passed 24 Sep 2026 (CCES lab, runner 0.1.0).'],
                 ['Code', 'github.com/Don-Paterson/Lab-Relay (public) &middot; local clone Documents\\ClaudeCowork\\Lab-Relay'],
                 ['Channel', 'github.com/Don-Paterson/Lab-Relay-Channel (private, Actions disabled)'],
                 ['GitHub App', 'Lab-Relay-app &middot; client ID Iv23liW99Woo8kRBZE5p &middot; Contents: read/write &middot; installed on Lab-Relay-Channel only'],
                 ['Laptop auth', 'Existing fine-grained PAT in Git Credential Manager (expires 21 Dec 2026)']], [28, 142], head=False),
          Spacer(1, 8)]

story += [H1('1. What it does'),
          P('Scripts written in Cowork reach the lab automatically, run there, and their output &mdash; text, log files and '
            'PNG screenshots &mdash; comes back to the laptop, with no clipboard, RDP, drive redirection or manual upload. '
            'It replaces the old save-to-file / easyupload.io / download routine.'),
          diagram(),
          P('Figure 1 &mdash; jobs flow left to right through the private channel repo; results flow back the same way. '
            'Both ends make outbound HTTPS calls only.', 'small')]

story += [H1('2. Why this design'),
          P('Every option ran into the same problem: getting a credential into a lab with no clipboard. The GitHub App '
            '<b>device flow</b> solves it &mdash; the lab displays a short code and you approve it on the laptop or phone, so '
            'nothing secret is ever typed into or stored in the lab.'),
          table([['Option', 'Verdict'],
                 ['GitHub repo + App device flow', '<b>Chosen.</b> Free, HTTPS only, atomic commits; 8-hour token limited to one repo; laptop reuses git + PAT.'],
                 ['Syncthing', 'Rejected after testing: the upstream FortiGate decrypts its TLS (Fortinet CA), which Syncthing\'s pinned certificates cannot survive. No bypass possible from inside the lab.'],
                 ['Azure Blob + SAS', 'Good credential but ~150 characters to type by hand each lab; small cost.'],
                 ['PAT inside the lab', 'Months-long credential at rest in a shared image.'],
                 ['Gist / paste services', 'Gist scope is all gists; pastes are public or unlisted.'],
                 ['OneDrive', 'Workable, but unpredictable sync timing and conflict copies; needs Entra app registration.'],
                 ['Claude in Chrome on the lab client', 'The VM console is pixels, not text &mdash; screenshot/OCR only.'],
                 ['Cowork / Claude Code on A-GUI', 'Needs nested virtualisation, or leaves a long-lived Claude login in the lab.']], [48, 122])]

story += [H1('3. Components'),
          table([['File', 'Runs on', 'Role'],
                 ['config\\relay.psd1', 'both', 'All settings: repo names, App client ID, poll intervals, timeouts, size limits, allowed file types, TLS issuer allow-list. Public; no secrets.'],
                 ['laptop\\Start-LabRelay.ps1', 'laptop', 'Watcher: sends outbox\\ scripts as jobs, pulls results, shows lab heartbeat, compacts channel history.'],
                 ['bootstrap.ps1', 'A-GUI', 'irm | iex entry point: downloads the code repo to Desktop\\Lab-Relay, unblocks it, starts the runner.'],
                 ['lab\\Start-LabRunner.ps1', 'A-GUI', 'Runner: TLS guard, device-flow sign-in, poll, run, upload.'],
                 ['lab\\LabRelay.Helpers.psm1', 'A-GUI', 'Save-RelayScreenshot, Save-RelayFile, Save-RelayText &mdash; pre-loaded into every job.'],
                 ['tests\\hello-lab.ps1', 'A-GUI', 'First end-to-end check: identity, IPs, lab ports, screenshot.'],
                 ['DESIGN.md / README.md', '&mdash;', 'Design record and quick start.']], [45, 17, 108])]

story += [H1('4. Starting a session'),
          H2('Laptop'),
          code(r'''cd $HOME\Documents\ClaudeCowork\Lab-Relay
.\laptop\Start-LabRelay.ps1'''),
          P('Wait for the green <i>Channel ready</i> line. Leave the window open; Ctrl+C stops it. Only one watcher can run per folder (lock file in logs\\).'),
          H2('A-GUI (every new lab)'),
          P('In <b>PowerShell 7</b> (pwsh), as Admin:'),
          code(r'''irm https://raw.githubusercontent.com/Don-Paterson/Lab-Relay/main/bootstrap.ps1 | iex'''),
          *B(['Three <i>TLS ... ok</i> lines confirm github.com, api.github.com and raw.githubusercontent.com present genuine public certificates.',
              'An 8-character code appears. On the laptop or phone open <b>github.com/login/device</b>, enter it, and authorise <b>Lab-Relay-app</b>. '
              'GitHub shows the request as coming from the lab\'s public IP (seen: London 185.254.59.121).',
              '<i>Signed in</i> then <i>Ready - polling every 30s</i>. Leave the window open. The token lasts 8 hours and is refreshed automatically.']),
          P('The GitHub wording &ldquo;Act on your behalf&rdquo; is standard for App user tokens; the token can only do what both you and the App can do &mdash; '
            'Contents read/write on Lab-Relay-Channel.', 'note')]

story += [H1('5. Job workflow in detail'),
          table([['#', 'Where', 'What happens'],
                 ['1', 'Cowork', 'Claude drafts the script anywhere in Lab-Relay, then moves the finished file into <b>outbox\\</b>. Drafts outside outbox\\ are never sent.'],
                 ['2', 'Watcher', 'Checks outbox\\ every 2 s. A file is sent only when it has been unchanged for 3 s and can be opened exclusively (no half-written files). '
                                  'Only .ps1 is accepted; anything else, or anything over 25 MB, goes to outbox\\rejected\\.'],
                 ['3', 'Watcher', 'Creates <b>jobs/&lt;jobId&gt;/</b> in the channel with the script (byte-for-byte) and job.json (sha256, queued time, timeout), commits and pushes. '
                                  'If the lab pushed in between, it rebases and retries (up to 8 times, jittered). Then moves the original to outbox\\sent\\&lt;jobId&gt;.ps1.'],
                 ['4', 'Runner', 'Polls the branch head every 30 s with If-None-Match &mdash; an unchanged channel costs a free 304. On change it reads the tree and finds jobs with no result.json.'],
                 ['5', 'Runner', 'Checks the job: queued more than 60 min before this lab session started &rarr; <i>expired</i>; sha256 or name mismatch &rarr; <i>rejected</i>. Otherwise commits result.json with status <i>running</i>.'],
                 ['6', 'Runner', 'Writes the script to C:\\LabRelay\\jobs\\&lt;jobId&gt;\\ and runs it in a child <b>pwsh -NoProfile -NonInteractive</b> with the helpers pre-loaded. '
                                 'All output streams (output, host, warning, error) are captured. Timeout default 600 s, header override, max 7200 s; on timeout the whole process tree is killed.'],
                 ['7', 'Runner', 'Uploads output.txt (stdout + stderr, head+tail truncated above 5 MB), any files saved to LABRELAY_OUT that pass the filters, and the final result.json '
                                 '&mdash; all in <b>one commit</b>. Deletes the local job folder.'],
                 ['8', 'Watcher', 'Pulls every 30 s. When a result reaches a final state it copies it into <b>results\\&lt;jobId&gt;\\</b>, applying the collector rules (section 7), result.json last.'],
                 ['9', 'Cowork', 'Claude reads results\\&lt;jobId&gt;\\ and follows up &mdash; fix, re-queue, next stage.']], [7, 17, 146]),
          Spacer(1, 6),
          KeepTogether([H2('Timing seen in the first live test'),
          table([['Time', 'Event'],
                 ['16:34:28', 'Watcher sent 20260924-153419-hello-lab-a97b25'],
                 ['16:37:45', 'A-GUI signed in (queued job still valid: under 60 min old)'],
                 ['16:37:52 - 16:38:56', 'Job ran, exit 0 (63 s, mostly port timeouts to 10.1.1.102)'],
                 ['16:39:28', 'Result on the laptop: output.txt, computer-info.txt, 1600x900 screenshot']], [38, 132])])]

story += [H2('Job states'),
          table([['Status', 'Meaning'],
                 ['running', 'Claimed by a runner session; shown on the laptop, not yet copied.'],
                 ['done', 'Exit code 0.'],
                 ['failed', 'Non-zero exit or a terminating error (stack trace in output.txt).'],
                 ['timeout', 'Killed after its timeout; partial output kept.'],
                 ['expired', 'Queued over 60 min before the lab session started &mdash; not run (protects a fresh lab from old work).'],
                 ['abandoned', 'Left <i>running</i> by a runner that stopped; marked by the next session.'],
                 ['rejected', 'Integrity or name check failed &mdash; not run.'],
                 ['error', 'The runner itself hit a problem handling the job.']], [25, 145])]

story += [H2('Writing scripts for the lab'),
          code(r'''# relay: timeout=1800
"Anything written to any stream ends up in output.txt"
Save-RelayScreenshot -Name 'smartconsole'          # PNG of the desktop
Save-RelayFile -Path C:\CCES-Automation-Logs\ftw.log   # return an existing file
Get-Service | Out-String | Save-RelayText -Name services.txt'''),
          P('Returned file types: .txt .log .json .csv .xml .png .jpg, up to 25 MB each. Environment inside a job: LABRELAY_OUT, LABRELAY_JOB, LABRELAY_SESSION. '
            'Jobs run one at a time, in queue order. Because jobs are non-interactive, a script that calls Read-Host fails instead of waiting &mdash; pass answers as parameters.', 'small')]

story += [H1('6. Where data lives, and retention'),
          P('Every job gets its own folder named by its <b>jobId</b> &mdash; <font name="Mono">yyyyMMdd-HHmmss-&lt;script&gt;-&lt;sha6&gt;</font> (UTC). '
            'The timestamp is unique to the second (bumped if two jobs collide), so a folder is never reused or overwritten, and re-sending the same script creates a new job.'),
          table([['Location', 'Contents', 'Kept for', 'Cleaned by'],
                 ['results\\&lt;jobId&gt;\\ (laptop)', 'output.txt, result.json, returned files, _skipped.txt', '<b>Permanently</b> &mdash; your history', 'Nothing automatic (you, or an optional prune later)'],
                 ['outbox\\sent\\ (laptop)', 'Each script exactly as sent, renamed to its jobId', 'Permanently', 'Nothing automatic'],
                 ['outbox\\rejected\\ (laptop)', 'Files that were not sent', 'Permanently', 'You'],
                 ['logs\\watcher-yyyyMMdd.log', 'One watcher log per day', 'Permanently', 'You'],
                 ['.channel\\ (laptop)', 'Working clone of the channel', 'Mirrors the channel', 'Compaction'],
                 ['Lab-Relay-Channel (GitHub)', 'jobs\\, results\\, sessions\\ and git history', 'Last 7 days once over 50 MB', 'Watcher compaction (hourly check)'],
                 ['C:\\LabRelay\\jobs\\ (A-GUI)', 'Script, wrapper, raw output while running', 'Until the job finishes', 'Runner; the VM itself is disposable']], [38, 52, 36, 44]),
          P('Scale: the first test used 50 KB, with a screenshot. A hundred similar jobs is about 5 MB on the laptop. All local working folders are git-ignored, '
            'so none of this ever reaches the public code repo.', 'small'),
          P('<b>Compaction</b> replaces the channel history with a single commit holding the last 7 days. It is skipped while any job is <i>running</i>, and pushes with a '
            'lease on the exact commit it started from, so a result the lab commits at the same moment cannot be lost. Run it by hand with '
            '<font name="Mono">.\\laptop\\Start-LabRelay.ps1 -Compact -Once</font>. It never touches results\\ on the laptop.', 'note')]

story += [H1('7. Security model'),
          table([['Item', 'Detail'],
                 ['Lab credential', 'GitHub App user token (ghu_), 8 hours, refreshed in memory 10 min before expiry. Refresh token (6 months) kept in runner memory only. '
                                    'Never written to disk, never printed. Close the window and it is gone.'],
                 ['What it can reach', 'Contents read/write on Lab-Relay-Channel only &mdash; no other repos, no account settings, no workflows (Actions disabled; App has no Workflows permission).'],
                 ['If stolen', 'For up to 8 hours: read lab outputs; queue scripts the lab would run (code execution in a disposable VM); plant files in results\\. '
                               'The last is the one that reaches the laptop &mdash; hence the collector rules.'],
                 ['Revoke', 'GitHub &rarr; Settings &rarr; Applications &rarr; Authorized GitHub Apps &rarr; Lab-Relay-app &rarr; Revoke. Or suspend the installation.'],
                 ['TLS guard', 'Before sign-in the runner checks each GitHub host\'s certificate chain and issuer organisation (DigiCert, Sectigo, Let\'s Encrypt, GlobalSign, Microsoft). '
                               'A Fortinet or any other issuer stops it: a token sent through inspection would be readable by whoever runs that firewall.'],
                 ['Laptop credential', 'Your existing PAT via Git Credential Manager, unchanged. It already covers all your repos.'],
                 ['Public code repo', 'No secrets. The App client ID is public by design; device flow needs no client secret. Never generate a client secret or private key for the App.']], [32, 138]),
          H2('Collector rules (laptop)'),
          *B(['Only folders whose name matches the jobId pattern are read; only top-level files; names must be plain (no leading dash, no paths).',
              'Extensions limited to .txt .log .json .csv .xml .png .jpg; 25 MB per file. Anything refused is listed in _skipped.txt.',
              '<b>Nothing collected is ever executed.</b> Result content is data, never instructions &mdash; including when Claude reads it.'])]

story += [H1('8. Awkward cases'),
          table([['Case', 'Handling'],
                 ['Half-written script', 'Stable-for-3 s plus exclusive-open test before sending; git commits are atomic.'],
                 ['Half-uploaded result', 'Output, files and result.json go up in one commit; the watcher copies result.json last.'],
                 ['Two updates in quick succession', 'Each file placed in outbox\\ is one job, run in order. Only finished files reach outbox\\.'],
                 ['Script hangs', 'Timeout kills the process tree (tested: child processes die too); partial output returned; status timeout.'],
                 ['Runner closed mid-job', 'Next session marks the job abandoned.'],
                 ['Old jobs in a new lab', 'Jobs queued over 60 min before the session started are marked expired, not run.'],
                 ['Large output', 'output.txt keeps the first and last 2.5 MB with a marker (tested at 6.8 MB).'],
                 ['Both ends pushing at once', 'Laptop rebases and retries; lab rebuilds its commit on the new head. Tested with commits landing every 0.3 s.'],
                 ['Token expiry', 'Silent refresh; if refused, the runner shows a new device code.'],
                 ['GitHub rate limit', 'About 120 conditional polls an hour; unchanged polls are free 304s.'],
                 ['Laptop offline', 'Jobs and results wait in the channel.'],
                 ['Upstream starts inspecting GitHub', 'TLS guard refuses to sign in and says why.']], [48, 122])]

story += [KeepTogether([H1('9. Running the CCES automation through the relay'),
          P('Each job is a thin wrapper that does exactly what a manual run does &mdash; it calls the CCES bootstrap from GitHub <b>main</b> in its non-menu form, then returns the logs:'),
          code(r'''# relay: timeout=3600
$u = 'https://raw.githubusercontent.com/Don-Paterson/CCES-R8120-Automation/main/bootstrap.ps1'
& ([scriptblock]::Create((irm $u))) -Action Prereqs
Get-ChildItem C:\CCES-Automation-Logs -File | ForEach-Object { Save-RelayFile -Path $_.FullName }''')]),
          H2('Change control &mdash; one line of history'),
          *B(['All CCES changes are made in <b>Documents\\ClaudeCowork\\CCES-R8120-Automation</b> (your local clone) and pushed to <b>main</b> by you with Update-Repo.ps1.',
              'The lab only ever gets CCES code from GitHub main &mdash; the same as your manual irm | iex. Changed CCES files are <b>never</b> sent through the relay.',
              'The channel carries only the small wrapper jobs and their results; it is not a second copy of any repo.',
              'Fix-and-test loop: Claude edits &rarr; you push &rarr; Claude queues a wrapper job &rarr; lab pulls the new main &rarr; Claude reads the result.',
              'The repo zip the bootstrap downloads is current immediately; bootstrap.ps1 itself comes from raw.githubusercontent.com, which caches for up to about 5 minutes.'])]

story += [KeepTogether([H2('Long stages and near-real-time monitoring (planned: runner 0.2)'),
          P('Today a result arrives only when the job finishes. That suits short stages (Prereqs, DryRun) but leaves a 20-40 minute FTW or Jumbo (JHFA) install '
            'invisible until the end. The planned change is <b>progress uploads</b>, entirely inside Lab-Relay:')]),
          table([['Piece', 'Change'],
                 ['Job header', 'New options, e.g. <font name="Mono"># relay: timeout=5400 progress=60 watch=C:\\CCES-Automation-Logs\\*.log</font>'],
                 ['Runner', 'While the job runs, every <i>progress</i> seconds it commits output-so-far plus current copies of the watched log files, with result.json still <i>running</i> '
                            'and a progress timestamp. Skipped when nothing changed. Final commit as today.'],
                 ['Watcher', 'Copies running snapshots into results\\&lt;jobId&gt;\\ as they arrive (overwritten by each newer snapshot, then by the final result), '
                             'and shows "updated hh:mm" lines.'],
                 ['Cost', 'About one small commit a minute while a long job runs (~40 for a Jumbo install); compaction keeps the channel small.'],
                 ['CCES scripts', '<b>No change needed for monitoring</b> &mdash; they already log to C:\\CCES-Automation-Logs and print progress to the console. '
                                  'A CCES change would only be needed if a stage prompts for input (jobs are non-interactive); that is checked by reading the code first.']], [26, 144]),
          P('Result: Claude sees the console output and CCES logs about a minute behind, can spot a stall or error mid-install, and can decide whether to let it run, stop it, or fix and re-run.', 'small')]

story += [KeepTogether([H1('10. Troubleshooting'), Spacer(1,0)]),
          table([['Symptom', 'Check'],
                 ['Watcher stuck at "Cloning channel"', 'A Git Credential Manager window may be waiting behind others; PAT expired (21 Dec 2026).'],
                 ['"Another watcher is already running"', 'Close the other window; the lock is logs\\watcher.lock.'],
                 ['Runner: "Refusing to sign in"', 'Read the issuer shown. Fortinet means GitHub is now being inspected upstream &mdash; do not work around it.'],
                 ['Runner: "Cannot see Lab-Relay-Channel"', 'App installation must include Lab-Relay-Channel (Settings &rarr; Applications &rarr; Lab-Relay-app).'],
                 ['Job shows expired', 'It was queued over 60 min before the runner started. Re-send it.'],
                 ['Lab shows "silent" on the laptop', 'No heartbeat for 20 min: runner window closed, lab suspended, or network down.'],
                 ['Screenshot black or wrong', 'Lab console locked or minimised in the lab client; the runner must be in the logged-in desktop.'],
                 ['PowerShell 5.1 error on A-GUI', 'Use pwsh (PowerShell 7). The bootstrap checks and says so.']], [52, 118]),
          Spacer(1, 6),
          H2('Key settings (config\\relay.psd1)'),
          table([['Setting', 'Value', 'Setting', 'Value'],
                 ['PollSeconds', '30', 'MaxOutputBytes', '5 MB'],
                 ['OutboxCheckSeconds', '2', 'MaxFileBytes', '25 MB'],
                 ['StableSeconds', '3', 'CompactThresholdMB', '50'],
                 ['DefaultTimeoutSeconds', '600', 'CompactKeepDays', '7'],
                 ['MaxTimeoutSeconds', '7200', 'StaleJobMinutes', '60']], [45, 40, 45, 40])]

def on_page(c, d):
    c.saveState()
    c.setFont('Sans', 7.5); c.setFillColor(MUTED)
    c.drawString(20 * mm, 12 * mm, 'Lab-Relay reference  ·  Don-Paterson/Lab-Relay  ·  24 Sep 2026')
    c.drawRightString(190 * mm, 12 * mm, f'Page {d.page}')
    c.setStrokeColor(RULE); c.setLineWidth(0.5); c.line(20 * mm, 16 * mm, 190 * mm, 16 * mm)
    c.restoreState()

out = sys.argv[1]
doc = BaseDocTemplate(out, pagesize=A4, leftMargin=20 * mm, rightMargin=20 * mm, topMargin=18 * mm, bottomMargin=22 * mm,
                      title='Lab-Relay reference', author='Don Paterson', subject='Laptop <-> Skillable lab file relay')
doc.addPageTemplates([PageTemplate(id='p', frames=[Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id='f')], onPage=on_page)])
doc.build(story)
print('built', out)
