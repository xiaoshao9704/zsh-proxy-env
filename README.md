# zsh-proxy-env

A lightweight Zsh plugin that automatically manages proxy environment variables on macOS.

It reads proxy settings from the macOS system configuration, probes reachability on every prompt, and keeps `http_proxy` / `https_proxy` / `all_proxy` / `no_proxy` in sync — without any manual intervention.

## Features

- **Auto-sync from system** — reads HTTP, HTTPS, and SOCKS5 proxy settings via `scutil --proxy`
- **Auto-sync `no_proxy`** — reads system `ExceptionsList` and merges it with local defaults
- **Heartbeat probe** — verifies proxy reachability before each prompt (throttled, configurable interval)
- **Graceful fallback** — TCP port probe when HTTP probe is unavailable
- **Hot-reload** — detects proxy address changes between heartbeats
- **Zero dependencies** — only requires `zsh`, `scutil`, and optionally `curl` / `nc`

## Installation

### Manual

```zsh
# Clone anywhere
git clone https://github.com/YOUR_USERNAME/zsh-proxy-env.git ~/.config/shell/zsh-proxy-env

# Add to ~/.zshrc
source ~/.config/shell/zsh-proxy-env/proxy_env.zsh
```

### Oh My Zsh

```zsh
git clone https://github.com/YOUR_USERNAME/zsh-proxy-env.git \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-proxy-env
```

Then add `zsh-proxy-env` to your `plugins` list in `~/.zshrc`.

### Zinit

```zsh
zinit light YOUR_USERNAME/zsh-proxy-env
```

## Configuration

All options can be set **before** sourcing the plugin:

```zsh
# Fallback proxy when system proxy is not configured (default: 127.0.0.1:7897)
export PROXY_DEFAULT_HOST=127.0.0.1
export PROXY_DEFAULT_PORT=7897

# Override per-protocol fallback
export PROXY_DEFAULT_HTTP_HOST=127.0.0.1
export PROXY_DEFAULT_HTTP_PORT=7890
export PROXY_DEFAULT_HTTPS_HOST=127.0.0.1
export PROXY_DEFAULT_HTTPS_PORT=7890
export PROXY_DEFAULT_SOCKS_HOST=127.0.0.1
export PROXY_DEFAULT_SOCKS_PORT=7891

# Heartbeat: check proxy reachability on each prompt
export PROXY_HEARTBEAT_ENABLED=1      # 1 = on, 0 = off
export PROXY_HEARTBEAT_INTERVAL=30    # seconds between checks
export PROXY_HEARTBEAT_URL=https://www.gstatic.com/generate_204  # set empty for TCP-only
export PROXY_HEARTBEAT_TIMEOUT=3      # curl connect/max timeout in seconds

# precmd hook registration (independent of heartbeat logic)
# Set to 0 to disable automatic hooks while keeping `proxy-heartbeat` command available
export PROXY_PRECMD_ENABLED=1

# Run a reachability check immediately on source (default: 1)
export PROXY_CHECK_ON_SOURCE=1

# Extra no_proxy entries appended after system ExceptionsList (comma-separated)
export PROXY_NO_PROXY_EXTRA="corp.internal,10.0.0.0/8"

source /path/to/proxy_env.zsh
```

### `PROXY_PRECMD_ENABLED` vs `PROXY_HEARTBEAT_ENABLED`

| `PROXY_PRECMD_ENABLED` | `PROXY_HEARTBEAT_ENABLED` | Result |
|---|---|---|
| 1 | 1 | Full auto-heartbeat (default) |
| 0 | 1 | No auto-hook; run `proxy-heartbeat` manually |
| 1 | 0 | Hook registered but heartbeat logic is skipped |
| 0 | 0 | Fully manual mode |

## Commands

| Command | Description |
|---|---|
| `proxy-on` | Sync system proxy and enable if reachable |
| `proxy-off` | Clear all proxy environment variables |
| `proxy-status` | Show current state, target addresses, and heartbeat config |
| `proxy-refresh` | Same as `proxy-on`, with output |
| `proxy-refresh-silent` | Same as `proxy-on`, no output |
| `proxy-heartbeat` | Manually trigger one heartbeat cycle |

### Example output

```
$ proxy-status
proxy env: enabled
proxy target: http://127.0.0.1:7890, https->http://127.0.0.1:7890, socks5://127.0.0.1:7891
no_proxy: *.local,169.254/16,127.0.0.1,localhost
heartbeat: on (interval=30s, precmd=1)
heartbeat url: https://www.gstatic.com/generate_204
```

## How it works

```
Each prompt (precmd, throttled)
  └── _proxy_sync_from_system
  │     ├── scutil --proxy  →  HTTP/HTTPS/SOCKS5 host:port
  │     └── ExceptionsList  →  _PROXY_NOPROXY
  └── _proxy_probe
  │     ├── curl via proxy  (HTTP heartbeat)
  │     └── nc / /dev/tcp   (TCP fallback)
  ├── reachable  →  _proxy_apply  (export env vars)
  └── unreachable →  _proxy_clear (unset env vars)
```

`no_proxy` is built in three layers:
1. System `ExceptionsList` (from `scutil --proxy`)
2. Fixed local addresses: `127.0.0.1,localhost`
3. `PROXY_NO_PROXY_EXTRA` (user-defined)

## License

MIT
