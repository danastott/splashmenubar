# Splash Menu Bar

A macOS menu bar app that runs `splash serve`, keeps it alive, and shows its
live inference metrics.

## What it does

- **Auto-start**: launching the app starts `splash serve` with the configured
  parameters (see Settings below).
- **Start / Stop / Restart**: the flyout's button bar switches between a
  green **Start** and a red **Stop** based on whether a server is actually
  serving the configured port. **Stop** shuts the server down even when it
  was started outside the app (it finds the listener and the native engine
  on the port, SIGTERMs them, and SIGKILLs after 5 s). If the server dies on
  its own the flyout shows a crashed state and offers to start it again.
  Quitting the app reaps only its own child; an externally started server is
  left running.
- **Live metrics** from the server's `GET /status` endpoint, polled every
  2 s:
  - **tok/s gauge** (live decode batch, falling back to the lifetime decode
    speed and the last log-parsed request) and a **cache-hit gauge**
    (`cache.hit_rate`)
  - **tok/s line graph over time** (sampled from the polled status)
  - load: completed/cancelled/failed requests, TTFT p50/p95, prefill and
    decode speed, total output, active requests (decode/prefill/queued),
    memory, uptime, thermal state
  - **prefill progress**: while a request is in its prompt phase,
    `prompt_processed / prompt_tokens` from `active_requests` with an
    estimated time left (remaining tokens ÷ current prefill speed)
- **Last request** detail (from splash's stdout lines): output, input/cached,
  deduplicated, TTFT, tok/cycle.
- The status bar item shows the live tok/s, e.g. `▣ 78.5 t/s`.

## Build

```sh
make          # builds SplashMenuBar.app (needs the Xcode/CLT Swift toolchain)
make run      # builds and launches
make clean
```

## Settings

Open the gear icon in the flyout (or press ⌘, after focusing it). The dialog
edits the full `splash serve` command line, persisted to
`~/.splashmenubar.json`; saving restarts the server:

| Field | Flag | Notes |
|---|---|---|
| Model | `--model` | e.g. `unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M` |
| Port | `--port` | e.g. `8081` |
| Max memory | `--max-memory` | e.g. `28G` (blank = auto) |
| Idle release | `--idle-release` | e.g. `off` (blank = default 10m) |
| Max context | `--max-context` | e.g. `100K` (blank = auto) |
| KV format | `--kv-format` | `int8` (default) or `bf16` |
| State format | `--state-format` | `fp32` (default) or `bf16` |
| Max cache disk | `--max-cache-disk` | e.g. `16G`; `0` turns it off (blank = auto) |
| Language only | `--language-only` | skip vision |
| Disable Neural Engine | `--disable-ane` | prefill on GPU alone |
| Persistent cache | `--persistent-cache` | keep the SSD cache across restarts |

Blank optional fields and default pickers omit the flag entirely.

`splash` is resolved from `PATH`; since apps launched from Finder get a
minimal PATH, `/opt/homebrew/bin`, `/usr/local/bin`, and `~/.local/bin` are
prepended automatically.

## How it works

- `SplashProcess` owns the `splash serve` child process, reads stdout/stderr
  on dedicated threads (blocking `availableData` loops) and dispatches
  complete lines to the main thread. `SplashParser` turns lines into events
  (Started/Done requests, thermal transitions, the Ready line, weights load).
- `StatusClient` polls `http://127.0.0.1:<port>/status` every 2 s;
  `MetricsStore` merges the polled snapshot with the log-derived per-request
  data into one `@Published` state.
- The flyout is a borderless, non-activating `NSPanel` positioned just below
  the menu bar on the status item's screen, clamped inside the screen (the
  body scrolls and the control bar stays pinned when it cannot fit). It
  dismisses on outside click, Escape, or clicking the status item again.

## Notes

- The app is unsigned; open it with `make run` or by double-clicking
  `SplashMenuBar.app` on your own machine.
- While a request is in flight the last completed values stay on screen;
  endpoint metrics update every 2 s.
