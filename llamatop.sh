#!/usr/bin/env bash
set -u

# ============================================================================
# llamatop.sh
#
# Jan / llama.cpp router monitor
#
# DASHBOARD:
#   ~/llamatop.sh http://127.0.0.1:6767 jan 2
#
# RAW ENDPOINT DUMP, ONCE:
#   ~/llamatop.sh http://127.0.0.1:6767 jan 2 --raw
#
# RAW ENDPOINT DUMP, REPEATED:
#   ~/llamatop.sh http://127.0.0.1:6767 jan 2 --raw-watch
#
# PIN A MODEL:
#   ~/llamatop.sh http://127.0.0.1:6767 jan 2 Qwen3_8-27B-UD-Q6_K_XL
#
# PIN + RAW:
#   ~/llamatop.sh http://127.0.0.1:6767 jan 2 \
#       Qwen3_8-27B-UD-Q6_K_XL --raw
#
# Optional:
#   SHOW_ALL_METRICS=0 ~/llamatop.sh ...
#   HISTORY_LEN=30 ~/llamatop.sh ...
#
# Keys in dashboard:
#   q = quit
# ============================================================================

BASE="${1:-http://127.0.0.1:6767}"
API_KEY="${2:-}"
INTERVAL="${3:-2}"

BASE="${BASE%/}"

PINNED_MODEL=""
MODE="dashboard"

for arg in "${@:4}"; do
    case "$arg" in
        --raw)
            MODE="raw"
            ;;
        --raw-watch)
            MODE="raw-watch"
            ;;
        *)
            if [[ -z "$PINNED_MODEL" ]]; then
                PINNED_MODEL="$arg"
            fi
            ;;
    esac
done

HISTORY_LEN="${HISTORY_LEN:-30}"
SHOW_ALL_METRICS="${SHOW_ALL_METRICS:-1}"

# ============================================================================
# Dependencies
# ============================================================================

for cmd in curl jq awk date; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing dependency: $cmd"
        echo
        echo "Install with:"
        echo "  sudo apt update"
        echo "  sudo apt install -y curl jq gawk"
        exit 1
    fi
done

# ============================================================================
# Temporary files / cleanup
# ============================================================================

TMP_DIR="$(mktemp -d)"
ALT_SCREEN=0

cleanup() {
    if [[ "$ALT_SCREEN" == "1" ]]; then
        printf '\033[?25h'
        printf '\033[?1049l'
    fi

    rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# ============================================================================
# HTTP
# ============================================================================

curl_args=(
    -sS
    --connect-timeout 2
    --max-time 5
)

if [[ -n "$API_KEY" ]]; then
    curl_args+=(
        -H "Authorization: Bearer $API_KEY"
    )
fi

HTTP_CODE=""
HTTP_BODY=""
HTTP_ERROR=""
HTTP_RC=0

http_get() {
    local url="$1"
    local body_file="$TMP_DIR/body"
    local err_file="$TMP_DIR/error"

    : > "$body_file"
    : > "$err_file"

    HTTP_CODE="$(
        curl "${curl_args[@]}" \
            -o "$body_file" \
            -w '%{http_code}' \
            "$url" \
            2>"$err_file"
    )"

    HTTP_RC=$?

    HTTP_BODY="$(cat "$body_file")"
    HTTP_ERROR="$(cat "$err_file")"

    [[ -z "$HTTP_CODE" ]] && HTTP_CODE="000"
}

# ============================================================================
# Common helpers
# ============================================================================

urlencode() {
    jq -nr --arg x "$1" '$x | @uri'
}

detect_model() {
    local models="$1"

    if [[ -n "$PINNED_MODEL" ]]; then
        printf '%s' "$PINNED_MODEL"
        return
    fi

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
    ' <<< "$models"
}

# ============================================================================
# RAW MODE
# ============================================================================

raw_snapshot() {
    local model=""
    local model_q=""

    echo "==============================================================================="
    echo "llamatop RAW    $(date '+%Y-%m-%d %H:%M:%S.%3N')"
    echo "==============================================================================="
    echo

    # ------------------------------------------------------------------------
    # /models
    # ------------------------------------------------------------------------

    echo ">>> GET $BASE/models"

    http_get "$BASE/models"

    echo "HTTP $HTTP_CODE"

    if [[ -n "$HTTP_ERROR" ]]; then
        echo "curl stderr:"
        printf '%s\n' "$HTTP_ERROR"
    fi

    echo
    printf '%s\n' "$HTTP_BODY"
    echo

    if [[ "$HTTP_CODE" != "200" ]]; then
        echo "Cannot continue without /models."
        return
    fi

    model="$(detect_model "$HTTP_BODY")"

    if [[ -z "$model" ]]; then
        echo "No loaded model detected."
        return
    fi

    model_q="$(urlencode "$model")"

    echo "Detected model:"
    echo "  $model"
    echo

    # ------------------------------------------------------------------------
    # /metrics
    # ------------------------------------------------------------------------

    local metrics_url
    metrics_url="$BASE/metrics?model=$model_q&autoload=false"

    echo ">>> GET $metrics_url"

    http_get "$metrics_url"

    echo "HTTP $HTTP_CODE"

    if [[ -n "$HTTP_ERROR" ]]; then
        echo "curl stderr:"
        printf '%s\n' "$HTTP_ERROR"
    fi

    echo
    printf '%s\n' "$HTTP_BODY"
    echo

    # ------------------------------------------------------------------------
    # /slots
    # ------------------------------------------------------------------------

    local slots_url
    slots_url="$BASE/slots?model=$model_q&autoload=false"

    echo ">>> GET $slots_url"

    http_get "$slots_url"

    echo "HTTP $HTTP_CODE"

    if [[ -n "$HTTP_ERROR" ]]; then
        echo "curl stderr:"
        printf '%s\n' "$HTTP_ERROR"
    fi

    echo
    printf '%s\n' "$HTTP_BODY"
    echo
}

if [[ "$MODE" == "raw" ]]; then
    raw_snapshot
    exit 0
fi

if [[ "$MODE" == "raw-watch" ]]; then
    while true; do
        raw_snapshot
        echo
        echo "Sleeping ${INTERVAL}s..."
        echo
        sleep "$INTERVAL"
    done
fi

# ============================================================================
# DASHBOARD terminal setup
# ============================================================================

printf '\033[?1049h'
printf '\033[?25l'
ALT_SCREEN=1

clear_screen() {
    printf '\033[H\033[J'
}

# ============================================================================
# Dashboard state
# ============================================================================

declare -A prev=()
declare -A curr=()

gen_live_hist=()
prompt_live_hist=()
ctx_hist=()
mtp_hist=()

last_model=""
last_sample_ts=""

# ============================================================================
# Fixed-width history
# ============================================================================

reset_histories() {
    gen_live_hist=()
    prompt_live_hist=()
    ctx_hist=()
    mtp_hist=()

    local i

    for ((i=0; i<HISTORY_LEN; i++)); do
        gen_live_hist+=(0)
        prompt_live_hist+=(0)
        ctx_hist+=(0)
        mtp_hist+=(0)
    done
}

reset_histories

push_hist() {
    local name="$1"
    local value="$2"

    local -n arr="$name"

    arr+=("$value")

    while (( ${#arr[@]} > HISTORY_LEN )); do
        arr=("${arr[@]:1}")
    done
}

spark() {
    if (( $# == 0 )); then
        printf '%s' '-'
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
            vals[i] = ARGV[i] + 0

            if (vals[i] < min) min = vals[i]
            if (vals[i] > max) max = vals[i]
        }

        # Entire history is zero
        if (min == 0 && max == 0) {
            for (i = 1; i < ARGC; i++)
                printf "·"

            exit
        }

        range = max - min

        for (i = 1; i < ARGC; i++) {
            x = vals[i]

            if (range == 0)
                idx = 3
            else
                idx = int(((x - min) / range) * 7)

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

delta_metric() {
    local name="$1"
    local current="${curr[$name]:-0}"
    local old="${prev[$name]:-}"

    if [[ -z "$old" ]]; then
        printf '0'
        return
    fi

    awk -v n="$current" -v o="$old" '
        BEGIN {
            d = n-o

            # Counter reset/model reload.
            if (d < 0)
                d = 0

            printf "%.10g", d
        }
    '
}

# ============================================================================
# Keyboard
# ============================================================================

check_keypress() {
    local key=""

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

    while awk -v e="$elapsed" -v t="$total" \
        'BEGIN { exit !(e < t) }'
    do
        check_keypress
        sleep "$step"

        elapsed="$(
            awk -v e="$elapsed" -v s="$step" '
                BEGIN {
                    printf "%.2f", e+s
                }
            '
        )"
    done
}

# ============================================================================
# Main loop
# ============================================================================

while true; do
    check_keypress

    # ------------------------------------------------------------------------
    # /models
    # ------------------------------------------------------------------------

    http_get "$BASE/models"

    MODELS="$HTTP_BODY"
    MODELS_CODE="$HTTP_CODE"

    if [[ "$MODELS_CODE" != "200" ]] ||
       ! jq -e '.data' >/dev/null 2>&1 <<< "$MODELS"
    then
        clear_screen

        echo "llamatop    $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        echo "GET $BASE/models"
        echo
        echo "HTTP $MODELS_CODE"
        echo

        if [[ -n "$HTTP_ERROR" ]]; then
            echo "$HTTP_ERROR"
            echo
        fi

        if [[ -n "$MODELS" ]]; then
            echo "$MODELS"
            echo
        fi

        echo "q = quit"

        responsive_sleep "$INTERVAL"
        continue
    fi

    # ------------------------------------------------------------------------
    # Select model
    # ------------------------------------------------------------------------

    MODEL="$(detect_model "$MODELS")"

    if [[ -z "$MODEL" ]]; then
        clear_screen

        echo "llamatop    $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Server: $BASE"
        echo
        echo "No model currently loaded."
        echo
        echo "Router models:"
        echo

        jq -r '
            .data[]?
            | "  \(.status.value // "?")   \(.id)"
        ' <<< "$MODELS"

        echo
        echo "Waiting..."
        echo "q = quit"

        responsive_sleep "$INTERVAL"
        continue
    fi

    MODEL_MODE="auto"

    if [[ -n "$PINNED_MODEL" ]]; then
        MODEL_MODE="pinned"
    fi

    # ------------------------------------------------------------------------
    # Model changed
    # ------------------------------------------------------------------------

    if [[ "$MODEL" != "$last_model" ]]; then
        prev=()
        curr=()

        reset_histories

        last_sample_ts=""
        last_model="$MODEL"
    fi

    MODEL_Q="$(urlencode "$MODEL")"

    METRICS_URL="$BASE/metrics?model=$MODEL_Q&autoload=false"
    SLOTS_URL="$BASE/slots?model=$MODEL_Q&autoload=false"

    # ------------------------------------------------------------------------
    # /metrics
    # ------------------------------------------------------------------------

    http_get "$METRICS_URL"

    METRICS="$HTTP_BODY"
    METRICS_CODE="$HTTP_CODE"
    METRICS_ERROR="$HTTP_ERROR"

    if [[ "$METRICS_CODE" != "200" ]]; then
        clear_screen

        echo "llamatop    $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        echo "GET $METRICS_URL"
        echo
        echo "HTTP $METRICS_CODE"
        echo

        [[ -n "$METRICS_ERROR" ]] && echo "$METRICS_ERROR"
        [[ -n "$METRICS" ]] && echo "$METRICS"

        echo

        case "$METRICS_CODE" in
            401)
                echo "Authentication failed. Check the API key."
                ;;
            501|404)
                echo "The /metrics endpoint may be disabled."
                echo
                echo 'Start Jan with:'
                echo '  $env:LLAMA_ARG_ENDPOINT_METRICS="true"'
                ;;
            *)
                echo "Use --raw to inspect all endpoint responses."
                ;;
        esac

        echo
        echo "q = quit"

        responsive_sleep "$INTERVAL"
        continue
    fi

    # ------------------------------------------------------------------------
    # /slots
    # ------------------------------------------------------------------------

    http_get "$SLOTS_URL"

    SLOTS="$HTTP_BODY"
    SLOTS_CODE="$HTTP_CODE"

    if [[ "$SLOTS_CODE" != "200" ]] ||
       ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$SLOTS"
    then
        SLOTS='[]'
    fi

    # ------------------------------------------------------------------------
    # Parse Prometheus values
    # ------------------------------------------------------------------------

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

    # ------------------------------------------------------------------------
    # Timing interval
    # ------------------------------------------------------------------------

    NOW_TS="$(date +%s.%N)"

    SAMPLE_DT="$INTERVAL"

    if [[ -n "$last_sample_ts" ]]; then
        SAMPLE_DT="$(
            awk -v n="$NOW_TS" -v o="$last_sample_ts" '
                BEGIN {
                    d = n-o

                    if (d <= 0)
                        d = 1

                    printf "%.6f", d
                }
            '
        )"
    fi

    last_sample_ts="$NOW_TS"

    # ------------------------------------------------------------------------
    # Official average gauges
    # ------------------------------------------------------------------------

    GEN_AVG="$(metric 'llamacpp:predicted_tokens_seconds')"
    PROMPT_AVG="$(metric 'llamacpp:prompt_tokens_seconds')"

    # ------------------------------------------------------------------------
    # Counters
    # ------------------------------------------------------------------------

    PROMPT_TOTAL="$(metric 'llamacpp:prompt_tokens_total')"
    GENERATED_TOTAL="$(metric 'llamacpp:tokens_predicted_total')"

    PROMPT_DELTA="$(delta_metric 'llamacpp:prompt_tokens_total')"
    GENERATED_DELTA="$(delta_metric 'llamacpp:tokens_predicted_total')"

    # ------------------------------------------------------------------------
    # Actual sample-to-sample "live" rates
    # ------------------------------------------------------------------------

    PROMPT_LIVE="$(
        awk \
            -v d="$PROMPT_DELTA" \
            -v t="$SAMPLE_DT" '
        BEGIN {
            if (t > 0)
                printf "%.2f", d/t
            else
                printf "0.00"
        }'
    )"

    GEN_LIVE="$(
        awk \
            -v d="$GENERATED_DELTA" \
            -v t="$SAMPLE_DT" '
        BEGIN {
            if (t > 0)
                printf "%.2f", d/t
            else
                printf "0.00"
        }'
    )"

    PROCESSING="$(metric 'llamacpp:requests_processing')"
    DEFERRED="$(metric 'llamacpp:requests_deferred')"

    # ------------------------------------------------------------------------
    # State
    # ------------------------------------------------------------------------

    REQUEST_STATE="IDLE"

    if awk -v p="$PROCESSING" 'BEGIN {exit !(p > 0)}'; then

        if awk -v g="$GENERATED_DELTA" 'BEGIN {exit !(g > 0)}'; then
            REQUEST_STATE="GENERATING"

        elif awk -v p="$PROMPT_DELTA" 'BEGIN {exit !(p > 0)}'; then
            REQUEST_STATE="PREFILL"

        else
            REQUEST_STATE="PROCESSING"
        fi
    fi

    # ------------------------------------------------------------------------
    # Context high-water mark
    # ------------------------------------------------------------------------

    CTX_HI="$(metric 'llamacpp:n_tokens_max')"

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

    # ------------------------------------------------------------------------
    # MTP
    # ------------------------------------------------------------------------

    DRAFT="$(metric 'llamacpp:spec_decode_num_draft_tokens_total')"
    ACCEPTED="$(metric 'llamacpp:spec_decode_num_accepted_tokens_total')"
    DRAFT_STEPS="$(metric 'llamacpp:spec_decode_num_drafts_total')"

    DRAFT_DELTA="$(
        delta_metric 'llamacpp:spec_decode_num_draft_tokens_total'
    )"

    ACCEPTED_DELTA="$(
        delta_metric 'llamacpp:spec_decode_num_accepted_tokens_total'
    )"

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

    MTP_RECENT="-"

    if awk -v d="$DRAFT_DELTA" 'BEGIN {exit !(d > 0)}'; then
        MTP_RECENT="$(
            awk \
                -v a="$ACCEPTED_DELTA" \
                -v d="$DRAFT_DELTA" '
            BEGIN {
                printf "%.1f", 100*a/d
            }'
        )"
    fi

    # ------------------------------------------------------------------------
    # Histories
    # ------------------------------------------------------------------------

    push_hist gen_live_hist "$GEN_LIVE"
    push_hist prompt_live_hist "$PROMPT_LIVE"
    push_hist ctx_hist "$CTX_PCT"

    if [[ "$MTP_RECENT" != "-" ]]; then
        push_hist mtp_hist "$MTP_RECENT"
    else
        push_hist mtp_hist 0
    fi

    # ------------------------------------------------------------------------
    # Render
    # ------------------------------------------------------------------------

    clear_screen

    echo "════════════════════════════════════════════════════════════════════════════════"
    echo " llamatop — Jan / llama.cpp                    $(date '+%Y-%m-%d %H:%M:%S')"
    echo "════════════════════════════════════════════════════════════════════════════════"

    printf " Model           %s  [%s]\n" "$MODEL" "$MODEL_MODE"
    printf " Server          %s\n" "$BASE"
    printf " State           %s\n" "$REQUEST_STATE"

    echo
    echo "──────────────────────────────── THROUGHPUT ────────────────────────────────────"

    printf " Generation live %9.2f tok/s   " "$GEN_LIVE"
    spark "${gen_live_hist[@]}"
    echo

    printf " Generation avg  %9.2f tok/s   (llama.cpp gauge)\n" "$GEN_AVG"

    printf " Prompt live     %9.2f tok/s   " "$PROMPT_LIVE"
    spark "${prompt_live_hist[@]}"
    echo

    printf " Prompt avg      %9.2f tok/s   (llama.cpp gauge)\n" "$PROMPT_AVG"

    echo
    printf " Requests        processing=%s  queued=%s\n" \
        "$PROCESSING" "$DEFERRED"

    printf " Tokens          prompt=%s  generated=%s\n" \
        "$PROMPT_TOTAL" "$GENERATED_TOTAL"

    printf " Sample delta    prompt=+%s  generated=+%s  over %.2fs\n" \
        "$PROMPT_DELTA" "$GENERATED_DELTA" "$SAMPLE_DT"

    # ------------------------------------------------------------------------
    # Context
    # ------------------------------------------------------------------------

    echo
    echo "───────────────────────────────── CONTEXT ──────────────────────────────────────"

    printf " High water      %9s / %-9s  %5.1f%%   " \
        "$CTX_HI" "$SLOT_CTX_MAX" "$CTX_PCT"

    spark "${ctx_hist[@]}"
    echo

    echo "                 largest observed sequence, not exact current KV occupancy"

    # ------------------------------------------------------------------------
    # MTP
    # ------------------------------------------------------------------------

    echo
    echo "────────────────────────────────── MTP ─────────────────────────────────────────"

    if awk -v d="$DRAFT" 'BEGIN {exit !(d > 0)}'; then

        printf " Acceptance all  %8.1f%%   %s accepted / %s draft\n" \
            "$MTP_TOTAL" "$ACCEPTED" "$DRAFT"

        printf " Verify steps    %s\n" "$DRAFT_STEPS"

        if [[ "$MTP_RECENT" != "-" ]]; then
            printf " Acceptance live %8s%%   " "$MTP_RECENT"
            spark "${mtp_hist[@]}"
            echo

            printf " Sample delta    +%s accepted / +%s draft\n" \
                "$ACCEPTED_DELTA" "$DRAFT_DELTA"
        else
            echo " Acceptance live        -"
        fi

    else
        echo " No speculative tokens recorded yet."
    fi

    # ------------------------------------------------------------------------
    # Slots
    # ------------------------------------------------------------------------

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
    def nt:
        if (.next_token | type) == "array" then
            (.next_token[0] // {})
        elif (.next_token | type) == "object" then
            .next_token
        else
            {}
        end;

    def r3:
        if type == "number"
        then ((. * 1000 | round) / 1000)
        else .
        end;

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

        (nt | .n_decoded // 0),

        (nt | .n_remain // "-"),

        (
            .params.max_tokens
            // .params.n_predict
            // "-"
        ),

        (.params.temperature // "-" | r3),

        (.params.top_p // "-" | r3),

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

    # ------------------------------------------------------------------------
    # Active slot parameters
    # ------------------------------------------------------------------------

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

    # ------------------------------------------------------------------------
    # All parsed /metrics
    # ------------------------------------------------------------------------

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
                        -v interval="$SAMPLE_DT" '
                    BEGIN {
                        d = new-old

                        if (d > 0)
                            arrow="↑"
                        else if (d < 0)
                            arrow="↓"
                        else
                            arrow="→"

                        if (d < 0 && old > 0) {
                            printf "reset reset ↺"
                        } else {
                            if (interval <= 0)
                                interval=1

                            printf "%.5g %.5g %s", \
                                d, d/interval, arrow
                        }
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
    echo " q = quit    |    --raw = exact endpoint dump"

    # ------------------------------------------------------------------------
    # Save sample
    # ------------------------------------------------------------------------

    prev=()

    for key in "${!curr[@]}"; do
        prev["$key"]="${curr[$key]}"
    done

    responsive_sleep "$INTERVAL"
done
