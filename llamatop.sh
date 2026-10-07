#!/usr/bin/env bash
set -u

# ---------------------------------------------------------------------------
# llamatop.sh
#
# Usage:
#   ~/llamatop.sh [BASE_URL] [API_KEY] [INTERVAL] [MODEL]
#
# Your setup:
#   ~/llamatop.sh http://127.0.0.1:6767 jan 2
#
# Optional fixed model:
#   ~/llamatop.sh http://127.0.0.1:6767 jan 2 Qwen3_8-27B-UD-Q6_K_XL
#
# Environment:
#   SHOW_ALL_METRICS=0   hide raw metric table
#   HISTORY_LEN=30       sparkline history length
#
# Keys:
#   q     quit
# ---------------------------------------------------------------------------

BASE="${1:-http://127.0.0.1:6767}"
API_KEY="${2:-}"
INTERVAL="${3:-2}"
PINNED_MODEL="${4:-}"

BASE="${BASE%/}"

HISTORY_LEN="${HISTORY_LEN:-30}"
SHOW_ALL_METRICS="${SHOW_ALL_METRICS:-1}"

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

for cmd in curl jq awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing dependency: $cmd"
        echo
        echo "Install with:"
        echo "  sudo apt update"
        echo "  sudo apt install -y curl jq gawk"
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Terminal setup
# ---------------------------------------------------------------------------

# Save terminal state, enter alternate screen, hide cursor
printf '\0337'
printf '\033[?1049h'
printf '\033[?25l'

cleanup() {
    # Show cursor, leave alternate screen, restore terminal state
    printf '\033[?25h'
    printf '\033[?1049l'
    printf '\0338'
}

trap cleanup EXIT INT TERM

clear_screen() {
    # Move home and erase from cursor to end of screen.
    # This is friendlier to alternate-screen terminals than normal "clear".
    printf '\033[H\033[J'
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

curl_args=(
    -fsS
    --connect-timeout 2
    --max-time 4
)

if [[ -n "$API_KEY" ]]; then
    curl_args+=(
        -H "Authorization: Bearer $API_KEY"
    )
fi

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

declare -A prev=()
declare -A curr=()

gen_hist=()
prompt_hist=()
ctx_hist=()
mtp_hist=()

last_model=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

urlencode() {
    jq -nr --arg x "$1" '$x | @uri'
}

push_hist() {
    local name="$1"
    local value="$2"
    local size

    eval "$name+=(\"\$value\")"
    eval "size=\${#$name[@]}"

    if (( size > HISTORY_LEN )); then
        eval "$name=(\"\${$name[@]:1}\")"
    fi
}

spark() {
    if (( $# == 0 )); then
        printf '-'
        return
    fi

    awk '
    BEGIN {
        blocks[0]="▁"
        blocks[1]="▂"
        blocks[2]="▃"
        blocks[3]="▄"
        blocks[4]="▅"
        blocks[5]="▆"
        blocks[6]="▇"
        blocks[7]="█"

        min = ARGV[1] + 0
        max = min

        for (i = 1; i < ARGC; i++) {
            v[i] = ARGV[i] + 0

            if (v[i] < min) min = v[i]
            if (v[i] > max) max = v[i]
        }

        # Entire history is zero
        if (min == 0 && max == 0) {
            for (i = 1; i < ARGC; i++)
                printf "·"
            exit
        }

        range = max - min

        for (i = 1; i < ARGC; i++) {
            if (range == 0)
                idx = 3
            else
                idx = int(((ARGV[i] - min) / range) * 7)

            if (idx < 0) idx = 0
            if (idx > 7) idx = 7

            printf "%s", blocks[idx]
        }
    }' "$@"
}

metric() {
    local name="$1"
    printf '%s' "${curr[$name]:-0}"
}

fetch_models() {
    curl "${curl_args[@]}" "$BASE/models" 2>/dev/null
}

auto_model() {
    local json="$1"

    jq -r '
        [
            .data[]?
            | select(.status.value == "loaded")
            | .id
        ]
        | if length > 0
          then .[0]
          else empty
          end
    ' <<< "$json"
}

check_keypress() {
    local key=""

    # Non-blocking read. q quits.
    if read -rsn1 -t 0.01 key 2>/dev/null; then
        case "$key" in
            q|Q)
                exit 0
                ;;
        esac
    fi
}

responsive_sleep() {
    local total="$1"
    local elapsed=0
    local step=0.1

    while awk -v e="$elapsed" -v t="$total" 'BEGIN { exit !(e < t) }'; do
        check_keypress
        sleep "$step"

        elapsed="$(
            awk -v e="$elapsed" -v s="$step" '
            BEGIN { printf "%.2f", e+s }
            '
        )"
    done
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

while true; do

    check_keypress

    # -----------------------------------------------------------------------
    # Discover models
    # -----------------------------------------------------------------------

    MODELS="$(fetch_models || true)"

    if ! jq -e '.data' >/dev/null 2>&1 <<< "$MODELS"; then
        clear_screen

        echo "llamatop   $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        echo "Cannot read:"
        echo
        echo "  $BASE/models"
        echo

        if [[ -n "$API_KEY" ]]; then
            echo "Check:"
            echo "  • Jan is running"
            echo "  • API key is correct"
            echo "  • WSL can reach the Windows host"
        else
            echo "If authentication is enabled, provide the API key."
        fi

        echo
        echo "Press q to quit."

        responsive_sleep "$INTERVAL"
        continue
    fi

    # -----------------------------------------------------------------------
    # Select model
    # -----------------------------------------------------------------------

    if [[ -n "$PINNED_MODEL" ]]; then
        MODEL="$PINNED_MODEL"
        MODEL_MODE="pinned"
    else
        MODEL="$(auto_model "$MODELS")"
        MODEL_MODE="auto"
    fi

    if [[ -z "$MODEL" ]]; then
        clear_screen

        echo "llamatop   $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Server: $BASE"
        echo
        echo "No model is currently loaded."
        echo
        echo "Router models:"
        echo

        jq -r '
            .data[]?
            | "  \(.status.value // "?")\t\(.id)"
        ' <<< "$MODELS"

        echo
        echo "Waiting for a model..."
        echo "Press q to quit."

        responsive_sleep "$INTERVAL"
        continue
    fi

    # Reset charts when model changes
    if [[ "$MODEL" != "$last_model" ]]; then
        prev=()
        curr=()

        gen_hist=()
        prompt_hist=()
        ctx_hist=()
        mtp_hist=()

        last_model="$MODEL"
    fi

    MODEL_Q="$(urlencode "$MODEL")"

    METRICS_URL="${BASE}/metrics?model=${MODEL_Q}&autoload=false"
    SLOTS_URL="${BASE}/slots?model=${MODEL_Q}&autoload=false"

    # -----------------------------------------------------------------------
    # Fetch /metrics and /slots
    # -----------------------------------------------------------------------

    METRICS="$(
        curl "${curl_args[@]}" "$METRICS_URL" 2>/dev/null || true
    )"

    SLOTS="$(
        curl "${curl_args[@]}" "$SLOTS_URL" 2>/dev/null || true
    )"

    if [[ -z "$METRICS" || "$METRICS" == \{* ]]; then
        clear_screen

        echo "llamatop   $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        echo "Model:"
        echo "  $MODEL"
        echo
        echo "Could not read:"
        echo "  $METRICS_URL"
        echo
        echo "Enable llama.cpp metrics BEFORE starting Jan:"
        echo
        echo 'PowerShell:'
        echo
        echo '  $env:LLAMA_ARG_ENDPOINT_METRICS="true"'
        echo '  jan serve MODEL -v --port 6767 --api-key jan'
        echo
        echo "Test manually:"
        echo
        echo "  curl -H 'Authorization: Bearer jan' \\"
        echo "    '$METRICS_URL'"
        echo
        echo "Press q to quit."

        responsive_sleep "$INTERVAL"
        continue
    fi

    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$SLOTS"; then
        SLOTS='[]'
    fi

    # -----------------------------------------------------------------------
    # Parse Prometheus metrics
    # -----------------------------------------------------------------------

    curr=()

    while IFS= read -r line; do

        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue

        key="${line%%[[:space:]]*}"

        rest="${line#*[[:space:]]}"
        val="${rest%%[[:space:]]*}"

        if [[ "$val" =~ ^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]]; then
            curr["$key"]="$val"
        fi

    done <<< "$METRICS"

    # -----------------------------------------------------------------------
    # Main performance stats
    # -----------------------------------------------------------------------

    GEN_TPS="$(metric 'llamacpp:predicted_tokens_seconds')"
    PROMPT_TPS="$(metric 'llamacpp:prompt_tokens_seconds')"

    PROCESSING="$(metric 'llamacpp:requests_processing')"
    DEFERRED="$(metric 'llamacpp:requests_deferred')"

    PROMPT_TOTAL="$(metric 'llamacpp:prompt_tokens_total')"
    GENERATED_TOTAL="$(metric 'llamacpp:tokens_predicted_total')"

    # Maximum token occupancy observed by llama.cpp.
    # IMPORTANT: this is NOT exact live context occupancy.
    CTX_HI="$(metric 'llamacpp:n_tokens_max')"

    # -----------------------------------------------------------------------
    # MTP / speculative stats
    # -----------------------------------------------------------------------

    DRAFT="$(metric 'llamacpp:spec_decode_num_draft_tokens_total')"
    ACCEPTED="$(metric 'llamacpp:spec_decode_num_accepted_tokens_total')"
    DRAFT_STEPS="$(metric 'llamacpp:spec_decode_num_drafts_total')"

    MTP_TOTAL="$(
        awk \
            -v a="$ACCEPTED" \
            -v d="$DRAFT" '
        BEGIN {
            if (d > 0)
                printf "%.1f", 100*a/d
            else
                printf "0.0"
        }'
    )"

    MTP_INTERVAL="-"

    if [[ -n "${prev[llamacpp:spec_decode_num_draft_tokens_total]+x}" ]]; then

        OLD_DRAFT="${prev[llamacpp:spec_decode_num_draft_tokens_total]}"
        OLD_ACCEPTED="${prev[llamacpp:spec_decode_num_accepted_tokens_total]:-0}"

        MTP_INTERVAL="$(
            awk \
                -v d="$DRAFT" \
                -v od="$OLD_DRAFT" \
                -v a="$ACCEPTED" \
                -v oa="$OLD_ACCEPTED" '
            BEGIN {
                dd = d-od
                da = a-oa

                if (dd > 0)
                    printf "%.1f", 100*da/dd
                else
                    printf "-"
            }'
        )"
    fi

    # -----------------------------------------------------------------------
    # Context capacity from slots
    # -----------------------------------------------------------------------

    SLOT_CTX_MAX="$(
        jq '
            [.[].n_ctx // 0]
            | max // 0
        ' <<< "$SLOTS"
    )"

    CTX_PCT="$(
        awk \
            -v used="$CTX_HI" \
            -v max="$SLOT_CTX_MAX" '
        BEGIN {
            if (max > 0)
                printf "%.1f", 100*used/max
            else
                printf "0.0"
        }'
    )"

    # -----------------------------------------------------------------------
    # Histories
    # -----------------------------------------------------------------------

    push_hist gen_hist "$GEN_TPS"
    push_hist prompt_hist "$PROMPT_TPS"
    push_hist ctx_hist "$CTX_PCT"

    if [[ "$MTP_INTERVAL" != "-" ]]; then
        push_hist mtp_hist "$MTP_INTERVAL"
    fi

    # -----------------------------------------------------------------------
    # Render
    # -----------------------------------------------------------------------

    clear_screen

    echo "════════════════════════════════════════════════════════════════════════════════"
    echo " llamatop — Jan / llama.cpp                    $(date '+%Y-%m-%d %H:%M:%S')"
    echo "════════════════════════════════════════════════════════════════════════════════"

    printf " Model        %s  [%s]\n" "$MODEL" "$MODEL_MODE"
    printf " Server       %s\n" "$BASE"

    echo

    printf " Generation   %9.2f tok/s   " "$GEN_TPS"
    spark "${gen_hist[@]}"
    echo

    printf " Prompt       %9.2f tok/s   " "$PROMPT_TPS"
    spark "${prompt_hist[@]}"
    echo

    printf " Requests     processing=%s  queued=%s\n" \
        "$PROCESSING" \
        "$DEFERRED"

    printf " Tokens       prompt=%s  generated=%s\n" \
        "$PROMPT_TOTAL" \
        "$GENERATED_TOTAL"

    echo

    printf " Context HI   %9s / %-9s  %5.1f%%   " \
        "$CTX_HI" \
        "$SLOT_CTX_MAX" \
        "$CTX_PCT"

    spark "${ctx_hist[@]}"
    echo

    echo "              high-water mark; not exact live KV/context occupancy"

    # -----------------------------------------------------------------------
    # MTP section
    # -----------------------------------------------------------------------

    echo

    if awk -v d="$DRAFT" 'BEGIN {exit !(d > 0)}'; then

        printf " MTP total    %8.1f%%   accepted=%s / draft=%s   steps=%s\n" \
            "$MTP_TOTAL" \
            "$ACCEPTED" \
            "$DRAFT" \
            "$DRAFT_STEPS"

        if [[ "$MTP_INTERVAL" != "-" ]]; then
            printf " MTP recent   %8s%%   " "$MTP_INTERVAL"

            spark "${mtp_hist[@]}"
            echo
        fi

    else
        echo " MTP          no speculative tokens recorded"
    fi

    # -----------------------------------------------------------------------
    # Slots
    # -----------------------------------------------------------------------

    echo
    echo "────────────────────────────────── SLOTS ───────────────────────────────────────"

    printf "%-4s %-8s %-7s %-9s %-6s %-8s %-8s %-8s %-7s %-7s %-7s\n" \
        "ID" \
        "STATE" \
        "TASK" \
        "CTX CAP" \
        "SPEC" \
        "DECODED" \
        "REMAIN" \
        "MAXOUT" \
        "TEMP" \
        "TOP_P" \
        "NMAX"

    printf '%*s\n' 94 '' | tr ' ' '-'

    jq -r '
        .[] |

        [
            (.id // "?"),

            (
                if .is_processing
                then "RUNNING"
                else "idle"
                end
            ),

            (.id_task // "-"),

            (.n_ctx // "-"),

            (
                if .speculative
                then "yes"
                else "no"
                end
            ),

            (.next_token.n_decoded // 0),

            (.next_token.n_remain // "-"),

            (
                .params.max_tokens
                // .params.n_predict
                // "-"
            ),

            (.params.temperature // "-"),

            (.params.top_p // "-"),

            (
                .params["speculative.n_max"]
                // "-"
            )
        ]

        | @tsv
    ' <<< "$SLOTS" |

    while IFS=$'\t' read -r \
        id \
        state \
        task \
        ctx \
        spec \
        decoded \
        remain \
        maxout \
        temp \
        topp \
        nmax
    do

        printf "%-4s %-8s %-7s %-9s %-6s %-8s %-8s %-8s %-7s %-7s %-7s\n" \
            "$id" \
            "$state" \
            "$task" \
            "$ctx" \
            "$spec" \
            "$decoded" \
            "$remain" \
            "$maxout" \
            "$temp" \
            "$topp" \
            "$nmax"

    done

    # -----------------------------------------------------------------------
    # Active request details
    # -----------------------------------------------------------------------

    echo
    echo "──────────────────────────── ACTIVE SLOT DETAILS ───────────────────────────────"

    ACTIVE_DETAILS="$(
        jq -r '
            .[]
            | select(.is_processing == true)

            |

            "slot \(.id): " +
            "min_p=\(.params.min_p // "-")  " +
            "top_k=\(.params.top_k // "-")  " +
            "reasoning=\(.params.reasoning_format // "-")  " +
            "spec_nmin=\(.params["speculative.n_min"] // "-")  " +
            "spec_pmin=\(.params["speculative.p_min"] // "-")"
        ' <<< "$SLOTS"
    )"

    if [[ -n "$ACTIVE_DETAILS" ]]; then
        printf '%s\n' "$ACTIVE_DETAILS"
    else
        echo "(no active request)"
    fi

    # -----------------------------------------------------------------------
    # Raw /metrics table
    # -----------------------------------------------------------------------

    if [[ "$SHOW_ALL_METRICS" == "1" ]]; then

        echo
        echo "────────────────────────────── ALL /metrics ───────────────────────────────────"

        printf "%-68s %14s %3s %12s %12s\n" \
            "METRIC" \
            "VALUE" \
            "" \
            "DELTA" \
            "RATE/s"

        printf '%*s\n' 113 '' | tr ' ' '-'

        while IFS= read -r key; do

            [[ -z "$key" ]] && continue

            val="${curr[$key]}"

            if [[ -n "${prev[$key]+x}" ]]; then

                old="${prev[$key]}"

                read -r delta rate arrow <<< "$(
                    awk \
                        -v new="$val" \
                        -v old="$old" \
                        -v interval="$INTERVAL" '
                    BEGIN {
                        d = new-old

                        if (d > 0)
                            arrow="↑"
                        else if (d < 0)
                            arrow="↓"
                        else
                            arrow="→"

                        if (d < 0 && old > 0)
                            printf "reset reset ↺"
                        else
                            printf "%.5g %.5g %s", d, d/interval, arrow
                    }'
                )"

                printf "%-68.68s %14.6g %3s %12s %12s\n" \
                    "$key" \
                    "$val" \
                    "$arrow" \
                    "$delta" \
                    "$rate"

            else

                printf "%-68.68s %14.6g %3s %12s %12s\n" \
                    "$key" \
                    "$val" \
                    "·" \
                    "-" \
                    "-"

            fi

        done < <(
            printf '%s\n' "${!curr[@]}" |
            sort
        )
    fi

    echo
    echo " q = quit"

    # -----------------------------------------------------------------------
    # Preserve counters for next interval
    # -----------------------------------------------------------------------

    prev=()

    for key in "${!curr[@]}"; do
        prev["$key"]="${curr[$key]}"
    done

    responsive_sleep "$INTERVAL"
done
