# 从 macOS 系统代理读取 ExceptionsList，返回逗号分隔字符串
_proxy_read_noproxy() {
  local out
  out=$(scutil --proxy 2>/dev/null) || return
  awk '
    /ExceptionsList.*\{/ { inside=1; next }
    inside && /^[[:space:]]*\}[[:space:]]*$/ { inside=0; next }
    inside {
      sub(/^[^:]*:[[:space:]]*/,"")
      result = (result == "" ? $0 : result "," $0)
    }
    END { if (result != "") print result }
  ' <<< "$out"
}

# 从 macOS 系统代理读取 http/https/socks5 配置；任意一种存在即成功
_proxy_read_system() {
  local out
  out=$(scutil --proxy 2>/dev/null) || return 1

  local http_enable http_host http_port
  http_enable=$(awk '/HTTPEnable/{print $3}'  <<< "$out")
  http_host=$(awk   '/^ *HTTPProxy /{print $3}' <<< "$out")
  http_port=$(awk   '/HTTPPort/{print $3}'    <<< "$out")

  local https_enable https_host https_port
  https_enable=$(awk '/HTTPSEnable/{print $3}'  <<< "$out")
  https_host=$(awk   '/^ *HTTPSProxy /{print $3}' <<< "$out")
  https_port=$(awk   '/HTTPSPort/{print $3}'    <<< "$out")

  local socks_enable socks_host socks_port
  socks_enable=$(awk '/SOCKSEnable/{print $3}'  <<< "$out")
  socks_host=$(awk   '/^ *SOCKSProxy /{print $3}' <<< "$out")
  socks_port=$(awk   '/SOCKSPort/{print $3}'    <<< "$out")

  if [[ "$http_enable" == "1" && -n "$http_host" && -n "$http_port" ]] || [[ "$https_enable" == "1" && -n "$https_host" && -n "$https_port" ]] || [[ "$socks_enable" == "1" && -n "$socks_host" && -n "$socks_port" ]]; then
    echo "${http_host} ${http_port} ${https_host} ${https_port} ${socks_host} ${socks_port}"
    return 0
  fi

  return 1
}

# 从系统代理读取并更新当前代理配置，失败则保留上次值
_proxy_sync_from_system() {
  local info
  info=$(_proxy_read_system) || return
  _PROXY_HTTP_HOST=$(awk '{print $1}' <<< "$info")
  _PROXY_HTTP_PORT=$(awk '{print $2}' <<< "$info")
  _PROXY_HTTPS_HOST=$(awk '{print $3}' <<< "$info")
  _PROXY_HTTPS_PORT=$(awk '{print $4}' <<< "$info")
  _PROXY_SOCKS_HOST=$(awk '{print $5}' <<< "$info")
  _PROXY_SOCKS_PORT=$(awk '{print $6}' <<< "$info")
  _PROXY_NOPROXY=$(_proxy_read_noproxy)
}

# 默认值，可在 source 前通过环境变量覆盖
: "${PROXY_DEFAULT_HOST:=127.0.0.1}"
: "${PROXY_DEFAULT_PORT:=7897}"
: "${PROXY_DEFAULT_HTTP_HOST:=${PROXY_DEFAULT_HOST}}"
: "${PROXY_DEFAULT_HTTP_PORT:=${PROXY_DEFAULT_PORT}}"
: "${PROXY_DEFAULT_HTTPS_HOST:=${PROXY_DEFAULT_HTTP_HOST}}"
: "${PROXY_DEFAULT_HTTPS_PORT:=${PROXY_DEFAULT_HTTP_PORT}}"
: "${PROXY_DEFAULT_SOCKS_HOST:=${PROXY_DEFAULT_HOST}}"
: "${PROXY_DEFAULT_SOCKS_PORT:=${PROXY_DEFAULT_PORT}}"

# 心跳开关和参数，可在 source 前通过环境变量覆盖
: "${PROXY_HEARTBEAT_ENABLED:=1}"
: "${PROXY_HEARTBEAT_INTERVAL:=30}"
: "${PROXY_HEARTBEAT_URL:=https://www.gstatic.com/generate_204}"
: "${PROXY_HEARTBEAT_TIMEOUT:=3}"
: "${PROXY_CHECK_ON_SOURCE:=1}"
# precmd hook 开关（独立于心跳逻辑；0 可禁用自动挂载但保留手动 proxy-heartbeat）
: "${PROXY_PRECMD_ENABLED:=${PROXY_HEARTBEAT_ENABLED}}"
# 追加到 no_proxy 的额外条目（逗号分隔），在系统配置之外叠加
: "${PROXY_NO_PROXY_EXTRA:=}"

# 兜底值（系统代理未配置时使用）
_PROXY_HTTP_HOST="${PROXY_DEFAULT_HTTP_HOST}"
_PROXY_HTTP_PORT="${PROXY_DEFAULT_HTTP_PORT}"
_PROXY_HTTPS_HOST="${PROXY_DEFAULT_HTTPS_HOST}"
_PROXY_HTTPS_PORT="${PROXY_DEFAULT_HTTPS_PORT}"
_PROXY_SOCKS_HOST="${PROXY_DEFAULT_SOCKS_HOST}"
_PROXY_SOCKS_PORT="${PROXY_DEFAULT_SOCKS_PORT}"
_PROXY_NOPROXY=""

# 初始化时同步一次
_proxy_sync_from_system

# 上次心跳时间（epoch 秒）
_proxy_last_check=0

# 内部：返回指定协议的代理 URL
_proxy_url() {
  local kind="${1}"

  if [[ "${kind}" == "http" ]]; then
    [[ -n "${_PROXY_HTTP_HOST}" && -n "${_PROXY_HTTP_PORT}" ]] || return 1
    echo "http://${_PROXY_HTTP_HOST}:${_PROXY_HTTP_PORT}"
    return 0
  fi

  if [[ "${kind}" == "https" ]]; then
    [[ -n "${_PROXY_HTTPS_HOST}" && -n "${_PROXY_HTTPS_PORT}" ]] || return 1
    echo "http://${_PROXY_HTTPS_HOST}:${_PROXY_HTTPS_PORT}"
    return 0
  fi

  if [[ "${kind}" == "socks5" ]]; then
    [[ -n "${_PROXY_SOCKS_HOST}" && -n "${_PROXY_SOCKS_PORT}" ]] || return 1
    echo "socks5://${_PROXY_SOCKS_HOST}:${_PROXY_SOCKS_PORT}"
    return 0
  fi

  return 1
}

# 内部：返回心跳使用的代理 URL，优先 HTTP，降级 SOCKS5
_proxy_probe_url() {
  _proxy_url https || _proxy_url http || _proxy_url socks5
}

# 内部：TCP 探测端口是否可达，成功返回 0
_proxy_probe_tcp_one() {
  local host="${1}"
  local port="${2}"
  [[ -n "${host}" && -n "${port}" ]] || return 1

  if command -v nc >/dev/null 2>&1; then
    nc -z -w 1 "${host}" "${port}" >/dev/null 2>&1
  else
    command bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

_proxy_probe_tcp() {
  _proxy_probe_tcp_one "${_PROXY_HTTPS_HOST}" "${_PROXY_HTTPS_PORT}" || _proxy_probe_tcp_one "${_PROXY_HTTP_HOST}" "${_PROXY_HTTP_PORT}" || _proxy_probe_tcp_one "${_PROXY_SOCKS_HOST}" "${_PROXY_SOCKS_PORT}"
}

# 内部：通过代理发起一次真实请求，成功返回 0
_proxy_probe_http() {
  local probe_url
  command -v curl >/dev/null 2>&1 || return 1
  probe_url="$(_proxy_probe_url)" || return 1
  curl --silent --show-error --fail \
    --connect-timeout "${PROXY_HEARTBEAT_TIMEOUT}" \
    --max-time "${PROXY_HEARTBEAT_TIMEOUT}" \
    --proxy "${probe_url}" \
    "${PROXY_HEARTBEAT_URL}" \
    >/dev/null 2>&1
}

# 内部：优先真实 HTTP 心跳，失败时回退 TCP 探测
_proxy_probe() {
  if [[ -n "${PROXY_HEARTBEAT_URL}" ]]; then
    _proxy_probe_http || _proxy_probe_tcp
  else
    _proxy_probe_tcp
  fi
}

# 内部：清理所有代理环境变量
_proxy_clear() {
  unset http_proxy https_proxy all_proxy
  unset HTTP_PROXY HTTPS_PROXY ALL_PROXY
  unset no_proxy NO_PROXY
}

# 内部：设置所有代理环境变量
_proxy_apply() {
  local http_proxy_url https_proxy_url socks_proxy_url
  http_proxy_url="$(_proxy_url http 2>/dev/null)"
  https_proxy_url="$(_proxy_url https 2>/dev/null)"
  socks_proxy_url="$(_proxy_url socks5 2>/dev/null)"

  if [[ -n "${http_proxy_url}" ]]; then
    export http_proxy="${http_proxy_url}"
    export HTTP_PROXY="${http_proxy_url}"
  elif [[ -n "${socks_proxy_url}" ]]; then
    export http_proxy="${socks_proxy_url}"
    export HTTP_PROXY="${socks_proxy_url}"
  fi

  if [[ -n "${https_proxy_url}" ]]; then
    export https_proxy="${https_proxy_url}"
    export HTTPS_PROXY="${https_proxy_url}"
  elif [[ -n "${http_proxy_url}" ]]; then
    export https_proxy="${http_proxy_url}"
    export HTTPS_PROXY="${http_proxy_url}"
  elif [[ -n "${socks_proxy_url}" ]]; then
    export https_proxy="${socks_proxy_url}"
    export HTTPS_PROXY="${socks_proxy_url}"
  fi

  if [[ -n "${socks_proxy_url}" ]]; then
    export all_proxy="${socks_proxy_url}"
    export ALL_PROXY="${socks_proxy_url}"
  elif [[ -n "${http_proxy_url}" ]]; then
    export all_proxy="${http_proxy_url}"
    export ALL_PROXY="${http_proxy_url}"
  fi

  # 构建 no_proxy：系统 ExceptionsList + 固定本地地址 + 用户扩展
  local _noproxy="127.0.0.1,localhost"
  [[ -n "${_PROXY_NOPROXY}" ]] && _noproxy="${_PROXY_NOPROXY},${_noproxy}"
  [[ -n "${PROXY_NO_PROXY_EXTRA}" ]] && _noproxy="${_noproxy},${PROXY_NO_PROXY_EXTRA}"
  export no_proxy="${_noproxy}"
  export NO_PROXY="${_noproxy}"
}

# 内部：是否存在任意代理环境变量
_proxy_env_is_set() {
  [[ -n "${http_proxy}${https_proxy}${all_proxy}${HTTP_PROXY}${HTTPS_PROXY}${ALL_PROXY}" ]]
}

proxy_env_refresh() {
  local silent="${1:-0}"
  _proxy_sync_from_system

  if _proxy_probe; then
    _proxy_apply
    [[ "${silent}" != "1" ]] && echo "proxy enabled: $(_proxy_describe)"
  else
    _proxy_clear
    [[ "${silent}" != "1" ]] && echo "proxy disabled"
  fi
}

proxy_env_off() {
  _proxy_clear
  echo "proxy disabled"
}

proxy_env_status() {
  local state="disabled"
  local heartbeat_state="off"

  _proxy_env_is_set && state="enabled"
  [[ "${PROXY_HEARTBEAT_ENABLED}" == "1" ]] && heartbeat_state="on"

  echo "proxy env: ${state}"
  echo "proxy target: $(_proxy_describe)"
  echo "no_proxy: ${no_proxy:-<unset>}"
  echo "heartbeat: ${heartbeat_state} (interval=${PROXY_HEARTBEAT_INTERVAL}s, precmd=${PROXY_PRECMD_ENABLED})"

  if [[ -n "${PROXY_HEARTBEAT_URL}" ]]; then
    echo "heartbeat url: ${PROXY_HEARTBEAT_URL}"
  else
    echo "heartbeat url: <tcp probe only>"
  fi
}

_proxy_describe() {
  local parts=()

  if [[ -n "${_PROXY_HTTP_HOST}" && -n "${_PROXY_HTTP_PORT}" ]]; then
    parts+=("http://${_PROXY_HTTP_HOST}:${_PROXY_HTTP_PORT}")
  fi

  if [[ -n "${_PROXY_HTTPS_HOST}" && -n "${_PROXY_HTTPS_PORT}" ]]; then
    parts+=("https->http://${_PROXY_HTTPS_HOST}:${_PROXY_HTTPS_PORT}")
  fi

  if [[ -n "${_PROXY_SOCKS_HOST}" && -n "${_PROXY_SOCKS_PORT}" ]]; then
    parts+=("socks5://${_PROXY_SOCKS_HOST}:${_PROXY_SOCKS_PORT}")
  fi

  if (( ${#parts[@]} == 0 )); then
    echo "<unset>"
  else
    echo "${(j: , :)parts}"
  fi
}

# 心跳检测：每次显示提示符前触发，节流至 PROXY_HEARTBEAT_INTERVAL 秒一次
# 代理恢复时自动设置变量，代理失联时自动清理变量
_proxy_heartbeat() {
  [[ "${PROXY_HEARTBEAT_ENABLED}" == "1" ]] || return

  local now
  now=$(date +%s)
  (( now - _proxy_last_check < PROXY_HEARTBEAT_INTERVAL )) && return
  _proxy_last_check=$now

  # 每次心跳同步系统代理地址（地址可能已变更）
  _proxy_sync_from_system

  if _proxy_probe; then
    if ! _proxy_env_is_set; then
      _proxy_apply
    fi
  else
    if _proxy_env_is_set; then
      _proxy_clear
      echo "[proxy] heartbeat failed, proxy env cleared" >&2
    fi
  fi
}

autoload -Uz add-zsh-hook
if [[ "${PROXY_PRECMD_ENABLED}" == "1" ]]; then
  add-zsh-hook precmd _proxy_heartbeat
fi

alias proxy-refresh='proxy_env_refresh'
alias proxy-refresh-silent='proxy_env_refresh 1'
alias proxy-heartbeat='_proxy_heartbeat'
alias proxy-on='proxy_env_refresh'
alias proxy-off='proxy_env_off'
alias proxy-status='proxy_env_status'

if [[ "${PROXY_CHECK_ON_SOURCE}" == "1" ]]; then
  proxy_env_refresh 1
fi
