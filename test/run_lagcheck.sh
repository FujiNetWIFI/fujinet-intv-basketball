#!/bin/sh
# M3/§7.24 interception proof: the same in-ROM demo script, run at d=0
# (basketball_lag0) and d=20 (basketball_lag).  The delay ring is the ONLY
# difference between the two builds, so the whole per-tick game-state
# timeline must come out shifted by exactly d.
#
# UNLIKE the family's whole-checksum default (Golf's §7.33 design), this
# does NOT correlate TRACE_RING. This cart's four native timer entries
# (game clock, shot clock, animation walk, ball blink -- all native
# dispatch, all always-armed, all firing on a fixed real-time schedule
# regardless of player input) would swamp the much smaller input-driven
# signal in a whole-state cross-correlation -- Shark Shark's exact §7.38
# failure shape (documented there: d0/d20 match exactly for the first N
# ambient-only ticks, then diverge with no discernible peak at any shift,
# because ambient state at d20's tick T+20 reflects 20 MORE real ticks of
# schedule than d0's tick T, not a delayed copy of it).
#
# Instead this correlates a DIRECT, un-smoothed echo of player input:
# SHADOW_CTRL/SHADOW_CTRL_R (ram.asm), the polled shadow pair this cart's
# single `[$011F+seat]` poll reads -- refreshed every tick straight from
# the delay ring with zero game-logic smoothing in between, by
# construction (src/hook.asm SHADOW_FROM_RINGS). Captured into a
# dedicated LAG_RING by debug.asm's TRACE_TICK. Unlike Golf's
# un-reverse-engineered swing/aim mechanic, this needed no guessing at an
# internal game cell at all: the shadow pair already IS the canonical
# input echo, existing purely as netcode infrastructure outside
# TRACE_RANGES/LS_CKSUM/RS_TAILTBL's own coverage.
#
# TRACE_STOP=250 is under 256 so neither ring ever wraps: ring index i IS
# tick i, directly, no lap ambiguity.
#
# Pure `r N` + one final breakpoint park: deterministic per build
# (PORTING.md §7.17 bans breakpoint-forced injection for exact-tick work,
# not instruction-count parks -- and this uses neither, just TRACE_DONE).
set -e
cd "$(dirname "$0")/.."
BUILD=build
JZINTV=${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}

make -s $BUILD/basketball_lag0.bin $BUILD/basketball_lag.bin >/dev/null

dump() {  # $1 = binary, $2 = sym file, $3 = output log
    DONE_ADDR=$(awk '/ TRACE_DONE$/ { sub(/^0+/, "", $1); print $1 }' "$2")
    if [ -z "$DONE_ADDR" ]; then
        echo "TRACE_DONE not found in $2" >&2
        exit 1
    fi
    {
        printf 'b 14D5\nr 10000000\ng 7 14D7\nn 14D5\n'
        printf 'b %s\nr 200000000\n' "$DONE_ADDR"
        printf 'm 9200 400\n'        # LAG_RING: 256 x [SHADOW_CTRL, SHADOW_CTRL_R]
        printf 'm 8108 2\n'          # TICK_LO/TICK_HI at park
        printf 'q\n'
    } > "$BUILD/lagprobe.scr"
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        timeout 120 "$JZINTV" -d --script="$BUILD/lagprobe.scr" -r0 \
        -e rom/exec.bin -g rom/grom.bin "$1" > "$2.out" 2>&1 || true
    if ! grep -q "Hit breakpoint at .$DONE_ADDR" "$2.out"; then
        echo "$1 never reached TRACE_DONE (\$$DONE_ADDR); tail:" >&2
        tail -5 "$2.out" >&2
        exit 1
    fi
    cp "$2.out" "$3"
}

dump $BUILD/basketball_lag0.bin $BUILD/basketball_lag0.sym $BUILD/lag0.log
dump $BUILD/basketball_lag.bin  $BUILD/basketball_lag.sym  $BUILD/lag20.log

python3 - $BUILD/lag0.log $BUILD/lag20.log <<'EOF'
import re, sys

def ring(path):
    """Parse the `m 9200 400` LAG_RING dump: 256 entries x 2 words
    (SHADOW_CTRL, SHADOW_CTRL_R -- seat 0/1's polled shadow input).  With
    TRACE_STOP < 256 the ring never wraps, so ring[i] is simply tick i's
    captured shadow pair.  Returns a list of 256 (seat0, seat1) tuples
    and the parked TICK_LO/TICK_HI."""
    log = open(path).read()
    rows = re.findall(r'^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#',
                       log, re.M)
    words = []
    tick_row = None
    for addr, body in rows:
        a = int(addr, 16)
        vals = [int(w.rstrip('*'), 16) for w in body.split()]
        if 0x9200 <= a < 0x9600:
            words.extend(vals)
        elif a == 0x8108:
            tick_row = vals
    if len(words) < 512:
        raise SystemExit(f"LAGCHECK FAIL: {path} ring dump too short "
                          f"({len(words)} words)")
    entries = [(words[2 * i] & 0xFFFF, words[2 * i + 1] & 0xFFFF)
               for i in range(256)]
    tick = None
    if tick_row:
        tick = (tick_row[0] & 0xFF) | ((tick_row[1] & 0xFF) << 8)
    return entries, tick

r0, t0 = ring(sys.argv[1])
r20, t20 = ring(sys.argv[2])
print(f"parked ticks: d=0 -> {t0}, d=20 -> {t20}")
PARK = min(t for t in (t0, t20) if t is not None)

# Score each candidate shift: tick t in the d=0 run should equal tick
# (t + s) in the d=20 run when the state timeline is shifted s ticks
# later.  Only compare ticks strictly inside BOTH parked ranges (no
# wraparound, no stale zero-fill past the park point).
best = []
for s in range(0, 41):
    hit = tot = 0
    for t in range(PARK - 41):
        if t + s >= PARK:
            continue
        tot += 1
        if r0[t] == r20[t + s]:
            hit += 1
    if tot >= 50:
        best.append((hit, s))
if not best:
    print("LAGCHECK FAIL: not enough in-range samples to score any shift")
    sys.exit(1)
best.sort(reverse=True)
peak_hit, shift = best[0]
median_hit = sorted(h for h, s in best)[len(best) // 2]
zero_hit = dict((s, h) for h, s in best).get(0)

print(f"best alignment: shift = {shift} ticks ({peak_hit}/{tot} agree)")
print(f"baseline      : median shift agreement {median_hit}/{tot}"
      + (f", shift=0 {zero_hit}/{tot}" if zero_hit is not None else ""))
top = sorted(best, reverse=True)[:5]
print("top shifts    : " + ", ".join(f"{s}:{h}" for h, s in top))

if not (17 <= shift <= 23):
    print(f"LAGCHECK FAIL: agreement peaks at shift {shift}, expected ~20")
    sys.exit(1)
if peak_hit < 1.25 * median_hit:
    print(f"LAGCHECK FAIL: peak {peak_hit} is not clearly above the "
          f"{median_hit} baseline -- no timeline shift is discernible")
    sys.exit(1)
if zero_hit is not None and peak_hit < 1.25 * zero_hit:
    print(f"LAGCHECK FAIL: shift {shift} ({peak_hit}) is not clearly "
          f"better than shift 0 ({zero_hit}) -- the delay ring is inert")
    sys.exit(1)
print(f"LAGCHECK PASS: interception + delay ring proven -- the state "
      f"timeline shifts {shift} ticks later at d=20")
print(f"  (agreement peaks at {peak_hit} vs a {median_hit} baseline)")
EOF
