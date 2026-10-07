#!/usr/bin/env bash
set -u

# ==============================================================================
# llamatop.sh — Jan / llama.cpp router monitor
#
# Normal:
#   ~/llamatop.sh http://127.0.0.1:6767 jan 2
#
# Compact:
#   SHOW_ALL_METRICS=0 ~/llamatop.sh http://127.0.0.1:6767 jan 2
#
# Exact raw endpoint dump:
#   ~/llamatop.sh http://127.0.0.1:6767 jan 2 --raw
#
# Repeated raw endpoint dump:
#   ~/llamatop.sh http://127.0.0.1:6767 jan 2 --raw-watch
#
# Pin model instead of auto-detect:
#   ~/llamatop.sh http://127.0.0.1:6767 jan 2 Qwen3_8-27B-UD-Q6_K_XL
#
# Dashboard keys:
#   q = quit, j/k = scroll when the dashboard is taller than the terminal
# ==============================================================================

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

# ==============================================================================
# Dependencies
# ==============================================================================

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

# ==============================================================================
# Cleanup / terminal
# ==============================================================================

TMP_DIR="$(mktemp -d)"
ALT_SCREEN=0

cleanup() {
    if [[ "$ALT_SCREEN" == "1" ]]; then
        # Release synchronized output / wrapping even if interrupted mid-frame.
        printf '\033[?2026l\033[?7h'
        printf '\033[?25h'
        printf '\033[?1049l'
    fi

    rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ==============================================================================
# HTTP
# ==============================================================================

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
HTTP_BODY_FILE="$TMP_DIR/body"

http_get() {
    local url="$1"
    local body_file="$HTTP_BODY_FILE"
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

# ==============================================================================
# Common helpers
# ==============================================================================

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
            | objects
            | select((.status | if type == "object" then .value else . end) == "loaded")
            | .id
            | select(type == "string" and length > 0)
        ]
        | if length > 0 then .[0] else empty end
    ' <<< "$models" 2>/dev/null
}

# /models reports which models are loaded, not which one is answering. In a
# router with multiple loaded models, prefer an active /slots response. Keep
# following the previously selected model when all models are idle.
select_dashboard_model() {
    PROBED_SLOTS=0
    MODEL="$(detect_model "$MODELS")"
    [[ -n "$PINNED_MODEL" || -z "$MODEL" ]] && return
    local -a candidates=()
    local candidate probe fallback="$MODEL"
    mapfile -t candidates < <(jq -r '
        .data[]? | objects |
        select((.status | if type == "object" then .value else . end) == "loaded") |
        .id | select(type == "string" and length > 0)
    ' <<< "$MODELS")
    (( ${#candidates[@]} <= 1 )) && return
    # Prefer the current model if more than one model is busy.
    for candidate in "${candidates[@]}"; do
        if [[ "$candidate" == "$last_model" ]]; then
            fallback="$candidate"
            candidates=("$candidate" "${candidates[@]}")
            break
        fi
    done
    local -A visited=()
    for candidate in "${candidates[@]}"; do
        [[ -n "${visited[$candidate]:-}" ]] && continue
        visited["$candidate"]=1
        check_keypress
        http_get "$BASE/slots?model=$(urlencode "$candidate")&autoload=false"
        local probe_ts
        probe_ts="$(date +%s.%N)"
        [[ "$HTTP_CODE" != "200" || "$HTTP_RC" != "0" ]] && continue
        if probe="$(normalize_slots <<< "$HTTP_BODY" 2>/dev/null)" &&
           jq -e 'any(.[]; .active == true)' >/dev/null <<< "$probe"
        then
            MODEL="$candidate"
            PROBED_SLOTS=1
            PROBED_SLOTS_BODY="$HTTP_BODY"
            PROBED_SLOTS_TS="$probe_ts"
            return
        fi
    done
    MODEL="$fallback"
}

# Raw bodies must come directly from curl's file. Command substitution strips
# trailing newlines, and Bash variables cannot preserve NUL bytes.
print_raw_response() {
    printf 'HTTP %s\n' "$HTTP_CODE"
    if [[ -n "$HTTP_ERROR" ]]; then
        printf 'curl stderr (exit %s):\n%s\n' "$HTTP_RC" "$HTTP_ERROR"
    fi
    printf '%s\n' '--- BEGIN RESPONSE BODY ---'
    cat "$HTTP_BODY_FILE"
    # This separator newline belongs to the wrapper, not to the response body.
    printf '\n%s\n\n' '--- END RESPONSE BODY ---'
}

# ==============================================================================
# Raw modes
# ==============================================================================

raw_snapshot() {
    local model=""
    local model_q=""

    echo "==============================================================================="
    echo "llamatop RAW    $(date '+%Y-%m-%d %H:%M:%S.%3N')"
    echo "==============================================================================="
    echo

    # /models
    echo ">>> GET $BASE/models"
    http_get "$BASE/models"

    print_raw_response

    if [[ "$HTTP_CODE" != "200" && -z "$PINNED_MODEL" ]]; then
        echo "Cannot auto-detect a model; provide a pinned model to query /metrics and /slots."
        return
    fi

    model="$(detect_model "$HTTP_BODY")"

    if [[ -z "$model" ]]; then
        echo "No loaded model detected."
        return
    fi

    model_q="$(urlencode "$model")"

    echo "Detected model: $model"
    echo

    # /metrics
    local metrics_url
    metrics_url="$BASE/metrics?model=$model_q&autoload=false"

    echo ">>> GET $metrics_url"
    http_get "$metrics_url"

    print_raw_response

    # /slots
    local slots_url
    slots_url="$BASE/slots?model=$model_q&autoload=false"

    echo ">>> GET $slots_url"
    http_get "$slots_url"

    print_raw_response
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

# ==============================================================================
# Dashboard terminal
# ==============================================================================

printf '\033[?1049h'
printf '\033[?25l'
ALT_SCREEN=1

shopt -s checkwinsize
previous_frame=()
last_frame=""
last_frame_rows=0
last_frame_cols=0
scroll_offset=0

# All slow formatting finishes off-screen. Then overwrite changed rows in one
# buffered update, without clearing the screen first. DEC mode 2026 additionally
# groups the update on supporting terminals; other terminals ignore that mode.
present_frame() {
    last_frame="$1"
    if [[ ! -t 1 ]]; then
        # Preserve complete snapshots when output is captured rather than shown.
        printf '\033[H\033[J%s\n' "$last_frame"
        return
    fi
    local rows="${LINES:-24}" cols="${COLUMNS:-80}"
    [[ "$rows" =~ ^[1-9][0-9]*$ ]] || rows=24
    [[ "$cols" =~ ^[1-9][0-9]*$ ]] || cols=80
    local -a lines=() visible=()
    local total body_rows max_offset row count line old_line part payload="" footer resized=0
    local width=$((cols > 1 ? cols-1 : 1))
    mapfile -t lines <<< "$last_frame"
    total=${#lines[@]}
    body_rows=$rows
    if (( total > rows )); then
        body_rows=$((rows-1))
        max_offset=$((total-body_rows))
        (( scroll_offset > max_offset )) && scroll_offset=$max_offset
        (( scroll_offset < 0 )) && scroll_offset=0
        for ((row=0; row<body_rows; row++)); do
            visible+=("${lines[row+scroll_offset]}")
        done
        printf -v footer ' q = quit | j/k = scroll | lines %s-%s/%s' \
            "$((scroll_offset+1))" "$((scroll_offset+body_rows))" "$total"
        visible+=("$footer")
    else
        scroll_offset=0
        visible=("${lines[@]}")
    fi
    if (( rows != last_frame_rows || cols != last_frame_cols )); then
        previous_frame=()
        resized=1
    fi
    count=${#visible[@]}
    (( ${#previous_frame[@]} > count )) && count=${#previous_frame[@]}
    (( resized )) && count=$rows
    (( count > rows )) && count=$rows
    for ((row=0; row<count; row++)); do
        line="${visible[row]:-}"
        # Keep each logical line in its own physical row. Do not let endpoint
        # text move the cursor or cause wrapping/scrolling during a refresh.
        line="${line//$'\r'/}"
        line="${line//$'\t'/    }"
        line="${line//$'\033'/?}"
        line="${line:0:width}"
        old_line="${previous_frame[row]-}"
        if [[ ! ${previous_frame[row]+present} || "$line" != "$old_line" ]]; then
            printf -v part '\033[%s;1H%s\033[K' "$((row+1))" "$line"
            payload+="$part"
        fi
        visible[row]="$line"
    done
    previous_frame=("${visible[@]}")
    last_frame_rows=$rows
    last_frame_cols=$cols
    if [[ -n "$payload" ]]; then
        printf '\033[?2026h\033[?7l%s\033[?7h\033[?2026l' "$payload"
    fi
}

# ==============================================================================
# Dashboard state
# ==============================================================================

declare -A curr=()

gen_hist=()
prompt_hist=()

last_model=""
last_sample_ts=""

# Live slot state from previous poll
prev_slots='[]'
remembered_requests='[]'

# ==============================================================================
# History / sparkline
# ==============================================================================

reset_histories() {
    gen_hist=()
    prompt_hist=()
    gen_min='n/a'
    gen_max='n/a'
    prompt_min='n/a'
    prompt_max='n/a'

    local i

    for ((i=0; i<HISTORY_LEN; i++)); do
        gen_hist+=(0)
        prompt_hist+=(0)
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

# Track positive observed rates for the selected model. Idle zeros, startup
# baselines, missing measurements and sparkline padding are not measurements
# of prefill/decode performance, so they must not become the minimum.
update_rate_range() {
    local value="$1"
    local -n low="$2"
    local -n high="$3"
    IFS=$'\t' read -r low high < <(
        awk -v value="$value" -v lo="$low" -v hi="$high" 'BEGIN {
            if (value != "n/a" && value+0 > 0) {
                if (lo == "n/a" || value+0 < lo+0) lo=value
                if (hi == "n/a" || value+0 > hi+0) hi=value
            }
            printf "%s\t%s\n", lo, hi
        }'
    )
}

spark() {
    if (( $# == 0 )); then
        printf '%s' '-'
        return
    fi

    local values="$*"

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

        known = 0
        for (i = 1; i <= n; i++) {
            if (a[i] == "n/a") continue
            x = a[i] + 0
            if (!known || x < min) min = x
            if (!known || x > max) max = x
            known++
        }

        if (min == 0 && max == 0) {
            for (i = 1; i <= n; i++)
                printf "%s", (a[i] == "n/a" ? "?" : "·")

            exit
        }

        range = max - min

        for (i = 1; i <= n; i++) {
            if (a[i] == "n/a") { printf "?"; continue }
            x = a[i] + 0

            if (range == 0)
                idx = 3
            else
                idx = int(((x - min) / range) * 7)

            if (idx < 0) idx = 0
            if (idx > 7) idx = 7

            printf "%s", blocks[idx]
        }
    }'
}

metric() {
    local name="$1"
    printf '%s' "${curr[$name]:-n/a}"
}

format_number() {
    awk -v value="$1" -v digits="${2:-2}" 'BEGIN {
        if (value ~ /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/)
            printf "%.*f", digits, value
        else
            printf "n/a"
    }'
}

# Fixed scale: 0% is empty, 100% is full, independent of previous samples.
context_bar() {
    awk -v used="$1" -v capacity="$2" -v width=30 'BEGIN {
        if (used == "n/a" || capacity == "n/a" || capacity <= 0) {
            printf "[context unavailable]"
            exit
        }
        filled = int(width * used / capacity)
        if (filled < 0) filled = 0
        if (filled > width) filled = width
        printf "["
        for (i = 0; i < width; i++) printf "%s", (i < filled ? "█" : "░")
        printf "]"
    }'
}

# Keep unknown fields null rather than fabricating zero measurements. Accept the
# array API as well as common object wrappers. Only explicit cache data is used.
normalize_slots() {
    jq -ce '
        def object: if type == "object" then . else {} end;
        def number:
            (if type == "number" then .
             elif type == "string" then (try tonumber catch null)
             else null end)
            | if type == "number" then (if isfinite then . else null end) else null end;
        def count: number | if . != null and . >= 0 then . else null end;
        def scalar:
            if (type == "string" or type == "number") and tostring != ""
            then tostring else null end;
        def nt:
            .next_token | if type == "array" then (.[0] | object) else object end;
        (if type == "array" then .
         elif type == "object" then
             if (.slots | type) == "array" then .slots
             elif (.data | type) == "array" then .data
             else error("expected a slot array or slots/data array") end
         else error("expected a slot array") end)
        | to_entries | map(
            select(.value | type == "object")
            | .key as $index | .value
            | (.params | object) as $p
            | ($p.speculative | object) as $sp
            | nt as $nt
            | {
                id: ((.id | scalar) // (.slot_id | scalar) // ($index | tostring)),
                task: (.id_task | scalar),
                active: (if (.is_processing | type) == "boolean" then .is_processing else null end),
                capacity: (.n_ctx | count),
                context: (.n_prompt_tokens | count),
                evaluated: (.n_prompt_tokens_processed | count),
                cached: (.n_prompt_tokens_cache | count),
                decoded: ($nt.n_decoded | count),
                remain: ($nt.n_remain | number),
                speculative: (if (.speculative | type) == "boolean" then .speculative else null end),
                temperature: ($p.temperature | number),
                top_p: ($p.top_p | number),
                min_p: ($p.min_p | number),
                top_k: ($p.top_k | number),
                reasoning: ($p.reasoning_format | scalar),
                spec_nmax: (($p["speculative.n_max"] // $sp.n_max) | number),
                spec_nmin: (($p["speculative.n_min"] // $sp.n_min) | number),
                spec_pmin: (($p["speculative.p_min"] // $sp.p_min) | number)
            }
        )
    '
}

# Preserve the last observed request in each slot when an idle response clears
# its counters. These saved values are used only for the request summary, never
# for live rates or current context occupancy.
request_summary() {
    jq -c --argjson remembered "$remembered_requests" --argjson ok "$SLOTS_OK" '
        def has_tokens: any([.context, .evaluated, .cached, .decoded][]; . != null and . > 0);
        def latest_counter($old; $new): [$old, $new] | map(select(. != null)) | max;
        . as $slots |
        (if $ok == 0 then $remembered else
            reduce $slots[] as $now ($remembered;
                ([.[] | select(.id == $now.id)][0]) as $old |
                (if $now.active == true then $now
                 elif $now.active == false then
                    if $old == null then
                        (if $now | has_tokens then
                            $now | if .evaluated == 0 and .cached == 0 and .decoded == 0 then
                                .evaluated = null | .cached = null | .decoded = null
                            else . end
                         else null end)
                    elif $old.task != null and $now.task == $old.task then
                        $old + {
                            context: (if $now.context != null and $now.context > 0 then $now.context else $old.context end),
                            evaluated: latest_counter($old.evaluated; $now.evaluated),
                            cached: latest_counter($old.cached; $now.cached),
                            decoded: latest_counter($old.decoded; $now.decoded)
                        }
                    elif $now.task != null and $now.task != "-1" and ($now | has_tokens) then $now
                    else $old end
                 else $old end) as $save |
                if $save == null then . else [.[] | select(.id != $now.id)] + [$save] end
            ) end) as $saved |
        [$slots[] | select(.active == true)] as $active |
        (if $ok == 0 then {visible: $saved, scope: "last observed requests; /slots unavailable"}
         elif ($active | length) > 0 then {visible: $active, scope: "active requests"}
         elif any($slots[]; .active == null) then {visible: $slots, scope: "reported slot counters; activity state unavailable"}
         elif ($saved | length) > 0 then {visible: $saved, scope: "last observed request per slot (idle; not live)"}
         else {visible: [], scope: "no request counters observed yet"} end)
        + {saved: $saved}
    '
}

endpoint_error() {
    printf '\nGET %s\nHTTP %s\n' "$1" "$2"
    [[ -n "$3" ]] && printf '%s\n' "$3"
    [[ -n "$4" ]] && printf '%s\n' "$4"
    printf '%s\n' 'Use --raw for the exact response body.'
}

# ==============================================================================
# Keyboard
# ==============================================================================

check_keypress() {
    local key=""

    if read -rsn1 -t 0.01 key 2>/dev/null; then
        case "$key" in
            q|Q)
                exit 0
                ;;
            j)
                ((scroll_offset+=3))
                [[ -n "$last_frame" ]] && present_frame "$last_frame"
                ;;
            k)
                ((scroll_offset-=3))
                [[ -n "$last_frame" ]] && present_frame "$last_frame"
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
                BEGIN { printf "%.2f", e+s }
            '
        )"
    done
}

# ==============================================================================
# Main loop
# ==============================================================================

while true; do
    check_keypress

    http_get "$BASE/models"
    MODELS="$HTTP_BODY"
    MODELS_CODE="$HTTP_CODE"
    MODELS_ERROR="$HTTP_ERROR"
    MODELS_OK=1
    if [[ "$MODELS_CODE" != "200" || "$HTTP_RC" != "0" ]] ||
       ! jq -e 'type == "object" and (.data | type) == "array"' >/dev/null 2>&1 <<< "$MODELS"
    then
        MODELS_OK=0
        if [[ -z "$PINNED_MODEL" ]]; then
            FRAME="$(
            printf 'llamatop    %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
            endpoint_error "$BASE/models" "$MODELS_CODE" "$MODELS_ERROR" "$MODELS"
            [[ "$MODELS_CODE" == "200" ]] && echo 'Expected a /models object containing a data array.'
            echo 'q = quit'
            )"
            present_frame "$FRAME"
            prev_slots='[]'
            last_sample_ts=""
            responsive_sleep "$INTERVAL"
            continue
        fi
    fi

    select_dashboard_model
    if [[ -z "$MODEL" ]]; then
        FRAME="$(
        printf 'llamatop    %s\nServer: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$BASE"
        echo 'No model currently loaded.'
        jq -r '
            .data[]? | objects |
            "  \(.status | if type == "object" then .value else . end // "?")   \(.id // "?")"
        ' <<< "$MODELS"
        echo 'Waiting...  q = quit'
        )"
        present_frame "$FRAME"
        prev_slots='[]'
        last_sample_ts=""
        responsive_sleep "$INTERVAL"
        continue
    fi

    MODEL_MODE="auto"
    [[ -n "$PINNED_MODEL" ]] && MODEL_MODE="pinned"
    if [[ "$MODEL" != "$last_model" ]]; then
        curr=()
        reset_histories
        last_sample_ts=""
        prev_slots='[]'
        remembered_requests='[]'
        last_model="$MODEL"
    fi

    MODEL_Q="$(urlencode "$MODEL")"
    METRICS_URL="$BASE/metrics?model=$MODEL_Q&autoload=false"
    SLOTS_URL="$BASE/slots?model=$MODEL_Q&autoload=false"

    http_get "$METRICS_URL"
    METRICS="$HTTP_BODY"
    METRICS_CODE="$HTTP_CODE"
    METRICS_ERROR="$HTTP_ERROR"
    METRICS_OK=1
    [[ "$METRICS_CODE" != "200" || "$HTTP_RC" != "0" ]] && METRICS_OK=0

    # A metrics error must not prevent independent live /slots monitoring.
    if [[ "$PROBED_SLOTS" == "1" ]]; then
        # Reuse the active snapshot that selected this model. A second request
        # could otherwise see cleared statistics from an already-finished task.
        HTTP_BODY="$PROBED_SLOTS_BODY"
        HTTP_CODE=200
        HTTP_RC=0
        HTTP_ERROR=""
        SLOT_SAMPLE_TS="$PROBED_SLOTS_TS"
    else
        http_get "$SLOTS_URL"
        SLOT_SAMPLE_TS="$(date +%s.%N)"
    fi
    SLOTS_BODY="$HTTP_BODY"
    SLOTS_CODE="$HTTP_CODE"
    SLOTS_ERROR="$HTTP_ERROR"
    SLOTS_OK=1
    SLOTS='[]'
    if [[ "$SLOTS_CODE" != "200" || "$HTTP_RC" != "0" ]]; then
        SLOTS_OK=0
    elif ! SLOTS="$(normalize_slots <<< "$SLOTS_BODY" 2>"$TMP_DIR/slots-parse-error")"; then
        SLOTS_OK=0
        SLOTS_ERROR="$(cat "$TMP_DIR/slots-parse-error")"
    fi
    [[ "$SLOTS_OK" == "0" ]] && SLOTS='[]'

    # Timestamp slot samples at receipt, including reused routing probes. Never derive a
    # live rate from tokens_predicted_total or any other /metrics counter.
    NOW_TS="$SLOT_SAMPLE_TS"
    SAMPLE_DT="$INTERVAL"
    if [[ -n "$last_sample_ts" ]]; then
        SAMPLE_DT="$(awk -v n="$NOW_TS" -v o="$last_sample_ts" '
            BEGIN { d=n-o; if (d <= 0) d=1; printf "%.6f", d }
        ')"
    fi
    last_sample_ts="$NOW_TS"

    curr=()
    if [[ "$METRICS_OK" == "1" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            key="${line%%[[:space:]]*}"
            rest="${line#*[[:space:]]}"
            read -r val _ <<< "$rest"
            if [[ "$val" =~ ^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$ ]]; then
                curr["$key"]="$val"
            fi
        done <<< "$METRICS"
    fi

    # Match each slot and request independently. Decode always uses two samples
    # of the same request. For prefill, an observed request change starts its
    # counter at zero: short prefills often finish before their first poll.
    # This is throughput over the whole polling interval, not prefill duration.
    # On startup/recovery there is no prior observation, so use a zero baseline.
    SLOT_LIVE="$(jq -r --argjson previous "$prev_slots" --argjson ok "$SLOTS_OK" '
        def sum_known:
            if any(.[]; . == null) then null else (add // 0) end;
        def display: if . == null then "n/a" else tostring end;
        . as $slots | [.[] | select(.active == true)] as $active |
        def delta($field):
            if $ok == 0 or any($slots[]; .active == null) then null
            else [$active[] | . as $now |
                if .task == null or .[$field] == null then null
                else ([$previous[] | select(.id == $now.id)][0]) as $prior_slot |
                    ([$previous[] | select(.id == $now.id and .task == $now.task and .active == true)][0]) as $old |
                    if $old == null then
                        if $field == "evaluated" and $prior_slot != null and
                           ($prior_slot.active == false or
                            ($prior_slot.task != null and $prior_slot.task != $now.task))
                        then $now[$field] else 0 end
                    elif $old[$field] == null then 0
                    else [0, ($now[$field] - $old[$field])] | max end
                end
            ] | sum_known end;
        [
            (if $ok == 0 then null else $active | map(.evaluated) | sum_known end),
            (if $ok == 0 then null else $active | map(.decoded) | sum_known end),
            (if $ok == 0 then null else $active | map(.context) | sum_known end),
            (if $ok == 0 or ($active | length) == 0 then null else $active | map(.cached) | sum_known end),
            ($active | length),
            delta("evaluated"),
            delta("decoded"),
            (if length == 0 then null else map(.context) | sum_known end),
            (if length == 0 then null else map(.capacity) | sum_known end),
            length,
            (if any(.[]; .active == null) then 1 else 0 end)
        ] | map(display) | @tsv
    ' <<< "$SLOTS")"

    IFS=$'\t' read -r \
        SLOT_PROMPT_PROCESSED SLOT_DECODED SLOT_CONTEXT SLOT_CACHED SLOT_ACTIVE_COUNT \
        SLOT_PROMPT_DELTA SLOT_DECODED_DELTA CTX_CURRENT CTX_CAPACITY SLOT_COUNT SLOT_UNKNOWN_STATE \
        <<< "$SLOT_LIVE"

    # Count display and rate measurements deliberately have separate lifetimes:
    # idle means zero current throughput, not a request with zero input/output.
    SUMMARY="$(request_summary <<< "$SLOTS")"
    remembered_requests="$(jq -c '.saved' <<< "$SUMMARY")"
    COUNTER_SCOPE="$(jq -r '.scope' <<< "$SUMMARY")"
    SUMMARY_COUNTS="$(jq -r '
        def sum_known:
            if length == 0 or any(.[]; . == null) then null else add end;
        .visible | [map(.evaluated) | sum_known] +
            [map(.decoded) | sum_known] + [map(.context) | sum_known] +
            [map(.cached) | sum_known]
        | map(if . == null then "n/a" else tostring end) | @tsv
    ' <<< "$SUMMARY")"
    IFS=$'\t' read -r DISPLAY_PREFILL DISPLAY_DECODED DISPLAY_CONTEXT DISPLAY_CACHED <<< "$SUMMARY_COUNTS"

    PROMPT_LIVE="$(awk -v d="$SLOT_PROMPT_DELTA" -v t="$SAMPLE_DT" '
        BEGIN { if (d == "n/a" || t <= 0) printf "n/a"; else printf "%.2f", d/t }
    ')"
    GEN_LIVE="$(awk -v d="$SLOT_DECODED_DELTA" -v t="$SAMPLE_DT" '
        BEGIN { if (d == "n/a" || t <= 0) printf "n/a"; else printf "%.2f", d/t }
    ')"
    prev_slots="$SLOTS"

    REQUEST_STATE="IDLE"
    if [[ "$SLOTS_OK" == "0" || "$SLOT_UNKNOWN_STATE" == "1" || "$SLOT_COUNT" == "0" ]]; then
        REQUEST_STATE="UNKNOWN"
    elif (( SLOT_ACTIVE_COUNT > 0 )); then
        if awk -v d="$SLOT_DECODED" 'BEGIN { exit !(d != "n/a" && d+0 > 0) }'; then
            REQUEST_STATE="DECODE"
        elif awk -v d="$SLOT_PROMPT_PROCESSED" 'BEGIN { exit !(d != "n/a" && d+0 > 0) }'; then
            REQUEST_STATE="PREFILL"
        else
            REQUEST_STATE="PROCESSING"
        fi
    fi

    GEN_AVG="$(format_number "$(metric 'llamacpp:predicted_tokens_seconds')")"
    PROMPT_AVG="$(format_number "$(metric 'llamacpp:prompt_tokens_seconds')")"
    PROCESSING="$(metric 'llamacpp:requests_processing')"
    DEFERRED="$(metric 'llamacpp:requests_deferred')"
    PROMPT_METRIC_TOTAL="$(metric 'llamacpp:prompt_tokens_total')"
    GENERATED_METRIC_TOTAL="$(metric 'llamacpp:tokens_predicted_total')"

    # n_prompt_tokens already includes generated tokens appended to the sequence.
    # Do NOT add n_decoded. Sum current counts and capacities over the same slots.
    CTX_HI="$(metric 'llamacpp:n_tokens_max')"
    CTX_PCT="$(awk -v used="$CTX_CURRENT" -v capacity="$CTX_CAPACITY" 'BEGIN {
        if (used == "n/a" || capacity == "n/a" || capacity <= 0) printf "n/a"
        else printf "%.1f", 100*used/capacity
    }')"

    DRAFT="$(metric 'llamacpp:spec_decode_num_draft_tokens_total')"
    ACCEPTED="$(metric 'llamacpp:spec_decode_num_accepted_tokens_total')"
    DRAFT_STEPS="$(metric 'llamacpp:spec_decode_num_drafts_total')"
    MTP_TOTAL="$(awk -v a="$ACCEPTED" -v d="$DRAFT" 'BEGIN {
        if (a == "n/a" || d == "n/a" || d <= 0) printf "n/a"
        else printf "%.1f", 100*a/d
    }')"

    push_hist gen_hist "$GEN_LIVE"
    push_hist prompt_hist "$PROMPT_LIVE"
    update_rate_range "$GEN_LIVE" gen_min gen_max
    update_rate_range "$PROMPT_LIVE" prompt_min prompt_max

    FRAME="$(
    echo '════════════════════════════════════════════════════════════════════════════════'
    printf ' llamatop — Jan / llama.cpp                    %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    echo '════════════════════════════════════════════════════════════════════════════════'
    printf ' Model                %s  [%s]\n Server               %s\n State                %s\n' "$MODEL" "$MODEL_MODE" "$BASE" "$REQUEST_STATE"

    echo
    echo '───────────────────────────── REQUEST MONITOR ──────────────────────────────────'
    printf ' Active slots         %s / %s\n' "$SLOT_ACTIVE_COUNT" "$SLOT_COUNT"
    printf ' Decode live          %9s tok/s   ' "$GEN_LIVE"
    spark "${gen_hist[@]}"
    printf '  min %s  max %s' "$gen_min" "$gen_max"
    printf '\n Prefill sampled      %9s tok/s   ' "$PROMPT_LIVE"
    spark "${prompt_hist[@]}"
    printf '  min %s  max %s' "$prompt_min" "$prompt_max"
    printf '\n                      Min/max: nonzero samples since model selection (tok/s).'
    printf '\n\n Counter scope        %s\n' "$COUNTER_SCOPE"
    printf ' Context tokens       %9s  (sequence count, including output tokens)\n' "$DISPLAY_CONTEXT"
    printf ' Prefill tokens       %9s  (input tokens processed after cache reuse)\n' "$DISPLAY_PREFILL"
    printf ' Prompt cached/reused %9s  (explicit slot field, when available)\n' "$DISPLAY_CACHED"
    printf ' Decoded tokens       %9s\n' "$DISPLAY_DECODED"
    printf ' Sample delta         prefill=%s  decode=%s  over %.2fs\n' "$SLOT_PROMPT_DELTA" "$SLOT_DECODED_DELTA" "$SAMPLE_DT"
    echo '                      Prefill sampled = tokens observed per poll interval.'
    echo '                      Decode needs two samples of the same request.'
    [[ "$SLOT_ACTIVE_COUNT" == "0" ]] && echo '                      Saved counts may omit final tokens between polls.'

    echo
    echo '──────────────────────────── /metrics AGGREGATE ────────────────────────────────'
    printf ' Decode average       %9s tok/s  (aggregate gauge, not live)\n' "$GEN_AVG"
    printf ' Prefill average      %9s tok/s  (aggregate gauge, not live)\n' "$PROMPT_AVG"
    printf ' Requests             processing=%s  queued=%s\n' "$PROCESSING" "$DEFERRED"
    printf ' Reported totals      prompt=%s  generated=%s\n' "$PROMPT_METRIC_TOTAL" "$GENERATED_METRIC_TOTAL"

    echo
    echo '───────────────────────────────── CONTEXT ──────────────────────────────────────'
    printf ' Current context      %s / %s  %s%%  ' "$CTX_CURRENT" "$CTX_CAPACITY" "$CTX_PCT"
    context_bar "$CTX_CURRENT" "$CTX_CAPACITY"
    printf '\n Context capacity     %s tokens\n Current context %%    %s%%\n' "$CTX_CAPACITY" "$CTX_PCT"
    printf ' Context scope        all %s reported slot(s), including retained idle sequences\n' "$SLOT_COUNT"
    printf ' High-water context   %s tokens  (/metrics n_tokens_max)\n' "$CTX_HI"
    echo '                      Largest sequence observed; separate from current context.'

    echo
    echo '────────────────────────────────── MTP ─────────────────────────────────────────'
    printf ' Acceptance           %s%%\n Accepted             %s\n Draft tokens         %s\n Verify steps         %s\n' \
        "$MTP_TOTAL" "$ACCEPTED" "$DRAFT" "$DRAFT_STEPS"
    echo '                      Aggregate statistics; may update only on request completion.'
    echo '                      Updates during generation are not guaranteed.'

    echo
    echo '────────────────────────────────── SLOTS ───────────────────────────────────────'
    printf '%-4s %-8s %-7s %-8s %-8s %-8s %-8s %-8s %-7s %-6s %-6s %-6s\n' \
        'ID' 'STATE' 'TASK' 'CAPACITY' 'CONTEXT' 'PREFILL' 'CACHED' 'DECODED' 'REMAIN' 'TEMP' 'TOP_P' 'SPEC'
    jq -r '
        def show: if . == null then "n/a" else tostring end;
        def r3: if type == "number" then ((. * 1000 | round) / 1000) else . end;
        .[] | [
            .id, (if .active == true then "RUNNING" elif .active == false then "idle" else "unknown" end),
            .task, .capacity, .context, .evaluated, .cached, .decoded, .remain,
            (.temperature | r3), (.top_p | r3),
            (if .speculative == true then "yes" elif .speculative == false then "no" else null end)
        ] | map(show) | @tsv
    ' <<< "$SLOTS" |
    while IFS=$'\t' read -r id state task capacity context evaluated cached decoded remain temp topp spec; do
        printf '%-4s %-8s %-7s %-8s %-8s %-8s %-8s %-8s %-7s %-6s %-6s %-6s\n' \
            "$id" "$state" "$task" "$capacity" "$context" "$evaluated" "$cached" "$decoded" "$remain" "$temp" "$topp" "$spec"
    done
    echo ' PREFILL = input tokens processed after reuse; CACHED = explicit reused-token count.'

    echo
    echo '──────────────────────────── ACTIVE SLOT DETAILS ───────────────────────────────'
    ACTIVE_DETAILS="$(jq -r '
        def show: if . == null then "n/a" else tostring end;
        def r3: if type == "number" then ((. * 1000 | round) / 1000) else . end;
        .[] | select(.active == true) |
        "slot \(.id): min_p=\(.min_p | r3 | show)  top_k=\(.top_k | show)  reasoning=\(.reasoning | show)  " +
        "spec_nmax=\(.spec_nmax | show)  spec_nmin=\(.spec_nmin | show)  spec_pmin=\(.spec_pmin | r3 | show)"
    ' <<< "$SLOTS")"
    if [[ -n "$ACTIVE_DETAILS" ]]; then
        printf '%s\n' "$ACTIVE_DETAILS"
    else
        echo '(no active slot details available)'
    fi

    if [[ "$SHOW_ALL_METRICS" == "1" ]]; then
        echo
        echo '────────────────────────────── ALL /metrics ───────────────────────────────────'
        printf '%-68s %14s\n' 'METRIC' 'VALUE'
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            printf '%-68.68s %14.6g\n' "$key" "${curr[$key]}"
        done < <(printf '%s\n' "${!curr[@]}" | sort)
    fi

    [[ "$MODELS_OK" == "0" ]] && endpoint_error "$BASE/models" "$MODELS_CODE" "$MODELS_ERROR" "$MODELS"
    [[ "$METRICS_OK" == "0" ]] && endpoint_error "$METRICS_URL" "$METRICS_CODE" "$METRICS_ERROR" "$METRICS"
    [[ "$SLOTS_OK" == "0" ]] && endpoint_error "$SLOTS_URL" "$SLOTS_CODE" "$SLOTS_ERROR" "$SLOTS_BODY"
    echo
    echo ' q = quit   |   --raw = exact endpoint bodies   |   n/a = unavailable'
    )"
    present_frame "$FRAME"
    responsive_sleep "$INTERVAL"
done
