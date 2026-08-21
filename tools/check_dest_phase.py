#!/usr/bin/env python3
"""Destination-phase assertion (PORTING.md §5.5, §7.25).

A CRC gate PASS can be two consoles identically stuck in the same wrong
place -- the checksum compare cannot see that. UNLIKE Shark Shark (whose
boot prompt "SELECT 1 OR 2 PLAYERS" needs an explicit deterministic
injector to get past at all), this cart has NO player-count prompt and no
injector: the boot-parked handler table ($58D6) already dispatches every
event straight into real gameplay (M0 -- confirmed live, every slot
routes to $59F1), so masked ($3F, disc-only) fuzz alone is expected to
leave the boot state almost immediately. The risk this check guards
against is narrower here -- a run that somehow never populates either
team's MOB record at all (a cross-seat routing bug, or virtual dispatch
never actually reaching game code) -- but is otherwise the same idea:
don't trust a green checksum compare without independently confirming
real game state exists.

NB_HTBL_BOOT ($58D6) is accepted alongside the two known transition
targets: it's also the tip-off/dead-ball table the game returns to
between plays (M0's `$5934 MVO R0,$035D <- $58D6` install), not only the
cold-boot default, so landing there again after MOB state is already
populated is normal, not evidence of never having started.

Usage: check_dest_phase.py build/det_a.out [...]
"""
import re
import sys

DUMP_RE = re.compile(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#", re.M)

NB_HTBL_BOOT = 0x58D6   # boot/tip-off/dead-ball table ($5934 install)
NB_HTBL_LIVE = 0x55AF   # live-play table ($55D2 install)
NB_HTBL_NULL = 0x1906   # EXEC null table ($55C5 install -- both seats disabled)


def check(path):
    text = open(path).read()
    mem = {}
    for m in DUMP_RE.finditer(text):
        addr = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            mem[addr + i] = int(w.rstrip("*"), 16)

    fail = []
    if not mem:
        return [f"{path}: no memory dumps found"]

    tbl_lo = mem.get(0x80C0)
    tbl_hi = mem.get(0x80C1)
    table = None
    if tbl_lo is not None and tbl_hi is not None:
        table = tbl_lo | (tbl_hi << 8)

    if table is None:
        fail.append("no $80C0/$80C1 (GAME_TBL) dump found")
    elif table not in (NB_HTBL_BOOT, NB_HTBL_LIVE, NB_HTBL_NULL):
        fail.append(f"GAME_TBL = ${table:04X}, expected NB_HTBL_BOOT "
                    f"($58D6), NB_HTBL_LIVE ($55AF) or NB_HTBL_NULL "
                    f"($1906) -- an unrecognized handler table is either a "
                    f"new install this session hasn't seen, or a sign the "
                    f"adopted-table capture itself is wrong")

    mob0 = any(mem.get(a, 0) for a in range(0x31D, 0x325))
    mob1 = any(mem.get(a, 0) for a in range(0x325, 0x32D))
    if not mob0:
        fail.append("MOB0 ($031D-$0324, seat 0) all zero -- team 0's "
                    "state was never populated")
    if not mob1:
        fail.append("MOB1 ($0325-$032C, seat 1) all zero -- team 1's "
                    "state was never populated (a cross-seat routing bug "
                    "would show up exactly this way)")

    if fail:
        return [f"{path}: {f}" for f in fail]

    tbl_note = f" (GAME_TBL=${table:04X})" if table is not None else ""
    print(f"DEST-PHASE OK ({path}): MOB0 and MOB1 both populated{tbl_note}")
    return []


problems = []
for arg in sys.argv[1:] or ["build/det_a.out"]:
    problems += check(arg)

if problems:
    print("DEST-PHASE FAIL:")
    for p in problems:
        print("  -", p)
    sys.exit(1)
