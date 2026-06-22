# Install guide — for Claude Code

**You are Claude Code, running on the printer owner's Mac. Your job: install and
configure "Printer Don't Die Please!!" for the user (the printer owner), then verify it
works.** Follow these steps in order. Run the commands yourself; only ask the
user where a human decision is required (which printer, permission to print a
test page, clicking the macOS permission prompt).

## What this tool does (so you can explain it if asked)

It stops an idle **inkjet** printer's nozzles from drying out / clogging by
printing a tiny page on a schedule (default every 14 days). The page fires every
ink channel (C/M/Y/K) as thin full-height lines, so every nozzle stays wet using
minimal ink. It picks intensity automatically from how long it's been since the
last print (light → medium → heavy), pops a heads-up notification before each
print, and logs every run. It's a macOS launchd "user agent" plus a `pkeep`
control command.

## Prerequisites — check these first

1. **macOS** (this is macOS-only; it uses launchd, CUPS/`lp`, AppleScript).
2. **python3** is required (the only runtime dependency — it builds the PDF):
   ```sh
   python3 --version
   ```
   If that errors or triggers an "install command line developer tools" prompt,
   tell the user to click **Install** and wait for it to finish, or run
   `xcode-select --install`. Re-check before continuing.
3. **The printer must already be added** to the Mac (System Settings ▸ Printers
   & Scanners). List what's installed:
   ```sh
   lpstat -p
   ```
   If no inkjet is listed, ask the user to add their printer first, then re-run.

## Step 1 — locate the project folder

The user was given a folder named `printer-maintenance`. Find it (check common
spots, then ask if not found):
```sh
ls -d ~/Downloads/printer-maintenance ~/Desktop/printer-maintenance ~/printer-maintenance 2>/dev/null
```
`cd` into whichever exists. Confirm it contains `install.sh` and `src/`:
```sh
ls install.sh src/pkeep src/printer-keepalive.sh
```

## Step 2 — run the installer

```sh
./install.sh
```
This installs into `~/Library/Scripts`, builds a notifier app, registers the
launchd agent (every 14 days), and adds a `pkeep` shell alias.

**A macOS "Allow Notifications?" prompt will appear** (from
"PrinterKeepaliveNotifier"). Tell the user to click **Allow** — that's what lets
the heads-up notification work. (If they miss it, you can re-trigger it in
Step 5.)

The `pkeep` alias only exists in *new* shells. For the rest of this session,
call the control script by full path:
```sh
PKEEP=~/Library/Scripts/pkeep
```

## Step 3 — set the user's printer(s)

List printers and **ask the user which one(s) are their inkjet(s)** (don't
guess — they may have several, and only inkjets benefit from this):
```sh
lpstat -p
```
Set a single printer (exact name from `lpstat -p`, e.g. `Canon_TS7700_series`):
```sh
"$PKEEP" printer "THEIR_PRINTER_NAME"
```
If they have **more than one inkjet**, add each — the keep-alive then runs on
all of them every cycle (or they can tick them in the menu under Settings ▸
Printers):
```sh
"$PKEEP" printer add "SECOND_PRINTER_NAME"
```

Optional — change the schedule if the user wants (default 14 days; 7–14 is a good
range for most inkjets):
```sh
"$PKEEP" interval 14      # days
```

## Step 4 — test print (ask first)

A keep-alive print uses one sheet + a little ink. **Ask the user for permission
to print a test page now.** If yes:
```sh
"$PKEEP" run
```
Expect: a heads-up notification, ~8 seconds, then the page prints. Verify it
went through:
```sh
lpstat -p "THEIR_PRINTER_NAME"     # should return to "is idle"
"$PKEEP" log                       # should show one entry
```
Ask the user to check the output tray: they should see a CMYK test strip across
the top (cyan, magenta, yellow, black bars) with an ink-level gauge on the
divider below it, then a mostly-blank page (or note paper if enabled). If any of
the colour bars are broken/faint/missing, that channel is partly clogged and the
user should run the printer's built-in cleaning once.

## Step 5 — verify notification (optional)

If the user didn't see a notification during the test, fire one directly:
```sh
PKA_TITLE="Printer Don't Die Please!!" PKA_BODY="Test ✅" \
  ~/Library/Scripts/PrinterKeepaliveNotifier.app/Contents/MacOS/applet
```
If still nothing, open System Settings ▸ Notifications and ensure
"PrinterKeepaliveNotifier" is allowed.

## Step 6 — confirm it's scheduled

```sh
"$PKEEP" status
```
Confirm `Agent: ON`, the right `Printer:`, and `Schedule:`. The agent runs on its
interval whenever the Mac is on and logged in (if asleep at the scheduled time it
runs on the next wake). **Tell the user: the Mac must be powered on and the
printer powered on for a scheduled print to happen.**

## Daily use (tell the user)

- `pkeep` — open the interactive menu (↑/↓ move, enter select, q quit)
- `pkeep run` — print one now
- `pkeep status` — show schedule / last print
- `pkeep log` — history
- `pkeep off` / `pkeep on` — pause / resume the schedule
- `pkeep update` — install the latest version (signed + checksum-verified); or
  turn on Settings ▸ Auto-update for a daily check

## Troubleshooting

| Symptom | Fix |
|---|---|
| `python3` not found | `xcode-select --install`, then re-run `./install.sh` |
| Nothing prints | Printer powered on? `lpstat -p NAME`; check the job didn't error in `~/Library/Logs/printer-keepalive.err.log` |
| Wrong/no printer | `pkeep printer "NAME"` (exact name from `lpstat -p`) |
| No notification | Re-run Step 5; allow it in System Settings ▸ Notifications |
| Agent not running | `pkeep on`, then `pkeep status` |
| Want to stop entirely | `./uninstall.sh` (add `--purge` to also delete logs/state) |

## Done

When `pkeep status` shows the agent ON with the user's printer and a successful
test print is logged, the install is complete. Summarize for the user: it will
quietly print a small nozzle-care page on the schedule, with a heads-up
notification first, as long as the Mac and printer are on.
