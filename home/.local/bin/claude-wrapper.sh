#!/bin/bash
# ================================================================
# Master Claude Wrapper - Survives full-path calls + updates
#
# 2026-06-07: Two fixes for gascity compatibility:
#  1. exec through a symlink named "claude" (+ exec -a claude) so the
#     running process keeps comm/argv0 = "claude". gc's tmux liveness
#     probe matches process names {node, claude}; exec'ing the bare
#     versioned binary (comm "2.1.166") made every agent look like a
#     "zombie process" -> kill/respawn loop (147+ mayor crashes).
#  2. Deterministic profile selection when running under gascity:
#     hash GC_AGENT/GC_SESSION_NAME so an agent always lands on the
#     same profile across respawns -- gc relaunches with --resume and
#     the session history lives inside CLAUDE_CONFIG_DIR.
#
# 2026-06-20: Usage-aware load balancing for interactive spawns and
#     ephemeral GC pool workers (dogs, polecats, polekittens). Named
#     infrastructure (mayor/deacon/witness/refinery) stays hash-pinned
#     for --resume unless ~/.claude-profiles/agent-overrides says otherwise.
#
# 2026-07-30: Absolute ceiling protect — if either profile's raw weekly
#     usage is >= LB_CEILING (default 99), ALL spawns (LB, hash-pin,
#     overrides, force-profile, LB-disabled) go to the lighter profile.
#     Auto-reverts once both profiles are under the ceiling again.
# ================================================================

set -euo pipefail

# ====================== CONFIG ======================
BASE_DIR="$HOME/.claude-profiles"
DIR_A="$BASE_DIR/A"
DIR_B="$BASE_DIR/B"
PROFILES=(A B)

# Load-balance tuning (override via env if needed)
LB_CACHE_TTL="${CLAUDE_LB_CACHE_TTL:-30}"        # seconds between usage refreshes
LB_POOL_MAX_STALE="${CLAUDE_LB_POOL_MAX_STALE:-15}" # pool spawns block-refresh past this age
LB_USAGE_WEIGHT="${CLAUDE_LB_USAGE_WEIGHT:-10}"  # score per 1% weekly usage
LB_PROC_WEIGHT="${CLAUDE_LB_PROC_WEIGHT:-6}"     # score per active worker
LB_BIAS_THRESHOLD="${CLAUDE_LB_BIAS_THRESHOLD:-2}" # % gap before extra bias
LB_BIAS_MULTIPLIER="${CLAUDE_LB_BIAS_MULTIPLIER:-5}"
LB_FORCE_GAP="${CLAUDE_LB_FORCE_GAP:-2}"           # % gap → pool workers go to light profile only
LB_POOL_PROC_WEIGHT="${CLAUDE_LB_POOL_PROC_WEIGHT:-0}" # pool rebalance follows quota, not proc herd
# When either profile is at/above this raw weekly usage %, ALL spawns hand out
# the lighter profile (absolute protect). Drops away once both are under it.
LB_CEILING="${CLAUDE_LB_CEILING:-99}"
LB_BASE_DIR="$BASE_DIR"
LB_CACHE_FILE="$BASE_DIR/.lb-cache"
LB_LOCK_FILE="$BASE_DIR/.lb-cache.lock"
AGENT_OVERRIDES_FILE="$BASE_DIR/agent-overrides"
# ===================================================

_WRAPPER_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=claude-lb-usage.sh
source "$_WRAPPER_DIR/claude-lb-usage.sh"

# Resolve the real binary once, and keep a stable exec path whose
# basename is "claude" so the kernel sets comm="claude".
find_real_claude() {
    ls -t "$HOME/.local/share/claude/versions"/2.* 2>/dev/null | head -n 1
}

exec_claude() {
    local real="$1"; shift
    local link_dir="$HOME/.local/share/claude/exec"
    local link="$link_dir/claude"
    mkdir -p "$link_dir"
    # Atomic refresh: build aside, rename over. Safe under concurrent spawns.
    if [[ "$(readlink "$link" 2>/dev/null)" != "$real" ]]; then
        ln -sfn "$real" "$link.tmp.$$" && mv -Tf "$link.tmp.$$" "$link"
    fi
    # exec -a pins argv0; the symlink basename pins comm. gc's liveness
    # probe accepts either, this gives it both.
    exec -a claude "$link" "$@"
}

profile_dir() {
    case "$1" in
        A) printf '%s' "$DIR_A" ;;
        B) printf '%s' "$DIR_B" ;;
        *) return 1 ;;
    esac
}

read_agent_override() {
    local agent=$1
    [[ -f "$AGENT_OVERRIDES_FILE" ]] || return 1
    grep -E "^${agent}=[AB]$" "$AGENT_OVERRIDES_FILE" 2>/dev/null | tail -1 | cut -d= -f2
}

# Ephemeral pool workers may land on either profile; infrastructure keeps hash pin.
is_pool_agent() {
    local agent=$1
    [[ -n "$agent" ]] || return 1
    case "$agent" in
        gastown.mayor|gastown.deacon|gastown.boot) return 1 ;;
        *gastown.witness|*gastown.refinery) return 1 ;;
        *control-dispatcher*) return 1 ;;
    esac
    case "$agent" in
        *dog*) return 0 ;;
        *polecat*|*polekitten*|*thundercat*|*gorkcat*) return 0 ;;
        */koolkats.*|koolkats.*) return 0 ;;
        */gastown.*|gastown.polecat*) return 0 ;;
    esac
    return 1
}

# Pool classification uses GC_AGENT first, then GC_TEMPLATE for namepool aliases
# and other instance handles whose GC_AGENT is just a slot id (e.g. "nux").
is_pool_spawn() {
    local key=$1
    is_pool_agent "$key" && return 0
    [[ -n "${GC_TEMPLATE:-}" ]] && is_pool_agent "$GC_TEMPLATE"
}

hash_profile_for_agent() {
    local agent=$1
    local hash
    hash=$(printf '%s' "$agent" | cksum | cut -d' ' -f1)
    if [ $((hash % 2)) -eq 0 ]; then
        printf 'A'
    else
        printf 'B'
    fi
}

# If either raw weekly usage is >= LB_CEILING and the other is strictly
# lighter, set SELECTED_DIR to the light profile and return 0. Else return 1
# (caller proceeds with normal selection). Applies to every spawn path.
try_apply_ceiling_protect() {
    local pool_mode=${1:-0}
    local label=${2:-spawn}
    local usage_a usage_b pick

    read -r usage_a usage_b < <(lb_load_usage_snapshot "$REAL_CLAUDE" "$pool_mode") || true
    usage_a=${usage_a:-0}
    usage_b=${usage_b:-0}

    if (( usage_a < LB_CEILING && usage_b < LB_CEILING )); then
        return 1
    fi
    if (( usage_a < usage_b )); then
        pick=A
    elif (( usage_b < usage_a )); then
        pick=B
    else
        # both at/above ceiling and tied — no unique light profile
        return 1
    fi

    SELECTED_DIR="$(profile_dir "$pick")"
    echo "🔑 [Master Wrapper] ceiling-protect $label → $pick" \
        "(week A:${usage_a}% B:${usage_b}% | ceiling:${LB_CEILING}% — all spawns to lighter)" >&2
    return 0
}

apply_balanced_selection() {
    local label=$1
    local pool_mode=${2:-0}
    local LB_PICK="" LB_USAGE_A="" LB_USAGE_B="" LB_PROCS_A="" LB_PROCS_B="" LB_SCORE_A="" LB_SCORE_B="" LB_MODE=""
    read -r LB_PICK LB_USAGE_A LB_USAGE_B LB_PROCS_A LB_PROCS_B LB_SCORE_A LB_SCORE_B LB_MODE \
        < <(select_profile_balanced "$REAL_CLAUDE" "$pool_mode") || true
    if [[ -z "${LB_PICK:-}" ]] || ! SELECTED_DIR="$(profile_dir "$LB_PICK" 2>/dev/null)"; then
        LB_PICK=$(hash_profile_for_agent "${GC_KEY:-$$}")
        SELECTED_DIR="$(profile_dir "$LB_PICK")"
        echo "🔑 [Master Wrapper] $label fallback → $LB_PICK (balancer unavailable)" >&2
        return 0
    fi
    local mode_s=""
    [[ -n "${LB_MODE:-}" ]] && mode_s=" | mode:${LB_MODE}"
    echo "🔑 [Master Wrapper] $label → $LB_PICK" \
        "(week A:${LB_USAGE_A}% B:${LB_USAGE_B}% | workers A:${LB_PROCS_A} B:${LB_PROCS_B} | score A:${LB_SCORE_A} B:${LB_SCORE_B}${mode_s})" >&2
}

# True when this PID is an active Claude worker (not a shell/tmux that
# merely inherited CLAUDE_CONFIG_DIR).
is_claude_worker() {
    local pid=$1
    local comm cmdline
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    case "$comm" in
        claude|node) return 0 ;;
    esac
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    [[ "$cmdline" == *"/claude/versions/"* || "$cmdline" == *"/claude/exec/claude"* ]]
}

# Count live workers per profile via CLAUDE_CONFIG_DIR.
count_profile_workers() {
    local -A counts=([A]=0 [B]=0)
    local pid dir
    for pid in $(pgrep -u "$(id -u)" 2>/dev/null || true); do
        [[ -r "/proc/$pid/environ" ]] || continue
        is_claude_worker "$pid" || continue
        dir=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep '^CLAUDE_CONFIG_DIR=' | cut -d= -f2- || true)
        case "$dir" in
            "$DIR_A") counts[A]=$((counts[A] + 1)) ;;
            "$DIR_B") counts[B]=$((counts[B] + 1)) ;;
        esac
    done
    printf '%s %s\n' "${counts[A]}" "${counts[B]}"
}

# Lower score = less loaded = more desirable.
# pool_mode=1: rebalance ephemeral workers toward weekly quota headroom.
#   At/above LB_FORCE_GAP, pick the light profile deterministically — weighted
#   random was leaving ~35% of pool spawns on the heavy account at a 15% gap.
#   Proc weight is skipped for pool picks so workers already on the light side
#   do not discourage further pool spawns there.
# Absolute ceiling: if either raw weekly usage is >= LB_CEILING (default 99),
#   always hand out the lighter profile (interactive + pool). When both fall
#   back under the ceiling, normal weighted / force-gap balancing resumes.
select_profile_balanced() {
    local real=$1
    local pool_mode=${2:-0}
    local usage_a usage_b procs_a procs_b
    local corr_a corr_b eff_a eff_b
    local score_a score_b weight_a weight_b total roll
    local usage_gap proc_weight pick mode

    read -r usage_a usage_b < <(lb_load_usage_snapshot "$real" "$pool_mode") || true
    read -r procs_a procs_b < <(count_profile_workers) || true
    read -r corr_a corr_b < <(lb_read_usage_corrections) || true

    usage_a=${usage_a:-0}
    usage_b=${usage_b:-0}
    procs_a=${procs_a:-0}
    procs_b=${procs_b:-0}
    corr_a=${corr_a:-0}
    corr_b=${corr_b:-0}
    eff_a=$(( usage_a + corr_a ))
    eff_b=$(( usage_b + corr_b ))
    usage_gap=$(( eff_a - eff_b ))

    # Ceiling protect uses raw weekly % (actual quota), not LB corrections.
    # Only force when one side is saturated *and* the other is strictly lighter;
    # if both are at/above ceiling and tied, fall through to normal scoring.
    if (( usage_a >= LB_CEILING || usage_b >= LB_CEILING )); then
        if (( usage_a < usage_b )); then
            pick=A
            mode=ceiling-protect
            echo "$pick $usage_a $usage_b $procs_a $procs_b 0 0 $mode"
            return 0
        elif (( usage_b < usage_a )); then
            pick=B
            mode=ceiling-protect
            echo "$pick $usage_a $usage_b $procs_a $procs_b 0 0 $mode"
            return 0
        fi
        # both saturated and equal — keep normal path
    fi

    if (( pool_mode )); then
        proc_weight=$LB_POOL_PROC_WEIGHT
        if pick=$(lb_read_pool_force 2>/dev/null); then
            mode=pool-force-manual
            echo "$pick $usage_a $usage_b $procs_a $procs_b 0 0 $mode"
            return 0
        fi
        if (( usage_gap >= LB_FORCE_GAP )); then
            pick=B
            mode=pool-force-light
            echo "$pick $usage_a $usage_b $procs_a $procs_b 0 0 $mode"
            return 0
        elif (( usage_gap <= -LB_FORCE_GAP )); then
            pick=A
            mode=pool-force-light
            echo "$pick $usage_a $usage_b $procs_a $procs_b 0 0 $mode"
            return 0
        fi
        mode=pool-weighted
    else
        proc_weight=$LB_PROC_WEIGHT
        mode=interactive-weighted
    fi

    score_a=$(( eff_a * LB_USAGE_WEIGHT + procs_a * proc_weight ))
    score_b=$(( eff_b * LB_USAGE_WEIGHT + procs_b * proc_weight ))

    if (( usage_gap >= LB_BIAS_THRESHOLD )); then
        score_a=$(( score_a + usage_gap * LB_BIAS_MULTIPLIER ))
    elif (( usage_gap <= -LB_BIAS_THRESHOLD )); then
        score_b=$(( score_b + (-usage_gap) * LB_BIAS_MULTIPLIER ))
    fi

    weight_a=$(( 1000 - score_a ))
    weight_b=$(( 1000 - score_b ))
    if (( weight_a < 1 )); then weight_a=1; fi
    if (( weight_b < 1 )); then weight_b=1; fi
    total=$(( weight_a + weight_b ))
    roll=$(( RANDOM % total ))

    if (( roll < weight_a )); then
        pick=A
    else
        pick=B
    fi
    if (( corr_a != 0 || corr_b != 0 )); then
        mode="${mode}|eff:A${eff_a},B${eff_b}|corr:A${corr_a},B${corr_b}"
    fi
    echo "$pick $usage_a $usage_b $procs_a $procs_b $score_a $score_b $mode"
}

# Parse & strip --force-profile
FORCE_PROFILE=""
NEW_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-profile)
            shift
            [[ $# -gt 0 ]] && FORCE_PROFILE="$1" && shift
            ;;
        *)
            NEW_ARGS+=("$1")
            shift
            ;;
    esac
done

REAL_CLAUDE=$(find_real_claude)
if [[ -z "$REAL_CLAUDE" || ! -x "$REAL_CLAUDE" ]]; then
    echo "❌ Could not find real Claude binary" >&2
    exit 1
fi

# CAAM bypass
PARENT_CMD=$(ps -o comm= -p $PPID 2>/dev/null || echo "unknown")
if [[ "$PARENT_CMD" == *"caam"* ]] || [[ "${CAAM_WRAPPER_DISABLE:-}" == "1" ]]; then
    exec_claude "$REAL_CLAUDE" "${NEW_ARGS[@]}"
fi

# Profile selection
GC_KEY="${GC_AGENT:-${GC_SESSION_NAME:-}}"
# Prefer fresher usage when this is an ephemeral pool worker spawn.
CEILING_POOL_MODE=0
if [[ -n "$GC_KEY" ]] && is_pool_spawn "$GC_KEY"; then
    CEILING_POOL_MODE=1
fi

# Ceiling protect wins over every other selection path (force, override,
# hash-pin, LB-disabled, weighted). Under the ceiling, normal rules apply.
if try_apply_ceiling_protect "$CEILING_POOL_MODE" "${GC_KEY:-interactive}"; then
    :
elif [[ -n "$FORCE_PROFILE" ]]; then
    SELECTED_DIR="$BASE_DIR/$FORCE_PROFILE"
    echo "🔑 [Master Wrapper] Force → $FORCE_PROFILE" >&2
elif [[ -n "$GC_KEY" ]]; then
    OVERRIDE_PROFILE=$(read_agent_override "$GC_KEY" 2>/dev/null || true)
    if [[ -n "${OVERRIDE_PROFILE:-}" ]]; then
        SELECTED_DIR="$(profile_dir "$OVERRIDE_PROFILE")"
        echo "🔑 [Master Wrapper] GC override $GC_KEY → $OVERRIDE_PROFILE" >&2
    elif is_pool_spawn "$GC_KEY"; then
        apply_balanced_selection "GC pool $GC_KEY" 1
    else
        SELECTED_DIR="$(profile_dir "$(hash_profile_for_agent "$GC_KEY")")"
        echo "🔑 [Master Wrapper] GC_AGENT=$GC_KEY → $(basename "$SELECTED_DIR")" >&2
    fi
elif [[ "${CLAUDE_LB_DISABLE:-}" == "1" ]]; then
    PID=$$
    HASH=$((PID + RANDOM))
    if [ $((HASH % 2)) -eq 0 ]; then
        SELECTED_DIR="$DIR_A"
    else
        SELECTED_DIR="$DIR_B"
    fi
    echo "🔑 [Master Wrapper] LB disabled PID=$PID → $(basename "$SELECTED_DIR")" >&2
else
    apply_balanced_selection "LB"
fi

mkdir -p "$SELECTED_DIR"

# Seed config
if [[ ! -f "$SELECTED_DIR/.claude.json" ]] || ! grep -q hasCompletedOnboarding "$SELECTED_DIR/.claude.json" 2>/dev/null; then
    cat > "$SELECTED_DIR/.claude.json" << 'EOC'
{
  "hasCompletedOnboarding": true,
  "ccOnboardingFlags": {},
  "theme": "dark",
  "env": { "DISABLE_AUTOUPDATER": "1" }
}
EOC
    chmod 600 "$SELECTED_DIR/.claude.json"
fi

export CLAUDE_CONFIG_DIR="$SELECTED_DIR"

exec_claude "$REAL_CLAUDE" "${NEW_ARGS[@]}"