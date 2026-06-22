#!/bin/bash
# Copyright 2026
# SPDX-License-Identifier: Apache-2.0
#
# printer-keepalive.sh — the worker. Prints a nozzle keep-alive page to stop an
# idle inkjet's nozzles drying out / clogging, and posts a heads-up notification
# first so whoever's at the machine knows the printer is about to wake.
#
# The test strip (all ink channels, C/M/Y/K) runs across the top of the page so
# the area below stays free — optionally filled with ruled lines so the sheet
# doubles as note paper (the LINES_FLAG toggle). Three intensities, scaling the
# strip's ink so a longer idle gap gets a deeper flush:
#
#   light   thin colour bars across the top — routine, minimal ink
#   medium  taller bars — a catch-up flush
#   heavy   thick bars, printed twice — a deep flush
#
# Note: concentrating the strip at the top is great for routine clog PREVENTION;
# the heavy tier uses taller bars (more vertical travel) for a thorough flush.
#
# Intensity is chosen automatically from how long it's been since the last
# successful print: if the Mac was off/asleep across one or more scheduled runs,
# the gap is long, so a heavier flush is printed to clear any partial drying.
#
# Usage:
#   printer-keepalive.sh                 # auto intensity, notify, print, log
#   printer-keepalive.sh --tier medium   # force light|medium|heavy
#   printer-keepalive.sh --dry [tier]    # build + open the PDF, don't print
#
set -euo pipefail

# --- paths / state (mirrors dsort's ~/Library/Scripts convention) ----------
SCRIPTS="$HOME/Library/Scripts"
PRINTER_FILE="$SCRIPTS/printer_keepalive.printer"     # selected printers, one name per line
INTERVAL_FILE="$SCRIPTS/printer_keepalive.interval"   # schedule seconds
LEAD_FILE="$SCRIPTS/printer_keepalive.lead"           # heads-up lead seconds
NONOTIFY_FLAG="$SCRIPTS/printer_keepalive.nonotify"   # presence = notifications OFF
LINES_FLAG="$SCRIPTS/printer_keepalive.lines"         # legacy on/off flag (pre-style)
NOTESTYLE_FILE="$SCRIPTS/printer_keepalive.notestyle" # off | lines | grid | dots
NOTESPACING_FILE="$SCRIPTS/printer_keepalive.notespacing"  # rule spacing in mm
LASTPRINT_FILE="$SCRIPTS/printer_keepalive.lastprint" # epoch of last good print
HISTORY_FILE="$SCRIPTS/printer_keepalive.history"     # TSV: epoch ISO tier days copies printer job
LOG="$HOME/Library/Logs/printer-keepalive.log"
NOTIFIER="$SCRIPTS/PrinterKeepaliveNotifier.app/Contents/MacOS/applet"

DEFAULT_INTERVAL=1209600   # 14 days
DEFAULT_LEAD=8             # seconds of heads-up before the print starts

# --- small helpers ---------------------------------------------------------
trim() { tr -d ' \t\n\r'; }

# selected printers, one per line. If none chosen, fall back to the system
# default destination so it still works out of the box.
get_printers() {
    if [ -r "$PRINTER_FILE" ] && [ -s "$PRINTER_FILE" ]; then
        grep -vE '^[[:space:]]*$' "$PRINTER_FILE"
    else
        lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p' | head -1
    fi
}
get_interval() {
    local v=""; [ -r "$INTERVAL_FILE" ] && v=$(trim < "$INTERVAL_FILE")
    case "$v" in ''|*[!0-9]*) echo "$DEFAULT_INTERVAL" ;; *) echo "$v" ;; esac
}
get_lead() {
    local v=""; [ -r "$LEAD_FILE" ] && v=$(trim < "$LEAD_FILE")
    case "$v" in ''|*[!0-9]*) echo "$DEFAULT_LEAD" ;; *) echo "$v" ;; esac
}
get_last() {
    local v=""; [ -r "$LASTPRINT_FILE" ] && v=$(trim < "$LASTPRINT_FILE")
    case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}
notify_on() { [ ! -e "$NONOTIFY_FLAG" ]; }
# note-paper style below the strip: off | lines | grid | dots (legacy LINES_FLAG = lines)
get_notestyle() {
    local v=""; [ -r "$NOTESTYLE_FILE" ] && v=$(trim < "$NOTESTYLE_FILE")
    case "$v" in lines|grid|dots|off) echo "$v"; return;; esac
    [ -e "$LINES_FLAG" ] && { echo lines; return; }
    echo off
}
get_notespacing() {   # rule spacing in mm (default 8)
    local v=""; [ -r "$NOTESPACING_FILE" ] && v=$(trim < "$NOTESPACING_FILE")
    case "$v" in ''|*[!0-9]*) echo 8 ;; *) echo "$v" ;; esac
}
lines_on()  { [ "$(get_notestyle)" != off ]; }

# post a notification via the applet (env-var payload, dsort's playbook). Silent
# if muted or the applet isn't installed yet.
notify() {
    notify_on || return 0
    [ -x "$NOTIFIER" ] || return 0
    PKA_TITLE="$1" PKA_BODY="$2" "$NOTIFIER" >/dev/null 2>>"$LOG" || true
}

# resolve a python3 (launchd has a minimal PATH)
PYTHON=""
for c in python3 /usr/bin/python3 "$HOME/.local/bin/python3" /opt/homebrew/bin/python3; do
    if command -v "$c" >/dev/null 2>&1; then PYTHON="$c"; break; fi
done

# --- intensity decision ----------------------------------------------------
# Gap since last print, expressed in whole days (for messages).
days_since() {
    local last now; last=$(get_last); now=$(date +%s)
    [ "$last" -le 0 ] && { echo -1; return; }      # -1 = never printed
    echo $(( (now - last) / 86400 ))
}
# Auto tier from the gap relative to the schedule interval:
#   <= 1.5x interval  -> light   (on schedule)
#   <= 3x interval    -> medium  (missed ~1-2 runs)
#   >  3x interval    -> heavy   (long neglect)
decide_tier() {
    local last now elapsed iv; last=$(get_last); iv=$(get_interval); now=$(date +%s)
    [ "$last" -le 0 ] && { echo light; return; }   # first ever run
    elapsed=$(( now - last ))
    if   [ "$elapsed" -le $(( iv * 3 / 2 )) ]; then echo light
    elif [ "$elapsed" -le $(( iv * 3 ))     ]; then echo medium
    else echo heavy; fi
}

# ink levels for a printer, as a compact "Color 50%  ·  Black 40%" string (only
# real ink cartridges; skips the waste/maintenance tank). Empty if the printer
# doesn't report marker levels via CUPS. Reads localhost CUPS (cached), so it's
# fast and works even if the printer is momentarily offline.
ink_report() {
    local p="$1" tf out names levels types sock=/private/var/run/cupsd
    command -v ipptool >/dev/null 2>&1 || { echo ""; return 0; }
    [ -n "$p" ] || { echo ""; return 0; }
    [ -S "$sock" ] || sock=/var/run/cupsd
    tf=$(mktemp)
    cat > "$tf" <<'IPPEOF'
{
  OPERATION Get-Printer-Attributes
  GROUP operation-attributes-tag
  ATTR charset attributes-charset utf-8
  ATTR naturalLanguage attributes-natural-language en
  ATTR uri printer-uri $uri
  ATTR keyword requested-attributes marker-names,marker-levels,marker-types
}
IPPEOF
    # query the local CUPS via its domain socket (always reachable; cupsd may not
    # be listening on TCP localhost:631 when idle). Falls back gracefully to empty.
    out=$(CUPS_SERVER="$sock" ipptool -tv "ipp://localhost/printers/$p" "$tf" 2>/dev/null || true)
    rm -f "$tf"
    names=$(printf '%s\n' "$out"  | sed -n 's/.*marker-names[^=]*= //p'  | head -1)
    levels=$(printf '%s\n' "$out" | sed -n 's/.*marker-levels[^=]*= //p' | head -1)
    types=$(printf '%s\n' "$out"  | sed -n 's/.*marker-types[^=]*= //p'  | head -1)
    [ -z "$levels" ] && { echo ""; return 0; }
    awk -v n="$names" -v l="$levels" -v t="$types" 'BEGIN{
        ni=split(n,N,","); split(l,L,","); split(t,T,",");
        o="";
        for(i=1;i<=ni;i++) if(T[i] ~ /ink-cartridge/) o=o (o==""?"":"  -  ") N[i] " " L[i] "%";
        print o
    }'
}

# --- build the keep-alive PDF for a given tier -----------------------------
# build_pdf <tier> <subtitle> [ink]  -> echoes the temp PDF path
# The test strip (all ink channels) runs across the top of the page so the area
# below is free; with ruled-paper mode on, that area becomes lined note paper.
build_pdf() {
    local tier="$1" subtitle="$2" ink="${3:-}" pdf stub style sp_mm sp_pts
    stub="$(mktemp -t pkeepalive)"; pdf="${stub}.pdf"; mv "$stub" "$pdf"
    [ -z "$PYTHON" ] && { rm -f "$pdf"; echo "ERROR: python3 not found" >&2; return 1; }
    style=$(get_notestyle); sp_mm=$(get_notespacing)
    sp_pts=$(awk "BEGIN{printf \"%.2f\", $sp_mm * 72 / 25.4}")   # mm -> points
    "$PYTHON" - "$pdf" "$tier" "$style" "$sp_pts" "$subtitle" "$ink" <<'PY'
import sys
out  = sys.argv[1]
tier = sys.argv[2] if len(sys.argv) > 2 else "light"
style = sys.argv[3] if len(sys.argv) > 3 else "off"
try: spacing = float(sys.argv[4])
except (IndexError, ValueError): spacing = 22.7
subtitle = sys.argv[5] if len(sys.argv) > 5 else ""
ink = sys.argv[6] if len(sys.argv) > 6 else ""
if tier not in ("light", "medium", "heavy"): tier = "light"
if style not in ("lines", "grid", "dots"): style = "off"
if spacing < 8: spacing = 8        # sane floor so we never emit thousands of rules

W, H = 595, 842                 # A4 points
ML, MR = 54, 54                 # left/right margins
CW = W - ML - MR                # content width
RIGHT = W - MR

# the four ink channels, top→bottom, as a clean CMYK strip
inks = [(1, 0, 0, 0, "C"), (0, 1, 0, 0, "M"), (0, 0, 1, 0, "Y"), (0, 0, 0, 1, "K")]

# per-tier strip geometry: bar height + gap. Heavier = more ink (deeper flush).
BH, GAP = {"light": (8, 6), "medium": (14, 6), "heavy": (24, 7)}[tier]

# the page content is encoded latin-1, so fold common smart punctuation to ASCII
# (macOS computer names default to a curly apostrophe) and replace anything else
# that can't be encoded, so a stray Unicode char never crashes the generator.
def esc(s):
    for a, b in (("’", "'"), ("‘", "'"), ("“", '"'), ("”", '"'),
                 ("–", "-"), ("—", "-"), ("…", "...")):
        s = s.replace(a, b)
    s = s.encode("latin-1", "replace").decode("latin-1")
    return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
def text(x, y, size, k, s, font="F1", tc=0.0):
    return (f"BT /{font} {size} Tf 0 0 0 {k} k {tc} Tc "
            f"{x:.1f} {y:.1f} Td ({esc(s)}) Tj 0 Tc ET")
def rtext(xr, y, size, k, s, font="F1"):   # right-aligned at xr (approx Helvetica width)
    return text(xr - len(s) * size * 0.5, y, size, k, s, font)
def rect(x, y, w, h, c, m, ye, k):
    return f"{c} {m} {ye} {k} k {x:.1f} {y:.1f} {w:.1f} {h:.1f} re f"
def line(x1, y1, x2, y2, w, c, m, ye, k):
    return f"{c} {m} {ye} {k} K {w} w {x1:.1f} {y1:.1f} m {x2:.1f} {y2:.1f} l S"

ops = []
# header: title (bold, tracked) + subtitle (muted)
ops.append(text(ML, 802, 13, 0.82, "PRINTER DON'T DIE PLEASE!!", font="F2", tc=1.6))
sub = subtitle.strip()
sub = (sub + "  -  " if sub else "") + f"{tier} flush"
ops.append(text(ML, 788, 8, 0.45, sub))
# ink report, top-right above the strip, on the title's line (only if the
# printer reported levels). "Ink" label in bold, the levels in muted grey.
if ink:
    ops.append(rtext(RIGHT, 802, 8, 0.4, ink))
    ops.append(rtext(RIGHT - len(ink) * 8 * 0.5 - 6, 802, 7, 0.5, "INK", font="F2"))

# colour strip across the short side, just below the header
y = 768
strip_bottom = y
for c, m, ye, k, label in inks:
    ops.append(rect(ML, y - BH, CW, BH, c, m, ye, k))
    ops.append(text(RIGHT + 6, y - BH + (BH - 6) / 2, 6.5, 0.45, label))  # tiny label in the right margin
    strip_bottom = y - BH
    y = strip_bottom - GAP

# hairline rule separating the test strip from the space below
rule_y = strip_bottom - 16
ops.append(line(ML, rule_y, RIGHT, rule_y, 0.6, 0, 0, 0, 0.25))

# note paper below (optional): lines / grid / dots, edge to edge, down to the
# bottom of the page (the printer's own unprintable margin trims the extremes).
if style != "off":
    BM = 16                       # extend nearly to the bottom edge
    notes_top = rule_y - 30
    GK = 0.14                     # rule/dot grey (CMYK K)
    ops.append(text(ML, notes_top + 12, 7, 0.32, "Notes", font="F2"))
    # a place to write the date, top-right of the note area
    ops.append(text(RIGHT - 100, notes_top + 12, 7, 0.32, "Date", font="F2"))
    ops.append(line(RIGHT - 78, notes_top + 10, RIGHT, notes_top + 10, 0.5, 0, 0, 0, 0.30))
    # horizontal rules (lines + grid)
    if style in ("lines", "grid"):
        yy = notes_top
        while yy > BM:
            ops.append(line(0, yy, W, yy, 0.5, 0, 0, 0, GK))
            yy -= spacing
    # vertical rules (grid only), centred so the columns sit symmetrically
    if style == "grid":
        n = int(W / spacing)
        x0 = (W - n * spacing) / 2.0
        xx = x0
        while xx < W:
            if xx > 0:
                ops.append(line(xx, notes_top, xx, BM, 0.5, 0, 0, 0, GK))
            xx += spacing
    # dot grid: a small dot at each intersection
    if style == "dots":
        n = int(W / spacing)
        x0 = (W - n * spacing) / 2.0
        yy = notes_top
        while yy > BM:
            xx = x0
            while xx < W:
                if xx > 0:
                    ops.append(rect(xx - 0.6, yy - 0.6, 1.2, 1.2, 0, 0, 0, 0.45))
                xx += spacing
            yy -= spacing

# subtle footer to identify the page — only on a blank page, so it stays out of
# the way when the sheet is being used as note paper
if style == "off":
    ops.append(text(ML, 40, 6.5, 0.35, "Printer Don't Die Please!!  ·  inkjet nozzle maintenance"))

content = ("\n".join(ops) + "\n").encode("latin-1")

objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {W} {H}] "
     f"/Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> /Contents 4 0 R >>").encode("latin-1"),
    b"<< /Length %d >>\nstream\n" % len(content) + content + b"endstream",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
]
buf = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"
offs = []
for i, body in enumerate(objs, 1):
    offs.append(len(buf)); buf += b"%d 0 obj\n" % i + body + b"\nendobj\n"
xref = len(buf)
buf += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
for o in offs: buf += b"%010d 00000 n \n" % o
buf += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
open(out, "wb").write(buf)
PY
    echo "$pdf"
}

# --- main ------------------------------------------------------------------
mkdir -p "$SCRIPTS" "$(dirname "$LOG")"
FORCE_TIER=""; DRY=0
case "${1:-}" in
    --dry)  DRY=1; FORCE_TIER="${2:-}";;
    --tier) FORCE_TIER="${2:-}";;
    "")     ;;
    *)      echo "usage: $(basename "$0") [--tier light|medium|heavy] [--dry [tier]]" >&2; exit 2;;
esac

TIER="${FORCE_TIER:-$(decide_tier)}"
case "$TIER" in light|medium|heavy) ;; *) TIER=$(decide_tier);; esac

DAYS=$(days_since)
TS="$(date '+%Y-%m-%d %H:%M:%S')"
HOST="$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || hostname)"

# read the selected printers into an array (bash 3.2: no mapfile)
PRINTERS=()
while IFS= read -r _p; do [ -n "$_p" ] && PRINTERS+=("$_p"); done < <(get_printers)
PCOUNT=${#PRINTERS[@]}

# human-friendly "since last run" phrase + heads-up body
if [ "$DAYS" -lt 0 ]; then since="first run"; else since="last run ${DAYS}d ago"; fi
on=""; [ "$PCOUNT" -gt 1 ] && on=" on $PCOUNT printers"
case "$TIER" in
    light)  body="Nozzle keep-alive printing now${on} - routine ($since).";;
    medium) body="Catching up${on} - ${since}; printing a medium nozzle flush.";;
    heavy)  body="It's been a while${on} - ${since}; printing an intensive nozzle flush (2 pages each).";;
esac

# --- dry run: build + open, no printing, no state change -------------------
if [ "$DRY" = 1 ]; then
    PDF=$(build_pdf "$TIER" "$TS  ·  $since  ·  $HOST  ·  dry run" "$(ink_report "${PRINTERS[0]:-}")")
    echo "[$TS] dry run ($TIER) - $PDF" | tee -a "$LOG"
    open "$PDF" 2>/dev/null || true
    exit 0
fi

if [ "$PCOUNT" -eq 0 ]; then
    echo "[$TS] ERROR: no printer selected and no system default" | tee -a "$LOG" >&2
    notify "Printer Don't Die Please!! — failed" "No printer configured."
    exit 1
fi

# --- heads-up FIRST, then a short lead so it's actually a heads-up ----------
notify "Printer Don't Die Please!!" "$body"
LEAD=$(get_lead); [ "$LEAD" -gt 0 ] && sleep "$LEAD"

COPIES=1; [ "$TIER" = heavy ] && COPIES=2
NOW=$(date +%s); OK=0; FAILED=""

# print to every selected printer; one history row per printer
for P in "${PRINTERS[@]}"; do
    PDF=$(build_pdf "$TIER" "$TS  ·  $since  ·  $HOST  ·  $P" "$(ink_report "$P")")
    if lp -d "$P" -n "$COPIES" -o media=A4 "$PDF" >/dev/null 2>>"$LOG"; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$NOW" "$TS" "$TIER" "$DAYS" "$COPIES" "$P" >> "$HISTORY_FILE"
        OK=$((OK+1))
    else
        echo "[$TS] FAILED to print to $P (see log)" | tee -a "$LOG" >&2
        FAILED="$FAILED $P"
    fi
    rm -f "$PDF"
done

[ "$OK" -gt 0 ] && echo "$NOW" > "$LASTPRINT_FILE"
if [ "$DAYS" -lt 0 ]; then gapmsg="first run"; else gapmsg="gap was ${DAYS}d"; fi
echo "[$TS] printed $TIER keep-alive to $OK/$PCOUNT printer(s); $gapmsg" | tee -a "$LOG"

if [ -n "$FAILED" ]; then
    notify "Printer Don't Die Please!! — failed" "Could not print to:$FAILED"
    [ "$OK" -eq 0 ] && exit 1
fi
