# llamatop

A small terminal monitor for **Jan and llama.cpp routers**.

Watch decode speed, prefill, context usage, and speculative decoding from one Bash script. It polls your server's HTTP endpoints and follows the model doing the work.

```text
llamatop — Jan / llama.cpp

Model                 Qwen3_8-27B-UD-Q6_K_XL  [auto]
State                 DECODE

Decode live               15.31 tok/s   ▁▂▄▆▅█▆▄  min 14.20  max 18.40
Prefill sampled            0.00 tok/s   ········  min 62.50  max 84.20

Current context       30328 / 73728  41.1%  [████████████░░░░░░░░░░░░░░░░░░]
High-water context    31137 tokens

q = quit · j/k = scroll
```

*Illustrative, abridged output.*

- **Live decode** from slot token deltas, with sparklines and min/max rates.
- **Current context** on a fixed 0–100% bar, separate from the high-water mark.
- **Automatic model selection**, or pin a specific model.
- **Stable terminal updates** with responsive scrolling, even during slow server requests.
- **Exact raw responses** for debugging API errors and server differences.

## Quick start

Run in **Bash on Linux or WSL**. Requires Bash 4.3+, `curl`, `jq`, `awk`, and standard GNU utilities such as `date` and `mktemp`.

On Ubuntu / Debian, including Ubuntu under WSL:

```bash
sudo apt update
sudo apt install -y git curl jq gawk

git clone https://github.com/Laz4rz/llamatop.git
cd llamatop
./llamatop.sh http://127.0.0.1:6767 'YOUR_API_KEY' 0.5
```

Replace the URL and API key with your server's settings. Use `''` as the key if authentication is disabled. Start your server and load a model first; llamatop waits when none is loaded.

The server should expose `/models`, `/slots`, and `/metrics`. In llama.cpp, `/metrics` requires `--metrics`; slot endpoint availability depends on the build and server configuration. See the [llama.cpp server documentation](https://github.com/ggml-org/llama.cpp/tree/master/tools/server#api-endpoints).

## Usage

```text
./llamatop.sh [BASE_URL] [API_KEY] [INTERVAL] [MODEL] [--raw | --raw-watch]
```

| Argument | Default | Meaning |
| --- | --- | --- |
| `BASE_URL` | `http://127.0.0.1:6767` | Server address, without `/v1`. |
| `API_KEY` | Empty | Sent as a Bearer token. |
| `INTERVAL` | `2` | Seconds between polls; accepts decimals. |
| `MODEL` | Auto | Exact model ID to monitor. |

The first three arguments are positional. Supply them before a model ID or raw-mode flag, using `''` for an empty key. The interval is the pause between polls; requests and rendering add to the actual elapsed time.

```bash
# Defaults: localhost:6767, no API key, 2-second interval
./llamatop.sh

# Faster refresh, without the full Prometheus metrics table
SHOW_ALL_METRICS=0 ./llamatop.sh http://127.0.0.1:6767 'YOUR_API_KEY' 0.2

# Pin a model
./llamatop.sh http://127.0.0.1:6767 'YOUR_API_KEY' 0.5 Qwen3_8-27B-UD-Q6_K_XL

# Increase the sparkline history from 30 to 60 samples
HISTORY_LEN=60 ./llamatop.sh http://127.0.0.1:6767 'YOUR_API_KEY' 0.5
```

Dashboard controls: **`q`** quits; **`j` / `k`** scroll one row at a time when the display is taller than the terminal. Hold either key to keep scrolling. Input and resizing work independently of the polling interval and server response time. Widen the terminal if a row is clipped. `Ctrl+C` also exits, including in raw-watch mode.

With multiple loaded models, the dashboard prefers one with an active slot. When all are idle, it stays with the previously selected model if still loaded. Requests to `/slots` and `/metrics` include `autoload=false`.

## Reading the dashboard

| Reading | What it means |
| --- | --- |
| **Decode live** | Change in `next_token.n_decoded` divided by actual elapsed time, matched by slot and request. Needs two samples of the same request. |
| **Prefill sampled** | Newly observed `n_prompt_tokens_processed` per polling interval. Includes prefill captured at an observed request change. This is a sampled rate, not the exact prefill execution speed. |
| **Min / max** | Lowest and highest **nonzero sampled rates** since model selection. Excludes idle zeros and missing samples; resets when the selected model changes. |
| **Current context** | Sum of `/slots[].n_prompt_tokens` over the reported slots, including retained idle sequences. Capacity comes from the corresponding `n_ctx` fields. |
| **High-water context** | `llamacpp:n_tokens_max`: the largest sequence observed, separate from current usage. |
| **Prefill tokens** | Input tokens actually processed for the request after cache reuse. |
| **Prompt cached/reused** | The explicit `n_prompt_tokens_cache` field, when provided. |
| **Decode / prefill average** | llama.cpp's aggregate throughput gauges from `/metrics`, rather than live rates. |
| **MTP** | Aggregate speculative decoding acceptance and draft counters. Availability depends on the server build; updates may wait until request completion. |

**Context already includes generated tokens.** `n_decoded` is never added to `n_prompt_tokens`.

The **Counter scope** line tells you whether request counts are active or retained. After completion, llamatop keeps the last observed request per slot because the server may clear its statistics. These saved counts can miss final tokens between polls; they do not feed live rates or current context occupancy. A separate **Request context** row appears only when that count differs from current context.

Rate sparklines scale to their history; the context bar always uses **0–100%**. All-zero history shows dots. `n/a` means unavailable, and `?` marks an unavailable sparkline sample. Short requests can finish entirely between polls, so not every prefill will appear in the graph.

## Troubleshooting

Start with an exact endpoint dump:

```bash
./llamatop.sh http://127.0.0.1:6767 'YOUR_API_KEY' 2 --raw

# Repeat snapshots until Ctrl+C
./llamatop.sh http://127.0.0.1:6767 'YOUR_API_KEY' 2 --raw-watch
```

Raw mode prints the HTTP status and unmodified body, including original trailing newlines, for:

```text
GET /models
GET /metrics?model=...&autoload=false
GET /slots?model=...&autoload=false
```

Bodies appear between markers; the newline before each end marker belongs to the wrapper. Raw mode uses a pinned model or the first loaded model. If `/models` fails, provide a model ID before `--raw` to query the other endpoints anyway.

| Symptom | Check |
| --- | --- |
| `401` | API key and server authentication settings. |
| `404` | Base URL, model ID, and whether the server exposes these router endpoints. |
| `501` | The response body identifies an unsupported or disabled endpoint. Enable the corresponding server feature if available. |
| No loaded model | Load one in Jan / your router, or specify the intended model ID. |
| MTP shows `n/a` | The server has not exposed those counters. Speculation can be enabled without those metrics being available. |
| Zero prefill rate during decode | Prefill has finished. Check the prefill token count, history, and counter scope. |

**Windows server, WSL monitor:** with mirrored networking, use `127.0.0.1`. Under WSL's default NAT networking, use the Windows host IP and make sure the server's listening address and firewall permit that connection. See [Microsoft's WSL networking guide](https://learn.microsoft.com/en-us/windows/wsl/networking#accessing-windows-networking-apps-from-linux-host-ip).

## Contributing

Small fixes and server compatibility improvements are welcome. For a bug report, include the server/build version, launch command with the API key removed, and relevant `--raw` output. Remove private prompt text before sharing it.

Check Bash syntax before sending a change:

```bash
bash -n llamatop.sh
```

[Report an issue](https://github.com/Laz4rz/llamatop/issues) · [Read the script](llamatop.sh)
