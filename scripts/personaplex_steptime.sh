#!/usr/bin/env bash
# Per-step inference cost, with model-load time cancelled out.
#
# The port prints no timing and its wall clock is dominated by loading weights
# (17 GB bf16 vs 9 GB int8 vs 5.4 GB int4), so comparing raw wall times mostly
# compares file sizes. Instead run each precision at TWO input lengths and take
# the slope:
#
#     ms/step = (wall_long - wall_short) / (steps_long - steps_short)
#
# Load + warmup is identical in both runs, so it cancels. What is left is the
# true marginal cost of a frame — the number that matters against the 80 ms budget.
#
# Usage: scripts/personaplex_steptime.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/.venv-personaplex/bin/python"
OUT_DIR="$ROOT/scratch/personaplex-steptime"
VOICE="${VOICE:-NATF2}"
SEED="${SEED:-42424242}"
SHORT_S="${SHORT_S:-8}"
LONG_S="${LONG_S:-40}"

mkdir -p "$OUT_DIR"

# Build the two inputs: same speech, different amounts of trailing silence.
"$PY" - "$ROOT/hello.wav" "$OUT_DIR" "$SHORT_S" "$LONG_S" <<'EOF'
import sys, wave, numpy as np
src, out, short_s, long_s = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
w = wave.open(src); rate = w.getframerate()
data = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
for tag, secs in (("short", short_s), ("long", long_s)):
    buf = np.concatenate([data, np.zeros(int(rate * secs), dtype=np.int16)])
    o = wave.open(f"{out}/in-{tag}.wav", "w")
    o.setnchannels(1); o.setsampwidth(2); o.setframerate(rate)
    o.writeframes(buf.tobytes()); o.close()
    print(f"{tag}: {len(buf)/rate:.2f}s -> {int(len(buf)/rate*12.5)} steps")
EOF

steps() { "$PY" -c "import wave,sys;w=wave.open(sys.argv[1]);print(int(w.getnframes()/w.getframerate()*12.5))" "$1"; }
S_SHORT=$(steps "$OUT_DIR/in-short.wav")
S_LONG=$(steps "$OUT_DIR/in-long.wav")
echo "steps: short=$S_SHORT long=$S_LONG  delta=$((S_LONG - S_SHORT))"
echo

run() { # precision, input tag -> wall seconds
    local q="$1" tag="$2"
    local args=()
    [ "$q" != "bf16" ] && args=(-q "$q")
    local start end
    start=$(date +%s.%N)
    "$PY" -m personaplex_mlx.offline \
        --input-wav "$OUT_DIR/in-$tag.wav" \
        --output-wav "$OUT_DIR/out-$q-$tag.wav" \
        --output-text "$OUT_DIR/out-$q-$tag.txt" \
        --voice "$VOICE" --seed "$SEED" "${args[@]}" \
        > "$OUT_DIR/log-$q-$tag.txt" 2>&1
    end=$(date +%s.%N)
    echo "$end - $start" | bc
}

printf '%-6s %10s %10s %12s %12s\n' precision short_s long_s ms/step load_s
for q in bf16 8 4; do
    ws=$(run "$q" short)
    wl=$(run "$q" long)
    mps=$(echo "scale=1; ($wl - $ws) * 1000 / ($S_LONG - $S_SHORT)" | bc)
    # Extrapolate back to zero steps to recover load+warmup overhead.
    load=$(echo "scale=1; $ws - ($mps * $S_SHORT / 1000)" | bc)
    printf '%-6s %10.1f %10.1f %12s %12s\n' "$q" "$ws" "$wl" "$mps" "$load"
done
echo
echo "budget is 80 ms/step (12.5 Hz frames); under that = real-time"
