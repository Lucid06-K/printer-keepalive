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
#   heavy   tall solid bars (one dense page) — a deep flush
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
MARGIN_FLAG="$SCRIPTS/printer_keepalive.margin"       # presence = workbook left margin line ON (default off)
MARGINMM_FILE="$SCRIPTS/printer_keepalive.marginmm"   # margin distance from the left edge, mm
LAYOUT_FILE="$SCRIPTS/printer_keepalive.layout"       # page layout: new (default) | classic
ARTFLAG="$SCRIPTS/printer_keepalive.art"              # presence = rotating ASCII art ON (default off)
ARTINDEX_FILE="$SCRIPTS/.printer_keepalive.artindex"  # which art to show next
ART_COUNT=15                                          # must match the ART list in the generator
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
get_layout() {   # page layout: classic (original full-width) | new (redesign, default)
    local v=""; [ -r "$LAYOUT_FILE" ] && v=$(trim < "$LAYOUT_FILE")
    case "$v" in classic) echo classic;; *) echo new;; esac
}
margin_on() { [ -e "$MARGIN_FLAG" ]; }    # school-workbook left margin line
get_marginmm() {   # distance of the margin line from the left edge, mm (default 25)
    local v=""; [ -r "$MARGINMM_FILE" ] && v=$(trim < "$MARGINMM_FILE")
    case "$v" in ''|*[!0-9]*) echo 25 ;; *) echo "$v" ;; esac
}
# ASCII-art mode: off | rotate | <1-15> (a pinned piece). ARTFLAG holds the value;
# an empty/legacy file means rotate (old on=rotate behaviour).
art_mode() {
    [ -e "$ARTFLAG" ] || { echo off; return; }
    local v; v=$(trim < "$ARTFLAG")
    case "$v" in ''|rotate) echo rotate;; [1-9]|1[0-5]) echo "$v";; *) echo rotate;; esac
}
get_artindex() { local v=""; [ -r "$ARTINDEX_FILE" ] && v=$(trim < "$ARTINDEX_FILE"); case "$v" in ''|*[!0-9]*) echo 0;; *) echo "$v";; esac; }
set_artindex() { printf '%s\n' "$1" > "$ARTINDEX_FILE" 2>/dev/null || true; }

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

# ink levels for a printer as a "C M Y K" string of percentages ("-" = unknown).
# CUPS only reports marker levels while the printer is awake/recently contacted,
# so we cache the last good reading per printer and fall back to it when a cold
# query comes back empty (a scheduled run often starts with the printer asleep).
ink_report() {
    local p="$1" tf out names levels types mapped cf sock=/private/var/run/cupsd
    command -v ipptool >/dev/null 2>&1 || { echo ""; return 0; }
    [ -n "$p" ] || { echo ""; return 0; }
    [ -S "$sock" ] || sock=/var/run/cupsd
    cf="$SCRIPTS/.printer_keepalive.ink.$(printf '%s' "$p" | tr -c 'A-Za-z0-9_-' '_')"
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
    if [ -z "$levels" ]; then            # cold query — fall back to last cached reading
        [ -r "$cf" ] && cat "$cf" || echo ""
        return 0
    fi
    # classify cartridges. Output is one of:
    #   "combined <colour%> <k%>"     one tri-colour cartridge + black
    #   "separate <c> <m> <y> <k>"    individual cartridges ("-" = unknown)
    mapped=$(awk -v n="$names" -v l="$levels" -v t="$types" 'BEGIN{
        ni=split(n,N,","); split(l,L,","); split(t,T,",");
        color=""; c=""; m=""; y=""; k="";
        for(i=1;i<=ni;i++){
            if(T[i] !~ /ink-cartridge/) continue;
            nm=tolower(N[i]); lv=L[i];
            if(nm ~ /black|pgbk|^bk$|^k$/)      k=lv;
            else if(nm ~ /cyan|^c$/)            c=lv;
            else if(nm ~ /magenta|^m$/)         m=lv;
            else if(nm ~ /yellow|^y$/)          y=lv;
            else                                color=lv;   # combined "Color"/tri-colour
        }
        sep = (c != "" || m != "" || y != "");
        if (color != "" && !sep) {                       # one tri-colour cartridge
            printf "combined %s %s", color, (k==""?"-":k);
        } else {
            if(c=="") c=color; if(m=="") m=color; if(y=="") y=color;
            printf "separate %s %s %s %s", (c==""?"-":c),(m==""?"-":m),(y==""?"-":y),(k==""?"-":k);
        }
    }')
    printf '%s\n' "$mapped" > "$cf" 2>/dev/null || true   # cache the fresh reading
    printf '%s\n' "$mapped"
}

# --- build the keep-alive PDF for a given tier -----------------------------
# build_pdf <tier> <subtitle> [ink] [art_idx] [mode]  -> echoes the temp PDF path
# The test strip (all ink channels) runs across the top of the page so the area
# below is free; with ruled-paper mode on, that area becomes lined note paper.
# art_idx >= 0 draws that rotating ASCII art top-right; mode "sheet" renders a
# contact sheet of all the art instead of a keep-alive page.
build_pdf() {
    local tier="$1" subtitle="$2" ink="${3:-}" art_idx="${4:--1}" mode="${5:-page}" pdf stub style sp_mm sp_pts
    stub="$(mktemp -t pkeepalive)"; pdf="${stub}.pdf"; mv "$stub" "$pdf"
    [ -z "$PYTHON" ] && { rm -f "$pdf"; echo "ERROR: python3 not found" >&2; return 1; }
    local mg mg_pts LAYOUT
    LAYOUT=$(get_layout)
    style=$(get_notestyle); sp_mm=$(get_notespacing)
    sp_pts=$(awk "BEGIN{printf \"%.2f\", $sp_mm * 72 / 25.4}")   # mm -> points
    mg=$(margin_on && echo 1 || echo 0)
    mg_pts=$(awk "BEGIN{printf \"%.2f\", $(get_marginmm) * 72 / 25.4}")
    "$PYTHON" - "$pdf" "$tier" "$style" "$sp_pts" "$subtitle" "$ink" "$art_idx" "$mode" "$mg" "$mg_pts" "$LAYOUT" <<'PY'
import sys
out  = sys.argv[1]
tier = sys.argv[2] if len(sys.argv) > 2 else "light"
style = sys.argv[3] if len(sys.argv) > 3 else "off"
try: spacing = float(sys.argv[4])
except (IndexError, ValueError): spacing = 22.7
subtitle = sys.argv[5] if len(sys.argv) > 5 else ""
ink = sys.argv[6] if len(sys.argv) > 6 else ""
try: art_idx = int(sys.argv[7])
except (IndexError, ValueError): art_idx = -1
mode = sys.argv[8] if len(sys.argv) > 8 else "page"
margin_on = (len(sys.argv) > 9 and sys.argv[9] == "1")
try: margin_x = float(sys.argv[10])
except (IndexError, ValueError): margin_x = 71.0
layout = sys.argv[11] if len(sys.argv) > 11 else "new"
if tier not in ("light", "medium", "heavy"): tier = "light"
if style not in ("lines", "grid", "dots"): style = "off"
if layout != "classic": layout = "new"
if spacing < 8: spacing = 8        # sane floor so we never emit thousands of rules

W, H = 595, 842                 # A4 points
ML, MR = 54, 54                 # left/right margins
CW = W - ML - MR                # content width
RIGHT = W - MR

# the four ink channels, top→bottom, as a clean CMYK strip
inks = [(1, 0, 0, 0, "C"), (0, 1, 0, 0, "M"), (0, 0, 1, 0, "Y"), (0, 0, 0, 1, "K")]

# per-tier strip geometry: bar height + gap. Heavier = more ink (deeper flush).
# The redesign's strip is half-width, so heavy uses taller bars to stay ink-heavy
# despite the narrower column; the classic full-width strip keeps the original 40.
if layout == "classic":
    BH, GAP = {"light": (8, 6), "medium": (14, 6), "heavy": (40, 8)}[tier]
else:
    BH, GAP = {"light": (8, 6), "medium": (14, 6), "heavy": (44, 8)}[tier]

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
def ctext(xc, y, size, k, s, font="F1"):   # centred on xc (approx Helvetica width)
    return text(xc - len(s) * size * 0.25, y, size, k, s, font)
def rect(x, y, w, h, c, m, ye, k):
    return f"{c} {m} {ye} {k} k {x:.1f} {y:.1f} {w:.1f} {h:.1f} re f"
def line(x1, y1, x2, y2, w, c, m, ye, k):
    return f"{c} {m} {ye} {k} K {w} w {x1:.1f} {y1:.1f} m {x2:.1f} {y2:.1f} l S"
def mono(x, y, size, c, m, ye, k, s):    # monospace line in Courier (F3), CMYK fill
    return (f"BT /F3 {size} Tf {c} {m} {ye} {k} k "
            f"{x:.1f} {y:.1f} Td ({esc(s)}) Tj ET")
def ribbon(xL, xT, xR, uy, bar_top, bar_bot, t, c, m, ye, k):
    # a filled CMYK ribbon: full bar thickness at the strip's left edge (xR),
    # curving + tapering to a thin underline of thickness t between xL and xT.
    # Top and bottom edges are cubic Béziers with horizontal tangents (a smooth S).
    half = (xR - xT) / 2.0
    th = t / 2.0
    return (f"{c} {m} {ye} {k} k "
            f"{xL:.1f} {uy + th:.1f} m "
            f"{xT:.1f} {uy + th:.1f} l "
            f"{xT + half:.1f} {uy + th:.1f} {xR - half:.1f} {bar_top:.1f} {xR:.1f} {bar_top:.1f} c "
            f"{xR:.1f} {bar_bot:.1f} l "
            f"{xR - half:.1f} {bar_bot:.1f} {xT + half:.1f} {uy - th:.1f} {xT:.1f} {uy - th:.1f} c "
            f"{xL:.1f} {uy - th:.1f} l f")

# 15 tiny ASCII-art pieces shown top-right and rotated each print. Each LINE is
# coloured C/M/Y/K in turn. Kept narrow so they tuck into the corner.
CMYK = [(1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0), (0, 0, 0, 1)]
ART = [
    [" .", "/o\\", "\\_/"],                                  # 1 ink drop
    [" ____", "|** |", "|____|", " |__| "],                 # 2 printer
    [" /\\_/\\", "( o.o )", " > ^ < "],                      # 3 cat (ears nudged right)
    ["(\\_/)", "(o.o)", "(\")(\")"],                          # 4 bunny
    ["|\\_/|", "(o.o)", "(u u)"],                            # 5 dog
    [".---.", "|o o|", "| ` |", "'---'"],                    # 6 smiley
    ["(o)(o)", "( o.o )", " ( v ) "],                        # 7 bear
    ["( ~ )", ".---.", "|   |D", "'---'"],                   # 8 coffee
    ["=(o.o)=", "  (\")"],                                    # 9 mouse
    ["  /\\", " |oo|", " |==|", " /||\\", "  ^^"],            # 10 rocket
    ["  o", " o", ">(((^>"],                                 # 11 fish
    ["{o,o}", "|)_)", " \" \" "],                             # 12 owl
    [".--.", "(o o)", "( || )", " ^^ "],                     # 13 penguin
    ["  __", "<(o )", "(___/"],                              # 14 duck
    ["+  .", " .* ", ".  +", " *. "],                         # 15 sparkles
]

def art_block(lines, x_left, y_top, size, lead):
    for j, ln in enumerate(lines):
        c, m, ye, k = CMYK[j % 4]
        ops.append(mono(x_left, y_top - j * lead, size, c, m, ye, k, ln))

ops = []
ink_tok = ink.split() if ink else []
ink_mode = ink_tok[0] if ink_tok else ""
REPO = "github.com/Lucid06-K/printer-keepalive"
note_split_x = None                # x where left/right note regions differ (heavy redesign)
notes_left_top = None              # y where the extra left-fill note region starts

# ===== top band: strip + ink-gauge divider (layout-dependent) =====
if layout == "classic":
    # original: a full-width strip with the title + info stacked above it
    ops.append(text(ML, 802, 13, 0.82, "PRINTER DON'T DIE PLEASE!!", font="F2", tc=1.6))
    sub = subtitle.strip()
    sub = (sub + "  -  " if sub else "") + f"{tier} flush"
    ops.append(text(ML, 788, 8, 0.45, sub))
    if 0 <= art_idx < len(ART):
        a = ART[art_idx]
        aw = max(len(l) for l in a) * 6.5 * 0.6
        art_block(a, RIGHT - aw, 806, 6.5, 7.5)   # right-justified to the strip end
    y = 768
    strip_bottom = y
    for c, m, ye, k, label in inks:
        ops.append(rect(ML, y - BH, CW, BH, c, m, ye, k))
        ops.append(text(RIGHT + 6, y - BH + (BH - 6) / 2, 6.5, 0.45, label))
        strip_bottom = y - BH
        y = strip_bottom - GAP
    sx, qw = ML, CW / 4.0
else:
    # redesign: half-width strip on the right (frees the left half for the header)
    strip_left = W / 2.0
    strip_w = RIGHT - strip_left
    y = 800
    strip_bottom = y
    bar_span = {}                  # label -> (top y, bottom y), used by the ribbons
    for c, m, ye, k, label in inks:
        ops.append(rect(strip_left, y - BH, strip_w, BH, c, m, ye, k))
        ops.append(text(RIGHT + 6, y - BH + (BH - 6) / 2, 6.5, 0.45, label))
        bar_span[label] = (y, y - BH)
        strip_bottom = y - BH
        y = strip_bottom - GAP
    sx, qw = strip_left, strip_w / 4.0

# divider: one rule split into four C/M/Y/K quarters, doubling as the ink gauge.
# The level(s) print above it — a single "Colour" reading spanning C/M/Y for a
# combined tri-colour cartridge, else one per channel. sx/qw are set per layout.
rule_y = strip_bottom - 16
for i, (c, m, ye, k) in enumerate([(1,0,0,0), (0,1,0,0), (0,0,1,0), (0,0,0,1)]):
    ops.append(line(sx + i*qw, rule_y, sx + (i+1)*qw, rule_y, 1.5, c, m, ye, k))

def gauge(xc, lvl, lbl=""):
    if lvl in ("", "-"): return
    ops.append(ctext(xc, rule_y + 4, 7, 0.6, (lbl + " " if lbl else "") + lvl + "%"))

if ink_mode == "combined":
    gauge(sx + 1.5 * qw, ink_tok[1] if len(ink_tok) > 1 else "-", "Colour")
    gauge(sx + 3.5 * qw, ink_tok[2] if len(ink_tok) > 2 else "-", "Black")
    by = rule_y - 5                # a thin brace: the C/M/Y quarters share one cartridge
    ops.append(line(sx + 4, by, sx + 3 * qw - 4, by, 0.5, 0, 0, 0, 0.30))
    ops.append(line(sx + 4, by, sx + 4, rule_y - 2, 0.5, 0, 0, 0, 0.30))
    ops.append(line(sx + 3 * qw - 4, by, sx + 3 * qw - 4, rule_y - 2, 0.5, 0, 0, 0, 0.30))
elif ink_mode == "separate":
    for i, v in enumerate(ink_tok[1:5]):
        gauge(sx + (i + 0.5) * qw, v)

if ink_mode in ("combined", "separate"):
    ops.append(text(RIGHT + 6, rule_y - 2, 6, 0.45, "INK LEVELS"))

# ===== redesign header: title/info/repo on the left, CMYK ribbons to the strip =====
if layout != "classic":
    # Four stacked lines, each with a CMYK ribbon that extrudes from its bar at full
    # thickness and tapers, curving, to a thin underline: title=K, date=Y, computer=M,
    # repo=C. The reversed colour map makes the ribbons criss-cross back to the strip.
    sp = [p.strip() for p in subtitle.split("·")]
    def part(i): return sp[i] if i < len(sp) and sp[i] else ""
    line1 = "  ·  ".join([s for s in (part(0), f"{tier} flush", part(1)) if s])  # date · flush · last-run
    host_s = part(2)                                                            # computer name
    TX = ML + 32                   # info text starts to the right of the art column
    def fit(s, size, x0):          # truncate so a line never runs into the strip
        n = int((strip_left - 6 - x0) / (size * 0.5))
        return s if len(s) <= n else s[:max(0, n - 1)]
    # lift the whole header group so the title's K underline TOP edge lines up with
    # the top of the C (cyan) bar. Base baselines 794/778/764/750, underlines -2pt.
    HY = bar_span["C"][0] - 792.65
    ops.append(text(ML, 794 + HY, 12, 0.82, "PRINTER DON'T DIE PLEASE!!", font="F2", tc=1.2))
    ops.append(text(TX, 778 + HY, 7, 0.45, fit(line1, 7, TX)))
    ops.append(text(TX, 764 + HY, 7.5, 0.45, fit(host_s, 7.5, TX)))
    ops.append(text(TX, 750 + HY, 6.5, 0.50, fit(REPO, 6.5, TX)))
    xT = strip_left - 34           # where the thin underline ends and the taper begins
    for uy, xL, lab in [(792 + HY, ML, "K"), (776 + HY, TX, "Y"), (762 + HY, TX, "M"), (748 + HY, TX, "C")]:
        bt, bb = bar_span[lab]
        cc = {"C": (1,0,0,0), "M": (0,1,0,0), "Y": (0,0,1,0), "K": (0,0,0,1)}[lab]
        ops.append(ribbon(xL, xT, strip_left, uy, bt, bb, 1.3, cc[0], cc[1], cc[2], cc[3]))
    # rotating art, tucked into the empty inner-left margin beside the info lines
    if 0 <= art_idx < len(ART):
        art_block(ART[art_idx], ML, 776 + HY, 5.5, 6.5)
    # heavy's tall strip leaves the left side empty — fill it with note rules too
    if tier == "heavy":
        note_split_x = strip_left
        notes_left_top = 724

# note paper below (optional): lines / grid / dots, edge to edge, down to the
# bottom of the page (the printer's own unprintable margin trims the extremes).
if style != "off":
    BM = 16                       # extend nearly to the bottom edge
    notes_top = rule_y - 30
    GK = 0.14                     # rule/dot grey (CMYK K)
    # In the heavy redesign the tall strip leaves the left half empty, so note rules
    # there start higher (lnt) and span only the left until they clear the strip
    # (splitx); below the strip every rule is full width, as in every other case.
    lnt = notes_left_top if notes_left_top else notes_top
    splitx = note_split_x if note_split_x else W
    ops.append(text(ML, lnt + 12, 7, 0.32, "Notes", font="F2"))
    # a place to write the date, top-right of the (full-width) note area
    ops.append(text(RIGHT - 100, notes_top + 12, 7, 0.32, "Date", font="F2"))
    ops.append(line(RIGHT - 78, notes_top + 10, RIGHT, notes_top + 10, 0.5, 0, 0, 0, 0.30))
    # horizontal rules (lines + grid)
    if style in ("lines", "grid"):
        yy = lnt
        while yy > BM:
            xend = W if yy <= notes_top else splitx     # beside the strip → left half only
            ops.append(line(0, yy, xend, yy, 0.5, 0, 0, 0, GK))
            yy -= spacing
    # vertical rules (grid only), centred so the columns sit symmetrically
    if style == "grid":
        n = int(W / spacing)
        x0 = (W - n * spacing) / 2.0
        xx = x0
        while xx < W:
            if xx > 0:
                ops.append(line(xx, (lnt if xx < splitx else notes_top), xx, BM, 0.5, 0, 0, 0, GK))
            xx += spacing
    # dot grid: a small dot at each intersection
    if style == "dots":
        n = int(W / spacing)
        x0 = (W - n * spacing) / 2.0
        yy = lnt
        while yy > BM:
            xx = x0
            while xx < W:
                if xx > 0 and (yy <= notes_top or xx < splitx):
                    ops.append(rect(xx - 0.6, yy - 0.6, 1.2, 1.2, 0, 0, 0, 0.45))
                xx += spacing
            yy -= spacing
    # optional school-workbook left margin line, a set distance from the edge
    if margin_on and 0 < margin_x < W:
        ops.append(line(margin_x, lnt + 6, margin_x, BM, 0.8, 0, 0.6, 0.5, 0))

# subtle footer to identify the page — only on a blank page, so it stays out of
# the way when the sheet is being used as note paper
if style == "off":
    ops.append(text(ML, 40, 6.5, 0.35, "Printer Don't Die Please!!  ·  inkjet nozzle maintenance"))

# contact sheet: discard the keep-alive page and lay out all the art in a grid
if mode == "sheet":
    ops = []
    ops.append(text(ML, 800, 14, 0.82, "PRINTER DON'T DIE PLEASE!!", font="F2", tc=1.4))
    ops.append(text(ML, 784, 8.5, 0.45, "ASCII art gallery - one of these rotates onto the top-right corner of each print"))
    cols, rows = 3, 5
    cellw = CW / cols
    top, bot = 760, 60
    rowh = (top - bot) / rows
    for idx, a in enumerate(ART):
        col, row = idx % cols, idx // cols
        cx = ML + col * cellw
        cy = top - row * rowh
        ops.append(text(cx, cy, 8, 0.55, "#%d" % (idx + 1), font="F2"))
        sz, lead = 9, 10.5
        aw = max(len(l) for l in a) * sz * 0.6
        ah = len(a) * lead
        art_block(a, cx + (cellw - 24 - aw) / 2 + 6, cy - 18, sz, lead)

content = ("\n".join(ops) + "\n").encode("latin-1")

objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {W} {H}] "
     f"/Resources << /Font << /F1 5 0 R /F2 6 0 R /F3 7 0 R >> >> /Contents 4 0 R >>").encode("latin-1"),
    b"<< /Length %d >>\nstream\n" % len(content) + content + b"endstream",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>",
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
FORCE_TIER=""; DRY=0; ARTSHEET=0; BUILD=0
case "${1:-}" in
    --dry)       DRY=1; FORCE_TIER="${2:-}";;
    --build)     BUILD=1; FORCE_TIER="${2:-}";;   # build the page PDF, print its path, no open/print
    --tier)      FORCE_TIER="${2:-}";;
    --art-sheet) ARTSHEET=1;;
    "")          ;;
    *)           echo "usage: $(basename "$0") [--tier light|medium|heavy] [--dry [tier]] [--build] [--art-sheet]" >&2; exit 2;;
esac

# --- ASCII-art contact sheet: print all the art on one page, then exit -------
if [ "$ARTSHEET" = 1 ]; then
    PRINTERS=()
    while IFS= read -r _p; do [ -n "$_p" ] && PRINTERS+=("$_p"); done < <(get_printers)
    [ "${#PRINTERS[@]}" -eq 0 ] && { echo "no printer configured" >&2; exit 1; }
    TS="$(date '+%Y-%m-%d %H:%M:%S')"
    PDF=$(build_pdf "light" "" "" -1 sheet)
    for P in "${PRINTERS[@]}"; do lp -d "$P" -o media=A4 "$PDF" >/dev/null 2>>"$LOG" || true; done
    echo "[$TS] printed ASCII-art contact sheet to ${#PRINTERS[@]} printer(s)" | tee -a "$LOG"
    rm -f "$PDF"; exit 0
fi

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
    heavy)  body="It's been a while${on} - ${since}; printing an intensive nozzle flush.";;
esac

# --- dry run: build + open, no printing, no state change -------------------
# which ASCII art to show: off (-1), a pinned piece, or the next in the rotation.
# AROT=1 only for rotate mode (advance + persist the counter after printing).
AMODE=$(art_mode); AROT=0
case "$AMODE" in
    off)    ADRY=-1;;
    rotate) ADRY=$(( $(get_artindex) % ART_COUNT )); AROT=1;;
    *)      ADRY=$(( AMODE - 1 ));;
esac
if [ "$DRY" = 1 ]; then
    PDF=$(build_pdf "$TIER" "$TS  ·  $since  ·  $HOST  ·  dry run" "$(ink_report "${PRINTERS[0]:-}")" "$ADRY" page)
    echo "[$TS] dry run ($TIER) - $PDF" | tee -a "$LOG"
    open "$PDF" 2>/dev/null || true
    exit 0
fi

# --- build only: emit the page PDF path for a previewer/renderer, then exit --
if [ "$BUILD" = 1 ]; then
    build_pdf "$TIER" "$TS  ·  $since  ·  $HOST  ·  preview" "$(ink_report "${PRINTERS[0]:-}")" "$ADRY" page
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

COPIES=1   # always one page; heavy gets a denser single page, not a second sheet
NOW=$(date +%s); OK=0; FAILED=""; ACUR=$ADRY    # ACUR<0 => art off; pinned stays put

# print to every selected printer; one history row per printer
for P in "${PRINTERS[@]}"; do
    PDF=$(build_pdf "$TIER" "$TS  ·  $since  ·  $HOST  ·  $P" "$(ink_report "$P")" "$ACUR" page)
    if lp -d "$P" -n "$COPIES" -o media=A4 "$PDF" >/dev/null 2>>"$LOG"; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$NOW" "$TS" "$TIER" "$DAYS" "$COPIES" "$P" >> "$HISTORY_FILE"
        OK=$((OK+1))
        # the job just woke the printer, so CUPS now has fresh marker levels —
        # refresh the cache so the NEXT page shows current ink
        ink_report "$P" >/dev/null 2>&1 || true
    else
        echo "[$TS] FAILED to print to $P (see log)" | tee -a "$LOG" >&2
        FAILED="$FAILED $P"
    fi
    rm -f "$PDF"
    [ "$AROT" = 1 ] && ACUR=$(( (ACUR + 1) % ART_COUNT ))   # advance only when rotating
done
[ "$AROT" = 1 ] && set_artindex "$ACUR"   # persist the rotation for the next run

[ "$OK" -gt 0 ] && echo "$NOW" > "$LASTPRINT_FILE"
if [ "$DAYS" -lt 0 ]; then gapmsg="first run"; else gapmsg="gap was ${DAYS}d"; fi
echo "[$TS] printed $TIER keep-alive to $OK/$PCOUNT printer(s); $gapmsg" | tee -a "$LOG"

if [ -n "$FAILED" ]; then
    notify "Printer Don't Die Please!! — failed" "Could not print to:$FAILED"
    [ "$OK" -eq 0 ] && exit 1
fi
