#!/usr/bin/env bash
# A/B the three PersonaPlex precisions through the Python/MLX port's offline
# (wav -> wav) mode, which is the only deterministic harness available: same
# input audio, same seed, same voice, only the quantization changes.
#
# Scope note: the Swift path cannot take part in this comparison. It loads the
# pre-split aufklarer repos, while this port loads NVIDIA's original checkpoint
# and quantizes on the fly. The two also pin different MLX generations
# (mlx <0.27 here vs mlx-swift 0.30+ there), so treat THIS as the quality
# comparison across precisions and take latency numbers from the Swift app.
#
# The port prints no per-step timing, so ms/step is derived from wall clock
# against the known step count (12.5 Hz frames).
#
# Usage: scripts/personaplex_ab.sh [input.wav] [outdir]

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$ROOT/.venv-personaplex/bin/python"
IN_WAV="${1:-$ROOT/scratch_ab_input.wav}"
OUT_DIR="${2:-$ROOT/scratch/personaplex-ab}"
VOICE="${VOICE:-NATF2}"
SEED="${SEED:-42424242}"

mkdir -p "$OUT_DIR"

# Steps the model must run = input duration x 12.5 Hz.
STEPS=$("$PY" - "$IN_WAV" <<'EOF'
import sys, wave
w = wave.open(sys.argv[1])
print(int(w.getnframes() / w.getframerate() * 12.5))
EOF
)
echo "input=$(basename "$IN_WAV")  steps=$STEPS  voice=$VOICE  seed=$SEED"
echo

# Deliberately no `set -e`: if bf16 OOMs or fails, we still want q8 and q4.
for q in bf16 8 4; do
    args=()
    [ "$q" != "bf16" ] && args=(-q "$q")
    echo "=================================================================="
    echo "### precision=$q"
    echo "=================================================================="
    start=$(date +%s.%N)
    "$PY" -m personaplex_mlx.offline \
        --input-wav "$IN_WAV" \
        --output-wav "$OUT_DIR/out-$q.wav" \
        --output-text "$OUT_DIR/out-$q.txt" \
        --voice "$VOICE" \
        --seed "$SEED" \
        "${args[@]}" > "$OUT_DIR/log-$q.txt" 2>&1
    rc=$?
    end=$(date +%s.%N)
    echo "$end - $start" | bc > "$OUT_DIR/wall-$q.txt"
    echo "exit=$rc wall=$(cat "$OUT_DIR/wall-$q.txt")s"
    [ $rc -ne 0 ] && tail -15 "$OUT_DIR/log-$q.txt"
    echo
done

echo "======================== summary ========================"
printf '%-6s %10s %12s %s\n' precision wall_s ms/step response
for q in bf16 8 4; do
    wall=$(cat "$OUT_DIR/wall-$q.txt" 2>/dev/null || echo 0)
    # Wall includes model load + warmup, so this is an upper bound on ms/step.
    mps=$(echo "scale=1; $wall * 1000 / $STEPS" | bc 2>/dev/null || echo "?")
    txt=$(tr -d '\n' < "$OUT_DIR/out-$q.txt" 2>/dev/null | head -c 90)
    printf '%-6s %10.1f %12s  %s\n' "$q" "$wall" "$mps" "${txt:-(failed)}"
done
echo
echo "wavs in $OUT_DIR — listen to compare quality, that is the real test"
