# claude-lb-usage.sh — shared usage cache for claude-wrapper + gc-balance
# Fast path: Anthropic OAuth /api/oauth/usage (~0.5s/profile, parallel OK)
# Fallback: claude -p /stats (~2s/profile) when OAuth token missing/expired

: "${LB_BASE_DIR:=$HOME/.claude-profiles}"
: "${LB_CACHE_FILE:=$LB_BASE_DIR/.lb-cache}"
: "${LB_LOCK_FILE:=$LB_BASE_DIR/.lb-cache.lock}"
: "${LB_CACHE_TTL:=${CLAUDE_LB_CACHE_TTL:-30}}"
: "${LB_POOL_MAX_STALE:=${CLAUDE_LB_POOL_MAX_STALE:-15}}"
: "${LB_REFRESH_TIMEOUT:=${CLAUDE_LB_REFRESH_TIMEOUT:-12}}"
: "${LB_POOL_FORCE_FILE:=$LB_BASE_DIR/pool-force}"
: "${LB_USAGE_CORRECTION_FILE:=$LB_BASE_DIR/usage-correction}"

# Temporary override: force all pool spawns to A or B.
# Env CLAUDE_LB_POOL_FORCE wins over ~/.claude-profiles/pool-force file.
lb_read_pool_force() {
    local val="${CLAUDE_LB_POOL_FORCE:-}"
    if [[ "$val" == "A" || "$val" == "B" ]]; then
        printf '%s' "$val"
        return 0
    fi
    [[ -f "$LB_POOL_FORCE_FILE" ]] || return 1
    val=$(grep -E '^[AB]$' "$LB_POOL_FORCE_FILE" 2>/dev/null | tail -1)
    if [[ "$val" == "A" || "$val" == "B" ]]; then
        printf '%s' "$val"
        return 0
    fi
    return 1
}

lb_set_pool_force() {
    local profile=$1
    [[ "$profile" == "A" || "$profile" == "B" ]] || return 1
    mkdir -p "$LB_BASE_DIR"
    printf '%s\n' "$profile" > "$LB_POOL_FORCE_FILE"
    chmod 600 "$LB_POOL_FORCE_FILE"
}

lb_clear_pool_force() {
    rm -f "$LB_POOL_FORCE_FILE"
}

# Usage % correction per profile for LB skew (effective = raw + correction).
# File ~/.claude-profiles/usage-correction (A=N / B=N lines).
# Env CLAUDE_LB_CORRECTION_A / CLAUDE_LB_CORRECTION_B override per profile.
lb_read_usage_correction_file() {
    local profile=$1
    local default=${2:-0}
    [[ -f "$LB_USAGE_CORRECTION_FILE" ]] || {
        printf '%s' "$default"
        return 0
    }
    local val
    val=$(grep -E "^${profile}=-?[0-9]+$" "$LB_USAGE_CORRECTION_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
    printf '%s' "${val:-$default}"
}

lb_read_usage_corrections_from_file() {
    local corr_a corr_b
    corr_a=$(lb_read_usage_correction_file A 0)
    corr_b=$(lb_read_usage_correction_file B 0)
    printf '%s %s\n' "$corr_a" "$corr_b"
}

lb_read_usage_corrections() {
    local corr_a corr_b
    if [[ -n "${CLAUDE_LB_CORRECTION_A+x}" ]]; then
        corr_a="$CLAUDE_LB_CORRECTION_A"
    else
        corr_a=$(lb_read_usage_correction_file A 0)
    fi
    if [[ -n "${CLAUDE_LB_CORRECTION_B+x}" ]]; then
        corr_b="$CLAUDE_LB_CORRECTION_B"
    else
        corr_b=$(lb_read_usage_correction_file B 0)
    fi
    [[ "$corr_a" =~ ^-?[0-9]+$ ]] || corr_a=0
    [[ "$corr_b" =~ ^-?[0-9]+$ ]] || corr_b=0
    printf '%s %s\n' "$corr_a" "$corr_b"
}

lb_set_usage_correction() {
    local profile=$1 val=$2
    [[ "$profile" == "A" || "$profile" == "B" ]] || return 1
    [[ "$val" =~ ^-?[0-9]+$ ]] || return 1
    local corr_a corr_b
    read -r corr_a corr_b < <(lb_read_usage_corrections_from_file)
    case "$profile" in
        A) corr_a=$val ;;
        B) corr_b=$val ;;
    esac
    mkdir -p "$LB_BASE_DIR"
    {
        printf 'A=%s\n' "$corr_a"
        printf 'B=%s\n' "$corr_b"
    } > "$LB_USAGE_CORRECTION_FILE"
    chmod 600 "$LB_USAGE_CORRECTION_FILE"
}

lb_clear_usage_corrections() {
    rm -f "$LB_USAGE_CORRECTION_FILE"
}

# Salt for deterministic hash-pin of non-pool agents.
# Priority: CLAUDE_PROFILE_HASH_SALT (explicit) → basename(GC_CITY_PATH) →
# basename(CITY) (gc-balance) → empty (legacy agent-only hash).
hash_salt_for_profile() {
    if [[ -n "${CLAUDE_PROFILE_HASH_SALT:-}" ]]; then
        printf '%s' "$CLAUDE_PROFILE_HASH_SALT"
        return 0
    fi
    local city="${GC_CITY_PATH:-${CITY:-}}"
    if [[ -n "$city" ]]; then
        city="${city%/}"
        printf '%s' "${city##*/}"
        return 0
    fi
    printf ''
}

# Hash-pin profile for named/infrastructure agents. Material is
#   "${salt}:${agent}" when salt is non-empty, else "${agent}".
# Salt defaults to basename of GC_CITY_PATH so each city gets its own
# pin lottery (gasburger.* names no longer inherit gastown pin maps).
hash_profile_for_agent() {
    local agent=$1
    local salt material hash
    salt=$(hash_salt_for_profile)
    if [[ -n "$salt" ]]; then
        material="${salt}:${agent}"
    else
        material="$agent"
    fi
    hash=$(printf '%s' "$material" | cksum | cut -d' ' -f1)
    if [ $((hash % 2)) -eq 0 ]; then
        printf 'A'
    else
        printf 'B'
    fi
}

lb_profile_dir() {
    case "$1" in
        A) printf '%s' "$LB_BASE_DIR/A" ;;
        B) printf '%s' "$LB_BASE_DIR/B" ;;
        *) return 1 ;;
    esac
}

lb_find_real_claude() {
    ls -t "$HOME/.local/share/claude/versions"/2.* 2>/dev/null | head -n 1
}

lb_read_meta() {
    local key=$1
    [[ -f "$LB_CACHE_FILE" ]] || return 1
    grep -E "^${key}=" "$LB_CACHE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

lb_read_usage_cache() {
    local profile=$1
    lb_read_meta "usage_${profile}"
}

lb_cache_age() {
    local cached_at now
    [[ -f "$LB_CACHE_FILE" ]] || return 1
    cached_at=$(grep '^cached_at=' "$LB_CACHE_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
    [[ "$cached_at" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s)
    printf '%s' "$(( now - cached_at ))"
}

lb_cache_is_fresh() {
    local age
    age=$(lb_cache_age 2>/dev/null || echo 999999)
    (( age < LB_CACHE_TTL ))
}

lb_parse_weekly_usage_pct() {
    sed -n 's/.*Current week (all models): \([0-9][0-9]*\)%.*/\1/p' | head -1
}

# OAuth usage API — same source TeamClaude/ccflare proxies use for quota probes.
lb_fetch_oauth_usage_pct() {
    local profile=$1
    local dir pct
    dir=$(lb_profile_dir "$profile") || return 1
    [[ -f "$dir/.credentials.json" ]] || return 1
    pct=$(python3 - "$dir" <<'PY' 2>/dev/null || true
import json, sys, urllib.request

dir_path = sys.argv[1]
try:
    with open(f"{dir_path}/.credentials.json") as f:
        oauth = json.load(f).get("claudeAiOauth") or {}
    token = oauth.get("accessToken")
    if not token:
        raise SystemExit(1)
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode())
    for lim in data.get("limits") or []:
        if lim.get("kind") == "weekly_all":
            pct = lim.get("percent")
            if pct is not None:
                print(int(float(pct)))
                raise SystemExit(0)
    sd = data.get("seven_day") or {}
    util = sd.get("utilization")
    if util is not None:
        print(int(float(util)))
        raise SystemExit(0)
    raise SystemExit(1)
except Exception:
    raise SystemExit(1)
PY
)
    [[ -n "${pct:-}" ]] || return 1
    printf '%s' "$pct"
}

lb_fetch_stats_usage_pct() {
    local profile=$1 real=$2
    local output pct
    [[ -n "$real" && -x "$real" ]] || return 1
    output=$(CLAUDE_CONFIG_DIR="$(lb_profile_dir "$profile")" \
        timeout "$LB_REFRESH_TIMEOUT" "$real" --no-session-persistence -p "/stats" 2>/dev/null) || return 1
    pct=$(printf '%s\n' "$output" | lb_parse_weekly_usage_pct)
    [[ -n "${pct:-}" ]] || return 1
    printf '%s' "$pct"
}

lb_fetch_profile_usage_pct() {
    local profile=$1 real=${2:-}
    local pct
    pct=$(lb_fetch_oauth_usage_pct "$profile") && { printf '%s' "$pct"; return 0; }
    pct=$(lb_fetch_stats_usage_pct "$profile" "$real") && { printf '%s' "$pct"; return 0; }
    return 1
}

lb_write_usage_cache() {
    local usage_a=$1 usage_b=$2 source=${3:-oauth}
    local refresh_meta tmp
    refresh_meta=$(lb_read_meta refresh_source 2>/dev/null || echo "")
    tmp="$LB_CACHE_FILE.tmp.$$"
    cat > "$tmp" <<EOF
cached_at=$(date +%s)
usage_A=$usage_a
usage_B=$usage_b
refresh_source=$source
EOF
    if [[ -n "$refresh_meta" && "$refresh_meta" != "$source" ]]; then
        : # keep latest source only
    fi
    mv -f "$tmp" "$LB_CACHE_FILE"
}

# Parallel OAuth fetch; flock so only one refresher runs at a time.
lb_refresh_usage_cache() {
    local real=${1:-}; local force=${2:-0}
    local usage_a="" usage_b="" source="oauth"
    local tmp_a tmp_b

    mkdir -p "$LB_BASE_DIR"
    exec 9>"$LB_LOCK_FILE"
    if ! flock -w "$LB_REFRESH_TIMEOUT" 9; then
        return 1
    fi
    if (( ! force )) && lb_cache_is_fresh; then
        return 0
    fi

    tmp_a="${LB_CACHE_FILE}.fetch.A.$$"
    tmp_b="${LB_CACHE_FILE}.fetch.B.$$"
    lb_fetch_oauth_usage_pct A >"$tmp_a" 2>/dev/null &
    local pid_a=$!
    lb_fetch_oauth_usage_pct B >"$tmp_b" 2>/dev/null &
    local pid_b=$!
    wait "$pid_a" 2>/dev/null || true
    wait "$pid_b" 2>/dev/null || true
    [[ -s "$tmp_a" ]] && usage_a=$(<"$tmp_a")
    [[ -s "$tmp_b" ]] && usage_b=$(<"$tmp_b")
    rm -f "$tmp_a" "$tmp_b"

    if [[ -z "$usage_a" || -z "$usage_b" ]]; then
        source="stats"
        real=${real:-$(lb_find_real_claude)}
        if [[ -n "$real" && -x "$real" ]]; then
            [[ -z "$usage_a" ]] && usage_a=$(lb_fetch_stats_usage_pct A "$real" || echo "")
            [[ -z "$usage_b" ]] && usage_b=$(lb_fetch_stats_usage_pct B "$real" || echo "")
        fi
    fi

    if [[ -z "$usage_a" && -z "$usage_b" ]]; then
        return 1
    fi
    usage_a=${usage_a:-$(lb_read_usage_cache A || echo 0)}
    usage_b=${usage_b:-$(lb_read_usage_cache B || echo 0)}
    lb_write_usage_cache "$usage_a" "$usage_b" "$source"
}

# pool_mode=1: block for fresh data when cache is older than LB_POOL_MAX_STALE.
lb_load_usage_snapshot() {
    local real=${1:-}; local pool_mode=${2:-0}
    local usage_a usage_b age

    usage_a=$(lb_read_usage_cache A 2>/dev/null || echo "")
    usage_b=$(lb_read_usage_cache B 2>/dev/null || echo "")

    if lb_cache_is_fresh && [[ -n "$usage_a" && -n "$usage_b" ]]; then
        printf '%s %s\n' "$usage_a" "$usage_b"
        return 0
    fi

    age=$(lb_cache_age 2>/dev/null || echo 999999)
    if (( pool_mode )) && (( age > LB_POOL_MAX_STALE )); then
        lb_refresh_usage_cache "$real" 1 || true
        usage_a=$(lb_read_usage_cache A || echo 0)
        usage_b=$(lb_read_usage_cache B || echo 0)
        printf '%s %s\n' "$usage_a" "$usage_b"
        return 0
    fi

    if [[ -n "$usage_a" && -n "$usage_b" ]]; then
        ( lb_refresh_usage_cache "$real" 0 ) >/dev/null 2>&1 &
        printf '%s %s\n' "$usage_a" "$usage_b"
        return 0
    fi

    lb_refresh_usage_cache "$real" 1 || true
    usage_a=$(lb_read_usage_cache A || echo 0)
    usage_b=$(lb_read_usage_cache B || echo 0)
    printf '%s %s\n' "$usage_a" "$usage_b"
}