#!/bin/sh
# M4 recovery test: the 2-player rig with a fault injection -- console 2's
# $015F cell (the game clock's low byte, printed at BACKTAB $023D -- M0)
# is corrupted mid-run via the debugger.
#
# This is a one-shot, CONTAINED corruption: $015F is written periodically
# by NB_TICK2 (the native game-clock entry, ~2.22 Hz) as the clock counts
# down during live play, and nothing else reads it in a way that would
# turn a single bad value into an ONGOING divergence (unlike Shark
# Shark's rejected SS_PCOUNT choice, which was ALSO a loop bound another
# timer entry consulted every tick -- PORTING.md §7.39's own caution
# about picking the wrong cell for each test mode applies here too, and
# $015F was chosen specifically to avoid that shape).
#
# Expected: CRC mismatch detected, the host pushes the state image
# (broadcast), ALL consoles re-baseline together, CRC rounds go back to
# matching, nobody drops.  PLAYERS fixed at 2 (this cart hard-caps there).
set -e
. "$(dirname "$0")/serverlib.sh"
BUILD=build
RIG="$BUILD/rig"
JZINTV="${JZINTV:-$HOME/Workspace/jzintv-20200712-src/bin/jzintv}"
RUN_SECS="${RUN_SECS:-100}"
PLAYERS="${PLAYERS:-2}"

i=1
while [ "$i" -le "$PLAYERS" ]; do
    [ -d "$RIG/fn$i" ] || { echo "run 'make rig PLAYERS=$PLAYERS' once first"; exit 1; }
    i=$((i+1))
done

# Same guard as run_rig.sh: never point fuzz clients at production.
if ! grep -q '127\.0\.0\.1' "$BUILD/srv_endpoint.asm" 2>/dev/null; then
    echo "run_m4.sh: build/srv_endpoint.asm is not 127.0.0.1 -- rebuild first"
    exit 1
fi

# Stale rig fujinet instances hold the BOIP ports and make every later
# launch a silent no-op (the fresh copy fails to bind and dies).
pkill -f 'fujinet -u 127.0.0.1:1808' 2>/dev/null || true
sleep 0.5
FNS=""
i=1
while [ "$i" -le "$PLAYERS" ]; do
    ( cd "$RIG/fn$i" && exec ./fujinet -u 127.0.0.1:1808$i ) > "$RIG/fn$i.log" 2>&1 &
    FNS="$FNS $!"
    i=$((i+1))
done
( relay_server --port 9114 --auto-go "$PLAYERS" ) \
    > "$RIG/m4_server.log" 2>&1 &
SRV=$!
trap 'kill $FNS $SRV 2>/dev/null || true' EXIT
sleep 1.5

# The debugger's `r N` counts INSTRUCTIONS (~4.6 cycles each on average),
# so ~200000 instructions per emulated second.  Console 2 gets the fault
# poke at ~40s (well past matchmaking at any player count); every console
# gets the stagger-compensated run length so all quit together.
CONS=""
i=1
while [ "$i" -le "$PLAYERS" ]; do
    SECS=$(( RUN_SECS - 2 * (i - 1) ))
    {
        printf 'b 14D5\nr 10000000\n'
        j=1
        while [ "$j" -lt "$i" ]; do
            printf 'n 14D5\nr %d\nb 14D5\nr 10000000\n' $((0x49BF0 + i * 4369))
            j=$((j+1))
        done
        printf 'g 7 14D7\nn 14D5\n'
        if [ "$i" = 1 ] && [ -n "$QUIESCE" ]; then
            # QUIESCE=1: starting when the fault lands (matching console
            # 2's timing below), keep FORCING the HOST's NB_PHASE ($0163)
            # dead-ball bits ($C0 -- both seats' input disabled) directly.
            #
            # UNLIKE Shark Shark's SS_QUIESCENT (a value SS_GAME_TICK
            # recomputed fresh every tick from underlying MOB bits, which
            # made a direct external poke structurally unable to stick,
            # PORTING.md §7.39), NB_PHASE is a RAW cell here: it is only
            # ever written at the cart's own ~15 phase-transition call
            # sites (M0), never recomputed unconditionally on the per-tick
            # path, so a repeated external poke DOES stick for as long as
            # the forcing loop holds -- confirm live in this run; if it
            # turns out something races the poke after all, fall back to
            # forcing the underlying MOB "alive" bits ($031D/$0325 bit
            # $0800, $0323/$032B) the way Shark Shark's fix did.
            #
            # Repeated forcing (not a one-shot poke), matching the family
            # precedent: CRC comparison (and therefore RS_PENDING actually
            # polling) only happens on 64-tick boundaries and RS_PEND_MAX
            # is only 60 ticks, so a narrow window can miss it entirely.
            printf 'r 8000000\n'
            k=0
            while [ "$k" -lt 200 ]; do
                printf 'e 163 C0\nr 50000\n'
                k=$((k+1))
            done
            # Capture RS_GATE right here, before any LATER (organic)
            # push has a chance to overwrite it -- it is a single cell
            # holding only the reason for the MOST RECENT push.
            printf 'm 818A 1\n'
            printf 'r %d\n' $(( (SECS - 40 - 50) * 200000 ))
        elif [ "$i" = 2 ] && [ -n "$QUIESCE" ]; then
            # QUIESCE mode uses the SAME $015F fault as the plain test --
            # LS_CKSUM checksums every cell in $015D-$01EF unconditionally
            # each comparison, so it shows up on the very next CRC check
            # regardless of whether game logic reads it, and $015F is
            # written back to a normal value by NB_TICK2 often enough
            # (every ~2.22 Hz) that it must land INSIDE the wide forcing
            # window below to be caught reliably, not just eventually via
            # fuzz luck (same reasoning the family precedent uses for
            # picking a QUIESCE-mode fault).
            printf 'r 8000000\ne 15F FF\nr %d\n' $(( (SECS - 40) * 200000 ))
        elif [ "$i" = 2 ]; then
            # Fault: rewrite console 2's $015F (game clock low byte) to
            # $FF -- outside any range the clock's own countdown can ever
            # produce, so "does it still read $FF" is an unambiguous
            # repair check.  One-shot: NB_TICK2 overwrites it again on its
            # own next countdown tick regardless of the fault, so a
            # working resync just needs to land before that happens (or
            # be invisible if it doesn't -- the CRC comparison at the
            # 64-tick boundary is what actually detects it either way).
            printf 'r 8000000\ne 15F FF\nr %d\n' $(( (SECS - 40) * 200000 ))
        else
            printf 'r %d\n' $(( SECS * 200000 ))
        fi
        printf 'm 8100 20\nm 8150 60\nm 80C0 2\nm 8180 10\nm 8090 10\nm 0160 20\nm 031D 10\n'
        printf 'q\n'
    } > "$RIG/m4c$i.scr"
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
        timeout $((RUN_SECS + 200)) "$JZINTV" -d --script="$RIG/m4c$i.scr" \
        --fujinet=localhost:1985$i -e rom/exec.bin -g rom/grom.bin \
        "$BUILD/basketball_net$i.bin" > "$RIG/m4c$i.out" 2>&1 &
    CONS="$CONS $!"
    sleep 2
    i=$((i+1))
done
wait $CONS || true

PLAYERS=$PLAYERS python3 - "$RIG" <<'EOF'
import os, re, sys
rig = sys.argv[1]
players = int(os.environ["PLAYERS"])
NB_HTBL_BOOT = 0x58D6
NB_HTBL_LIVE = 0x55AF
NB_HTBL_NULL = 0x1906

def cells(path):
    mem = {}
    for m in re.finditer(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#",
                         open(path).read(), re.M):
        a = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            mem[a + i] = int(w.rstrip("*"), 16)
    return mem

def first_reading(path, addr):
    """The FIRST time `addr` was dumped in `path`, not the last -- for
    cells like RS_GATE ($818A) that get overwritten by a later, unrelated
    push before the run ends."""
    for m in re.finditer(r"^([0-9A-F]{4}):((?:\s+[0-9A-F]{4}\*?){1,8})\s*#",
                         open(path).read(), re.M):
        a = int(m.group(1), 16)
        for i, w in enumerate(m.group(2).split()):
            if a + i == addr:
                return int(w.rstrip("*"), 16)
    return None

ok = True
for n in range(1, players + 1):
    m = cells(f"{rig}/m4c{n}.out")
    tick = m.get(0x8108, 0) | (m.get(0x8109, 0) << 8)
    active, dropped, hold = m.get(0x8162, 0), m.get(0x8163, 0), m.get(0x8090, 9)
    diag = [m.get(0x8180 + i, 0) for i in range(4)]
    pend, waited = m.get(0x8187, 0), m.get(0x8189, 0)
    seat = m.get(0x8160, 9)
    why = m.get(0x818A, 0)
    gtbl = m.get(0x80C0, 0) | (m.get(0x80C1, 0) << 8)
    gate = "n/a (guest)" if seat else {
        0: "never pushed",
        1: f"QUIESCENT (NB_PHASE forced) after {waited} ticks",
        2: f"cap expired at {waited} ticks (pushed mid-play)"}.get(why, "?")
    print(f"console {n}: seat={seat} active={active} dropped={dropped} "
          f"hold={hold} tick={tick} diag(slip,rej,tmo,err)={diag}")
    print(f"           resync gate: pending={pend} GAME_TBL=${gtbl:04X} -> {gate}")
    ok &= (active == 1 and dropped == 0 and hold == 0 and tick > 400
           and diag == [0, 0, 0, 0])
    # Destination-phase assertion (§7.25): GAME_TBL landed on a known
    # table and both teams' state is populated.
    mob0 = any(m.get(a, 0) for a in range(0x31D, 0x325))
    mob1 = any(m.get(a, 0) for a in range(0x325, 0x32D))
    print(f"           mob0={mob0} mob1={mob1}")
    if gtbl not in (NB_HTBL_BOOT, NB_HTBL_LIVE, NB_HTBL_NULL):
        print(f"console {n}: GAME_TBL=${gtbl:04X} is none of BOOT/LIVE/"
              f"NULL -- unexpected destination")
        ok = False
    if not (mob0 and mob1):
        print(f"console {n}: MOB0={mob0} MOB1={mob1} -- one seat's team "
              f"was never populated")
        ok = False
    # The fault itself: both modes poke $015F (game clock low byte) to
    # $FF, a value the clock's own countdown can never produce.  By the
    # end of a successful recovery it should not still be present on
    # EITHER console -- a resync that only fixed the CRC bookkeeping but
    # left the actual corrupted byte in place would be a false pass.
    clock_lo = m.get(0x15F)
    if clock_lo == 0xFF:
        print(f"console {n}: $015F is still the fault value $FF -- "
              f"not actually repaired")
        ok = False

# QUIESCE=1 exists to prove the quiescent branch works at all; require it.
if os.environ.get("QUIESCE"):
    host_why = first_reading(f"{rig}/m4c1.out", 0x818A)
    if host_why != 1:
        print(f"QUIESCE run: host RS_GATE={host_why}, expected 1 (quiescent) "
              f"-- the dead-ball branch of RS_PENDING did not fire")
        ok = False
    else:
        print("QUIESCE run: the dead-ball branch of RS_PENDING fired as intended")

lines = open(f"{rig}/m4_server.log").read().splitlines()
mm = [i for i, l in enumerate(lines) if "CRC MISMATCH" in l]
oks = [i for i, l in enumerate(lines) if "crc ok" in l]
recovered = bool(mm) and bool(oks) and max(oks) > max(mm)
print(f"server: mismatches={len(mm)} crc-ok-lines={len(oks)} "
      f"recovered-after-fault={recovered}")
ok &= recovered
print(f"M4 PASS ({players} players)" if ok else "M4 FAIL")
sys.exit(0 if ok else 1)
EOF
