#!/usr/bin/env bash
set -u

# llamatop.sh — live Jan / llama.cpp router monitor
#
# Usage:
#   ./llamatop.sh [BASE_URL] [API_KEY] [INTERVAL_SECONDS] [MODEL_ID]
#
# Examples:
#
# Auto-detect currently loaded model:
#   ./llamatop.sh http://127.0.0.1:6767 my-api-key 2
#
# No API key:
#   ./llamatop.sh http://127.0.0.1:6767 '' 2
#
# Pin a specific model:
#   ./llamatop.sh \
#     http://127.0.0.1:6767 \
#     my-api-key \
#     2 \
#     Qwen3_8-27B-UD-Q6_K_XL
#
# Requires:
#   bash 4+
#   curl
#   jq
#   awk

BASE="${1:-http://127.0.0.1:6767}"
API_KEY="${2:-}"
INTERVAL="${3:-2}"
PINNED_MODEL="${4:-}"

HISTORY_LEN="${HISTORY_LEN:-30}"
SHOW_ALL_METRICS="${SHOW_ALL_METRICS:-1}"

BASE="${BASE%/}"

# -----------------------------------------------------------------------------
# Dependencies
# -----------------------------------------------------------------------------

for cmd in curl jq awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing dependency: $cmd"
        echo
        echo "Ubuntu/WSL:"
        echo "  sudo apt install -y curl jq gawk"
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# HTTP
# -----------------------------------------------------------------------------

curl_args=(
    -fsS
    --max-time 4
)

if [[ -n "$API_KEY" ]]; then
    curl_args+=(
        -H "Authorization: Bearer $API_KEY"
    )
fi

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------

declare -A prev=()
declare -A curr=()

gen_hist=()
prompt_hist=()
ctx_hist=()
mtp_hist=()

last_model=""

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

urlencode() {
    jq -nr --arg x "$1" '$x | @uri'
}

clear_screen() {
    printf '\033[H\033[2J'
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
    local values="$*"

    if [[ -z "$values" ]]; then
        printf -- "-"
        return
    fi

    awk -v vals="$values" '
    BEGIN {
        blocks[0]="▁"
        blocks[1]="▂"
        blocks[2]="▃"
        blocks[3]="▄"
        blocks[4]="▅"
        blocks[5]="▆"
        blocks[6]="▇"
        blocks[7]="█"

        n = split(vals, a, " ")

        min = a[1] + 0
        max = min

        for (i = 1; i <= n; i++) {
            v = a[i] + 0

            if (v < min) min = v
            if (v > max) max = v
        }

        range = max - min

        for (i = 1; i <= n; i++) {
            v = a[i] + 0

            if (range == 0)
                idx = 3
            else
                idx = int(((v - min) / range) * 7)

            if (idx < 0) idx = 0
            if (idx > 7) idx = 7

            printf "%s", blocks[idx]
        }
    }'
}

metric() {
    local name="$1"

    printf '%s' "${curr[$name]:-0}"
}

fetch_models() {
    curl "${curl_args[@]}" "$BASE/models" 2>/dev/null
}

auto_model() {
    local models_json="$1"

    jq -r '
        [
            .data[]?
            | select(.status.value == "loaded")
            | .id
        ] as $models

        | if ($models | length) > 0
          then $models[0]
          else empty
          end
    ' <<< "$models_json"
}

# -----------------------------------------------------------------------------
# Main loop
# -----------------------------------------------------------------------------

while true; do

    # -------------------------------------------------------------------------
    # Discover loaded model
    # -------------------------------------------------------------------------

    MODELS="$(fetch_models || true)"

    if ! jq -e '.data' >/dev/null 2>&1 <<< "$MODELS"; then
        clear_screen

        echo "llamatop  $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        echo "Cannot read:"
        echo
        echo "  $BASE/models"
        echo

        if [[ -n "$API_KEY" ]]; then
            echo "Check the server URL and API key."
        else
            echo "If Jan auth is enabled, pass the API key as argument 2."
        fi

        sleep "$INTERVAL"
        continue
    fi

    if [[ -n "$PINNED_MODEL" ]]; then
        MODEL="$PINNED_MODEL"
        AUTO_NOTE="pinned"
    else
        MODEL="$(auto_model "$MODELS")"
        AUTO_NOTE="auto"
    fi

    # -------------------------------------------------------------------------
    # No loaded model
    # -------------------------------------------------------------------------

    if [[ -z "$MODEL" ]]; then
        clear_screen

        echo "llamatop  $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Server: $BASE"
        echo
        echo "No model is currently loaded."
        echo
        echo "Available router models:"
        echo

        jq -r '
            .data[]?
            | "  \(.status.value // "?")\t\(.id)"
        ' <<< "$MODELS"

        echo
        echo "Waiting..."

        sleep "$INTERVAL"
        continue
    fi

    # -------------------------------------------------------------------------
    # Reset trajectories when Jan switches models
    # -------------------------------------------------------------------------

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

    # autoload=false is deliberate:
    # monitoring should not wake/load an unloaded model.
    METRICS_URL="$BASE/metrics?model=$MODEL_Q&autoload=false"
    SLOTS_URL="$BASE/slots?model=$MODEL_Q&autoload=false"

    # -------------------------------------------------------------------------
    # Fetch data
    # -------------------------------------------------------------------------

    METRICS="$(
        curl "${curl_args[@]}" "$METRICS_URL" 2>/dev/null || true
    )"

    SLOTS="$(
        curl "${curl_args[@]}" "$SLOTS_URL" 2>/dev/null || true
    )"

    # -------------------------------------------------------------------------
    # Metrics unavailable
    # -------------------------------------------------------------------------

    if [[ -z "$METRICS" || "$METRICS" == \{* ]]; then
        clear_screen

        echo "llamatop  $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        echo "Model:"
        echo "  $MODEL"
        echo
        echo "Could not read /metrics."
        echo
        echo "Enable llama.cpp metrics before starting Jan."
        echo
        echo "PowerShell:"
        echo
        echo '  $env:LLAMA_ARG_ENDPOINT_METRICS="true"'
        echo '  jan serve MODEL -v --port 6767'
        echo

        sleep "$INTERVAL"
        continue
    fi

    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<< "$SLOTS"; then
        SLOTS='[]'
    fi

    # -------------------------------------------------------------------------
    # Parse Prometheus metrics
    # -------------------------------------------------------------------------

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

    # -------------------------------------------------------------------------
    # Important metrics
    # -------------------------------------------------------------------------

    GEN_TPS="$(
        metric 'llamacpp:predicted_tokens_seconds'
    )"

    PROMPT_TPS="$(
        metric 'llamacpp:prompt_tokens_seconds'
    )"

    PROCESSING="$(
        metric 'llamacpp:requests_processing'
    )"

    DEFERRED="$(
        metric 'llamacpp:requests_deferred'
    )"

    # This is a HIGH-WATER MARK, not exact current occupancy.
    CTX_HI="$(
        metric 'llamacpp:n_tokens_max'
    )"

    # -------------------------------------------------------------------------
    # Speculative / MTP metrics
    # -------------------------------------------------------------------------

    DRAFT="$(
        metric 'llamacpp:spec_decode_num_draft_tokens_total'
    )"

    ACCEPTED="$(
        metric 'llamacpp:spec_decode_num_accepted_tokens_total'
    )"

    DRAFT_STEPS="$(
        metric 'llamacpp:spec_decode_num_drafts_total'
    )"

    MTP_TOTAL="$(
        awk \
            -v accepted="$ACCEPTED" \
            -v draft="$DRAFT" '
        BEGIN {
            if (draft > 0)
                printf "%.1f", 100 * accepted / draft
            else
                printf "0.0"
        }'
    )"

    MTP_INTERVAL="-"

    if [[ -n "${prev[llamacpp:spec_decode_num_draft_tokens_total]+x}" ]]; then

        OLD_DRAFT="${
            prev[llamacpp:spec_decode_num_draft_tokens_total]
        }"

        OLD_ACCEPTED="${
            prev[llamacpp:spec_decode_num_accepted_tokens_total]:-0
        }"

        MTP_INTERVAL="$(
            awk \
                -v draft="$DRAFT" \
                -v old_draft="$OLD_DRAFT" \
                -v accepted="$ACCEPTED" \
                -v old_accepted="$OLD_ACCEPTED" '
            BEGIN {
                dd = draft - old_draft
                da = accepted - old_accepted

                if (dd > 0)
                    printf "%.1f", 100 * da / dd
                else
                    printf "-"
            }'
        )"
    fi

    # -------------------------------------------------------------------------
    # Context capacity
    # -------------------------------------------------------------------------

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
                printf "%.1f", 100 * used / max
            else
                printf "0.0"
        }'
    )"

    # -------------------------------------------------------------------------
    # Histories / trajectories
    # -------------------------------------------------------------------------

    push_hist gen_hist "$GEN_TPS"
    push_hist prompt_hist "$PROMPT_TPS"
    push_hist ctx_hist "$CTX_PCT"

    if [[ "$MTP_INTERVAL" != "-" ]]; then
        push_hist mtp_hist "$MTP_INTERVAL"
    fi

    # -------------------------------------------------------------------------
    # Screen
    # -------------------------------------------------------------------------

    clear_screen

    echo "════════════════════════════════════════════════════════════════════════════════"
    echo " llamatop — Jan / llama.cpp router                 $(date '+%Y-%m-%d %H:%M:%S')"
    echo "════════════════════════════════════════════════════════════════════════════════"

    printf " Model       %s  (%s)\n" "$MODEL" "$AUTO_NOTE"
    printf " Server      %s\n" "$BASE"

    echo

    printf " Generation  %9.2f tok/s   " "$GEN_TPS"
    spark "${gen_hist[@]}"
    echo

    printf " Prompt      %9.2f tok/s   " "$PROMPT_TPS"
    spark "${prompt_hist[@]}"
    echo

    printf " Requests    processing=%s  deferred=%s\n" \
        "$PROCESSING" \
        "$DEFERRED"

    printf " Context HI  %9s / %-9s  %5.1f%%   " \
        "$CTX_HI" \
        "$SLOT_CTX_MAX" \
        "$CTX_PCT"

    spark "${ctx_hist[@]}"
    echo

    echo "              ^ high-water mark, NOT exact current context occupancy"

    # -------------------------------------------------------------------------
    # MTP
    # -------------------------------------------------------------------------

    if awk -v draft="$DRAFT" 'BEGIN {exit !(draft > 0)}'; then

        printf " MTP total   %9.1f%%  accepted=%s / draft=%s  steps=%s\n" \
            "$MTP_TOTAL" \
            "$ACCEPTED" \
            "$DRAFT" \
            "$DRAFT_STEPS"

        if [[ "$MTP_INTERVAL" != "-" ]]; then
            printf " MTP recent  %9s%%        " "$MTP_INTERVAL"

            spark "${mtp_hist[@]}"
            echo
        fi

    else
        echo " MTP         no speculative tokens recorded yet"
    fi

    # -------------------------------------------------------------------------
    # Slots
    # -------------------------------------------------------------------------

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

    # -------------------------------------------------------------------------
    # Active request details
    # -------------------------------------------------------------------------

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

    # -------------------------------------------------------------------------
    # Every metric
    # -------------------------------------------------------------------------

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
                        d = new - old

                        if (d > 0)
                            arrow="↑"
                        else if (d < 0)
                            arrow="↓"
                        else
                            arrow="→"

                        # Usually means a counter reset / model reload.
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

    # -------------------------------------------------------------------------
    # Remember metrics for the next sample
    # -------------------------------------------------------------------------

    prev=()

    for key in "${!curr[@]}"; do
        prev["$key"]="${curr[$key]}"
    done

    sleep "$INTERVAL"
done
