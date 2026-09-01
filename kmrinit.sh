#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TOOL_VERSION="0.1.4"
TOOL_NAME="kmrinit"
INSTALL_PATH="/usr/local/sbin/kmrinit"
SELF_URL="https://raw.githubusercontent.com/chenqingjian/vpsinit/main/kmrinit.sh"
CONFIG_DIR="/etc/kmrinit"
STATE_DIR="/var/lib/kmrinit"
LOG_DIR="/var/log/kmrinit"
STATE_FILE="$STATE_DIR/state.conf"
LOG_FILE="$LOG_DIR/kmrinit.log"
LOCK_FILE="/run/lock/kmrinit.lock"
KOMARI_DIR="/opt/komari"
KOMARI_BIN="$KOMARI_DIR/komari"
KOMARI_SERVICE_FILE="/etc/systemd/system/komari.service"
KOMARI_SERVICE="komari.service"
NGINX_SITE="/etc/nginx/sites-available/kmrinit-komari.conf"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/kmrinit-komari.conf"
NGINX_DEFAULT="/etc/nginx/conf.d/00-kmrinit-default.conf"
CERT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/90-kmrinit-reload-nginx"
IPV6_DISABLE_FILE="/proc/sys/net/ipv6/conf/all/disable_ipv6"
GITHUB_API_RELEASE="https://api.github.com/repos/komari-monitor/komari/releases/latest"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
log_info() { printf '%s[信息]%s %s\n' "$BLUE" "$NC" "$*" >&2; }
log_ok() { printf '%s[完成]%s %s\n' "$GREEN" "$NC" "$*" >&2; }
log_warn() { printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
log_error() { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; }
die() { local code="${2:-1}"; log_error "$1"; exit "$code"; }

RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kmrinit.XXXXXX")"
cleanup() { [[ -n "${RUNTIME_DIR:-}" && -d "$RUNTIME_DIR" && "$(basename "$RUNTIME_DIR")" == kmrinit.* ]] && rm -rf -- "$RUNTIME_DIR"; }
trap cleanup EXIT
trap 'log_error "第 $LINENO 行执行失败。"' ERR

make_temp() { mktemp "$RUNTIME_DIR/file.XXXXXX"; }
require_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 用户运行。" 3; }

check_platform() {
  [[ -r /etc/os-release ]] || die "无法识别操作系统。" 3
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == debian ]] || die "仅支持官方 Debian。" 3
  case "${VERSION_ID:-}" in 12|13) ;; *) die "仅支持 Debian 12 或 Debian 13。" 3 ;; esac
  [[ "$(uname -m)" == x86_64 ]] || die "仅支持 amd64/x86_64。" 3
  command -v systemctl >/dev/null 2>&1 || die "系统必须使用 systemd。" 3
}

ensure_dirs() {
  install -d -m 700 "$CONFIG_DIR" "$STATE_DIR"
  install -d -m 750 "$LOG_DIR"
  touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
}

start_logging() {
  [[ "${KMRINIT_LOGGING_STARTED:-0}" == 1 ]] && return
  export KMRINIT_LOGGING_STARTED=1
  exec > >(tee -a "$LOG_FILE") 2>&1
}

acquire_lock() { install -d -m 755 "$(dirname "$LOCK_FILE")"; exec 9>"$LOCK_FILE"; flock -n 9 || die "已有另一个 kmrinit 变更操作正在运行。"; }

download_file() {
  local url="$1" output="$2"
  curl --fail --show-error --location --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 2 --output "$output" "$url"
  [[ -s "$output" ]] || die "下载文件为空：$url" 5
}

bootstrap_self() {
  [[ "${KMRINIT_SKIP_BOOTSTRAP:-0}" == 1 ]] && return
  [[ "$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")" == "$INSTALL_PATH" ]] && return
  require_root
  local temp; temp="$(make_temp)"
  log_info "正在安装 kmrinit 到 $INSTALL_PATH"
  download_file "$SELF_URL" "$temp"
  grep -q 'TOOL_NAME="kmrinit"' "$temp" || die "下载内容不是预期的 kmrinit 脚本。" 5
  bash -n "$temp" || die "下载脚本语法检查失败。" 5
  install -o root -g root -m 0755 "$temp" "$INSTALL_PATH"
  log_ok "kmrinit 已安装。"
  exec "$INSTALL_PATH" "$@"
}

state_get() {
  local wanted="$1" key value; [[ -r "$STATE_FILE" ]] || return 1
  while IFS='=' read -r key value; do [[ "$key" == "$wanted" ]] && { printf '%s\n' "$value"; return 0; }; done < "$STATE_FILE"
  return 1
}

state_set() {
  local wanted="$1" new_value="$2" temp key value found=0
  ensure_dirs; temp="$(make_temp)"
  if [[ -r "$STATE_FILE" ]]; then
    while IFS='=' read -r key value; do
      [[ -z "$key" ]] && continue
      if [[ "$key" == "$wanted" ]]; then printf '%s=%s\n' "$wanted" "$new_value" >> "$temp"; found=1; else printf '%s=%s\n' "$key" "$value" >> "$temp"; fi
    done < "$STATE_FILE"
  fi
  [[ "$found" -eq 1 ]] || printf '%s=%s\n' "$wanted" "$new_value" >> "$temp"
  install -o root -g root -m 0600 "$temp" "$STATE_FILE"
}

state_delete() {
  local wanted="$1" temp key value; [[ -r "$STATE_FILE" ]] || return 0; temp="$(make_temp)"
  while IFS='=' read -r key value; do [[ -z "$key" || "$key" == "$wanted" ]] && continue; printf '%s=%s\n' "$key" "$value" >> "$temp"; done < "$STATE_FILE"
  install -o root -g root -m 0600 "$temp" "$STATE_FILE"
}

ask_yes_no() { local prompt="$1" default="${2:-n}" answer suffix; [[ "$default" == y ]] && suffix='[y/n，回车默认为y]' || suffix='[y/n，回车默认为n]'; read -r -p "$prompt $suffix " answer; answer="${answer:-$default}"; [[ "$answer" =~ ^[Yy]$ ]]; }
confirm_danger() { local answer; log_warn "$1"; read -r -p '请输入大写 YES 继续：' answer; [[ "$answer" == YES ]] || { log_warn "操作已取消。"; return 1; }; }

install_dependencies() {
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates nginx certbot python3-certbot-nginx dnsutils openssl iproute2 python3
}

package_is_installed() { dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii '; }

missing_stack_packages() {
  local package missing=()
  for package in nginx nginx-common nginx-core certbot python3-certbot-nginx; do
    package_is_installed "$package" || missing+=("$package")
  done
  local IFS=,
  printf '%s\n' "${missing[*]}"
}

purge_added_packages() {
  local value="$1" package
  [[ -n "$value" ]] || return 0
  local -a packages=()
  local IFS=,
  read -r -a packages <<<"$value"
  for package in "${packages[@]}"; do
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "$package" || log_warn "由 kmrinit 添加的软件包 $package 未能自动清理。"
  done
}

ensure_probe_dependencies() {
  DEBIAN_FRONTEND=noninteractive apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates dnsutils iproute2 python3
}

valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_email() { [[ -z "$1" || "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; }
valid_ipv4() { awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i<0 || $i>255) exit 1; exit 0} {exit 1}' <<<"$1"; }

read_domain() {
  local value
  while true; do read -r -p '请输入 Komari 访问域名：' value; value="${value,,}"; valid_domain "$value" && { printf '%s\n' "$value"; return; }; log_error "域名格式无效，请只输入域名。"; done
}

read_email() {
  local value
  while true; do read -r -p "Let's Encrypt 联系邮箱（默认留空）：" value; valid_email "$value" && { printf '%s\n' "$value"; return; }; log_error "邮箱格式无效。"; done
}

read_port() {
  local prompt="$1" default="$2" value
  while true; do read -r -p "$prompt [$default]：" value; value="${value:-$default}"; [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )) && { printf '%s\n' "$value"; return; }; log_error "端口必须是 1-65535 的整数。"; done
}

port_is_listening() { local port="$1"; ss -H -lntup 2>/dev/null | awk -v p=":$port" '$5 ~ p"$" {found=1} END {exit !found}'; }

show_port_owner() { local port="$1"; ss -lntup 2>/dev/null | awk -v p=":$port" 'NR==1 || $5 ~ p"$"'; }

require_free_port() {
  local port="$1"
  if port_is_listening "$port"; then log_error "端口 $port 已被占用："; show_port_owner "$port"; return 4; fi
}

read_komari_port() {
  local prompt="$1" default="$2" current="${3:-}" port
  while true; do
    port="$(read_port "$prompt" "$default")"
    if [[ -n "$current" && "$port" == "$current" ]]; then
      printf '%s\n' "$port"
      return
    fi
    if [[ "$port" == 80 || "$port" == 443 ]]; then
      log_error "Komari 内部端口不能使用 Nginx 固定占用的 80 或 443。"
      continue
    fi
    if require_free_port "$port"; then
      printf '%s\n' "$port"
      return
    fi
  done
}

detect_public_ipv4() {
  local first second
  first="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  second="$(curl -4fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '$1=="ip" {print $2}' || true)"
  valid_ipv4 "$first" && { [[ -z "$second" ]] || [[ "$first" == "$second" ]]; } || return 1
  printf '%s\n' "$first"
}

get_public_ipv4() {
  local detected value
  detected="$(detect_public_ipv4 || true)"
  [[ -n "$detected" ]] && { printf '%s\n' "$detected"; return; }
  while true; do
    read -r -p '无法可靠自动检测公网 IPv4，请手动输入：' value
    valid_ipv4 "$value" && { printf '%s\n' "$value"; return; }
    log_error "IPv4 格式无效。"
  done
}

query_a() {
  local domain="$1" resolver="${2:-}"
  if [[ -n "$resolver" ]]; then
    dig +short A "$domain" "$resolver" 2>/dev/null
  else
    dig +short A "$domain" 2>/dev/null
  fi | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u
}

check_domain_a() {
  local domain="$1" public_ip="$2" system_a cf_a google_a
  system_a="$(query_a "$domain" || true)"
  cf_a="$(query_a "$domain" @1.1.1.1 || true)"
  google_a="$(query_a "$domain" @8.8.8.8 || true)"
  log_info "当前公网 IPv4：$public_ip"
  printf '系统 DNS A 记录：%s\n' "${system_a:-无结果}"
  printf 'Cloudflare DNS A 记录：%s\n' "${cf_a:-无结果}"
  printf 'Google DNS A 记录：%s\n' "${google_a:-无结果}"
  local answers
  for answers in "$system_a" "$cf_a" "$google_a"; do
    [[ -n "$answers" ]] || return 1
    [[ "$(printf '%s\n' "$answers" | grep -Fvx "$public_ip" || true)" == "" ]] || return 1
    printf '%s\n' "$answers" | grep -Fxq "$public_ip" || return 1
  done
}

ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; }

ufw_allow_web() {
  if ! ufw_active; then log_warn "UFW 未启用，未自动创建 80/443 规则。"; return; fi
  local owned=0
  if ! ufw status | grep -Eq '^80/tcp[[:space:]]+ALLOW'; then
    ufw allow 80/tcp comment 'kmrinit-http'
    owned=$((owned | 1))
    state_set UFW_WEB "$owned"
  else
    log_warn "UFW 已有 80/tcp 规则，kmrinit 不取得其所有权。"
  fi
  if ! ufw status | grep -Eq '^443/tcp[[:space:]]+ALLOW'; then
    ufw allow 443/tcp comment 'kmrinit-https'
    owned=$((owned | 2))
    state_set UFW_WEB "$owned"
  else
    log_warn "UFW 已有 443/tcp 规则，kmrinit 不取得其所有权。"
  fi
  state_set UFW_WEB "$owned"
}

ufw_delete_web() {
  local owned failed=0; owned="$(state_get UFW_WEB 2>/dev/null || true)"; [[ "$owned" =~ ^[0-3]$ ]] || return 0
  if (( owned > 0 )) && ! command -v ufw >/dev/null 2>&1; then
    log_warn "未找到 UFW，无法删除 kmrinit 创建的规则，保留所有权记录。"
    return 1
  fi
  if (( owned & 1 )) && ! ufw --force delete allow 80/tcp >/dev/null 2>&1; then log_warn "无法删除由 kmrinit 创建的 UFW 80/tcp 规则。"; failed=1; fi
  if (( owned & 2 )) && ! ufw --force delete allow 443/tcp >/dev/null 2>&1; then log_warn "无法删除由 kmrinit 创建的 UFW 443/tcp 规则。"; failed=1; fi
  (( failed == 0 )) || return 1
  state_delete UFW_WEB
}

release_json() { curl -fsSL --connect-timeout 15 --max-time 60 -H 'Accept: application/vnd.github+json' "$GITHUB_API_RELEASE"; }

komari_release_info() {
  local json info
  json="$(release_json)" || die "无法读取 Komari 官方最新 Release。" 5
  info="$(printf '%s' "$json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
asset = next((a for a in data.get("assets", []) if a.get("name") == "komari-linux-amd64"), None)
if not asset or data.get("prerelease") or data.get("draft"):
    raise SystemExit(1)
print(data.get("tag_name", ""))
print(asset.get("browser_download_url", ""))
print(asset.get("digest") or "")
')" || die "未找到 Komari 官方 linux-amd64 稳定版资产。" 5
  [[ "$(printf '%s\n' "$info" | sed -n '1p')" != Snapshot-* ]] || die "GitHub latest 指向预览版本，拒绝安装。" 5
  printf '%s\n' "$info"
}

verify_release_digest() {
  local binary="$1" digest="$2" expected actual
  if [[ -z "$digest" ]]; then log_warn "Komari 官方 Release 未提供资产 digest。"; return 0; fi
  [[ "$digest" =~ ^sha256:([0-9a-fA-F]{64})$ ]] || die "Komari 官方资产 digest 格式异常。" 5
  expected="${BASH_REMATCH[1]}"
  actual="$(sha256sum "$binary" | awk '{print $1}')"
  [[ "${actual,,}" == "${expected,,}" ]] || die "Komari SHA-256 校验失败。" 5
  log_ok "Komari SHA-256 校验通过。"
}

download_komari() {
  local output="$1" info tag url digest
  info="$(komari_release_info)"
  tag="$(printf '%s\n' "$info" | sed -n '1p')"; url="$(printf '%s\n' "$info" | sed -n '2p')"; digest="$(printf '%s\n' "$info" | sed -n '3p')"
  download_file "$url" "$output"
  verify_release_digest "$output" "$digest"
  chmod 0755 "$output"
  "$output" --help >/dev/null 2>&1 || "$output" help >/dev/null 2>&1 || die "下载的 Komari 二进制无法执行。" 5
  printf '%s\n' "$tag"
}

write_komari_service() {
  local port="$1" temp
  temp="$(make_temp)"
  cat > "$temp" <<EOF
[Unit]
Description=Komari Server managed by kmrinit
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$KOMARI_DIR
ExecStart=$KOMARI_BIN server -l 127.0.0.1:$port
Restart=on-failure
RestartSec=5s
User=root
Group=root
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  install -o root -g root -m 0644 "$temp" "$KOMARI_SERVICE_FILE"
  systemctl daemon-reload
}

ipv6_listen_enabled() {
  [[ -r "$IPV6_DISABLE_FILE" ]] && [[ "$(<"$IPV6_DISABLE_FILE")" != 1 ]]
}

write_nginx_configs() {
  local domain="$1" port="$2" mode="${3:-http}" default_temp site_temp
  local v6_default_http="" v6_default_https="" v6_http="" v6_https=""
  if ipv6_listen_enabled; then
    v6_default_http='    listen [::]:80 default_server;'
    v6_default_https='    listen [::]:443 ssl default_server;'
    v6_http='    listen [::]:80;'
    v6_https='    listen [::]:443 ssl http2;'
  fi
  default_temp="$(make_temp)"; site_temp="$(make_temp)"
  cat > "$default_temp" <<EOF
# Managed by kmrinit
server {
    listen 80 default_server;
$v6_default_http
    server_name _;
    return 444;
}
server {
    listen 443 ssl default_server;
$v6_default_https
    server_name _;
    ssl_reject_handshake on;
}
EOF
  if [[ "$mode" == final ]]; then
    cat > "$site_temp" <<EOF
# Managed by kmrinit
server {
    listen 80;
$v6_http
    server_name $domain;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
$v6_https
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_connect_timeout 10s;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
  else
    cat > "$site_temp" <<EOF
# Managed by kmrinit
server {
    listen 80;
$v6_http
    server_name $domain;

    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_connect_timeout 10s;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
  fi
  install -d -m 0755 "$(dirname "$NGINX_SITE")"
  install -d -m 0755 "$(dirname "$NGINX_SITE_LINK")"
  install -d -m 0755 "$(dirname "$NGINX_DEFAULT")"
  rm -f /etc/nginx/sites-enabled/default
  install -o root -g root -m 0644 "$default_temp" "$NGINX_DEFAULT"
  install -o root -g root -m 0644 "$site_temp" "$NGINX_SITE"
  ln -sfn "$NGINX_SITE" "$NGINX_SITE_LINK"
  nginx -t
}

request_certificate() {
  local domain="$1" email="$2" args
  args=(certbot certonly --nginx --non-interactive --agree-tos --cert-name "$domain" -d "$domain")
  if [[ -n "$email" ]]; then args+=(--email "$email"); else args+=(--register-unsafely-without-email); fi
  "${args[@]}"
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat > "$CERT_HOOK" <<'EOF'
#!/usr/bin/env bash
# Managed by kmrinit
nginx -t && systemctl reload nginx
EOF
  chmod 0755 "$CERT_HOOK"
  systemctl enable --now certbot.timer
}

wait_for_http() {
  local url="$1" attempts=20
  while (( attempts > 0 )); do curl -fsS --max-time 5 "$url" >/dev/null 2>&1 && return 0; sleep 1; ((attempts-=1)); done
  return 1
}

cleanup_failed_install() {
  local domain="$1" cert_preexisting="$2" hook_preexisting="$3" added_packages="$4" ufw_clean=1
  log_warn "安装未完成，正在清理本次创建的 Komari/Nginx 资源。"
  systemctl disable --now "$KOMARI_SERVICE" >/dev/null 2>&1 || true
  rm -f "$KOMARI_SERVICE_FILE"
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ "$cert_preexisting" != 1 && -n "$domain" ]] && command -v certbot >/dev/null 2>&1; then
    certbot delete --non-interactive --cert-name "$domain" >/dev/null 2>&1 || true
  fi
  systemctl disable --now nginx >/dev/null 2>&1 || true
  rm -f "$NGINX_SITE_LINK" "$NGINX_SITE" "$NGINX_DEFAULT"
  rm -rf "$KOMARI_DIR"
  ufw_delete_web || ufw_clean=0
  purge_added_packages "$added_packages"
  [[ "$hook_preexisting" == 1 ]] || rm -f "$CERT_HOOK"
  if (( ufw_clean == 1 )); then rm -f "$STATE_FILE"; else log_warn "UFW 规则尚未清理，保留 kmrinit 状态以便重试。"; fi
}

perform_stack_install() {
  local domain="$1" public_ip="$2" port="$3" email="$4" added_packages="$5" cert_preexisting="$6" binary tag
  install_dependencies
  binary="$(make_temp)"; tag="$(download_komari "$binary")"
  install -d -o root -g root -m 0750 "$KOMARI_DIR"
  install -o root -g root -m 0755 "$binary" "$KOMARI_BIN"
  write_komari_service "$port"
  systemctl enable --now "$KOMARI_SERVICE"
  sleep 1; systemctl is-active --quiet "$KOMARI_SERVICE" || die "Komari 服务启动失败。" 6
  wait_for_http "http://127.0.0.1:$port/" || die "Komari 内部 HTTP 健康检查失败。" 6

  write_nginx_configs "$domain" "$port" http
  systemctl enable --now nginx
  systemctl restart nginx
  ufw_allow_web
  request_certificate "$domain" "$email"
  write_nginx_configs "$domain" "$port" final
  nginx -t; systemctl reload nginx
  certbot renew --dry-run
  wait_for_http "https://$domain/" || die "Komari HTTPS 健康检查失败。" 6

  state_set INSTALLED 1; state_set DOMAIN "$domain"; state_set KOMARI_PORT "$port"; state_set CERT_EMAIL "$email"; state_set KOMARI_VERSION "$tag"; state_set PUBLIC_IPV4 "$public_ip"
  state_set ADDED_PACKAGES "$added_packages"; state_set CERT_PREEXISTING "$cert_preexisting"
}

install_stack() {
  if [[ "$(state_get INSTALLED 2>/dev/null || true)" == 1 || -e "$KOMARI_SERVICE_FILE" || -e "$NGINX_SITE" ]]; then die "检测到 Komari/Nginx 已安装，请使用 upgrade、configure 或 uninstall。" 4; fi
  command -v nginx >/dev/null 2>&1 && die "检测到已有 Nginx，拒绝接管。" 4
  ensure_probe_dependencies
  require_free_port 80 || die "Nginx 必须使用 80 端口。" 4
  require_free_port 443 || die "Nginx 必须使用 443 端口。请先用 vpsinit 修改 Xray 端口。" 4

  local domain public_ip port email rc added_packages cert_preexisting=0 hook_preexisting=0
  domain="$(read_domain)"
  public_ip="$(get_public_ipv4)"
  check_domain_a "$domain" "$public_ip" || die "域名 A 记录尚未完全解析到当前服务器，请等待解析后重试。" 4
  port="$(read_komari_port 'Komari 内部端口' 30774)"
  email="$(read_email)"
  [[ -e "/etc/letsencrypt/renewal/$domain.conf" ]] && cert_preexisting=1
  if [[ -e "$CERT_HOOK" ]]; then
    grep -q '^# Managed by kmrinit$' "$CERT_HOOK" || die "$CERT_HOOK 已存在且不属于 kmrinit。" 4
    hook_preexisting=1
  fi
  added_packages="$(missing_stack_packages)"

  set +e
  ( set -Eeuo pipefail; perform_stack_install "$domain" "$public_ip" "$port" "$email" "$added_packages" "$cert_preexisting" )
  rc=$?
  set -e
  if (( rc != 0 )); then cleanup_failed_install "$domain" "$cert_preexisting" "$hook_preexisting" "$added_packages"; return "$rc"; fi
  log_ok "Nginx、证书和 Komari 已部署完成。"
  printf '访问地址：https://%s/\n' "$domain"
  log_info "请打开网页完成 Komari 管理员首次初始化。"
}

upgrade_komari() {
  [[ "$(state_get INSTALLED 2>/dev/null || true)" == 1 && -x "$KOMARI_BIN" ]] || die "Komari 尚未由 kmrinit 安装。" 4
  local binary tag current
  binary="$(make_temp)"; tag="$(download_komari "$binary")"; current="$(state_get KOMARI_VERSION 2>/dev/null || true)"
  if [[ "$tag" == "$current" ]]; then log_ok "Komari 已是官方最新稳定版 ${tag}。"; return; fi
  systemctl stop "$KOMARI_SERVICE"
  install -o root -g root -m 0755 "$binary" "$KOMARI_BIN"
  systemctl start "$KOMARI_SERVICE"
  sleep 1; systemctl is-active --quiet "$KOMARI_SERVICE" || die "Komari 升级后启动失败。" 6
  state_set KOMARI_VERSION "$tag"
  log_ok "Komari 已直接升级到 ${tag}。"
}

perform_stack_configure() {
  local old_domain="$1" domain="$2" port="$3" email="$4" public_ip="$5" cert_preexisting="$6"
  write_komari_service "$port"
  systemctl restart "$KOMARI_SERVICE"
  sleep 1
  systemctl is-active --quiet "$KOMARI_SERVICE" || die "Komari 新配置启动失败。" 6
  wait_for_http "http://127.0.0.1:$port/" || die "Komari 新端口健康检查失败。" 6

  if [[ "$domain" == "$old_domain" ]]; then
    write_nginx_configs "$domain" "$port" final
    systemctl restart nginx
  else
    write_nginx_configs "$domain" "$port" http
    systemctl restart nginx
    request_certificate "$domain" "$email"
    write_nginx_configs "$domain" "$port" final
    nginx -t
    systemctl reload nginx
  fi
  nginx -t
  systemctl reload nginx
  wait_for_http "https://$domain/" || die "新配置 HTTPS 健康检查失败。" 6
  state_set DOMAIN "$domain"
  state_set KOMARI_PORT "$port"
  state_set CERT_EMAIL "$email"
  state_set CERT_PREEXISTING "$cert_preexisting"
  if [[ -n "$public_ip" ]]; then state_set PUBLIC_IPV4 "$public_ip"; fi
  return 0
}

rollback_stack_configure() {
  local backup_dir="$1" new_domain="$2" new_cert_preexisting="$3" hook_preexisting="$4"
  log_warn "配置修改未完成，正在恢复原 Komari、Nginx 和状态配置。"
  cp -a "$backup_dir/komari.service" "$KOMARI_SERVICE_FILE"
  cp -a "$backup_dir/nginx-site" "$NGINX_SITE"
  cp -a "$backup_dir/nginx-default" "$NGINX_DEFAULT"
  rm -f "$NGINX_SITE_LINK"
  cp -a "$backup_dir/nginx-site-link" "$NGINX_SITE_LINK"
  cp -a "$backup_dir/state.conf" "$STATE_FILE"
  if [[ "$new_cert_preexisting" != 1 && -n "$new_domain" ]] && command -v certbot >/dev/null 2>&1; then
    certbot delete --non-interactive --cert-name "$new_domain" >/dev/null 2>&1 || true
  fi
  [[ "$hook_preexisting" == 1 ]] || rm -f "$CERT_HOOK"
  systemctl daemon-reload
  systemctl restart "$KOMARI_SERVICE" || log_error "恢复后 Komari 重启失败，请立即人工检查。"
  nginx -t && systemctl restart nginx || log_error "恢复后 Nginx 重启失败，请立即人工检查。"
}

configure_stack() {
  [[ "$(state_get INSTALLED 2>/dev/null || true)" == 1 ]] || die "Komari 尚未安装。" 4
  local old_domain old_port old_email old_cert_preexisting domain port email public_ip="" new_cert_preexisting=0 hook_preexisting=0 backup_dir rc required new_domain_for_cleanup=""
  old_domain="$(state_get DOMAIN)"; old_port="$(state_get KOMARI_PORT)"; old_email="$(state_get CERT_EMAIL 2>/dev/null || true)"
  old_cert_preexisting="$(state_get CERT_PREEXISTING 2>/dev/null || printf '0')"
  read -r -p "访问域名 [$old_domain]：" domain; domain="${domain:-$old_domain}"; domain="${domain,,}"; valid_domain "$domain" || die "域名格式无效。" 2
  port="$(read_komari_port 'Komari 内部端口' "$old_port" "$old_port")"
  read -r -p "证书联系邮箱 [$old_email]：" email; email="${email:-$old_email}"; valid_email "$email" || die "邮箱格式无效。" 2
  if [[ "$domain" != "$old_domain" ]]; then
    public_ip="$(get_public_ipv4)"
    check_domain_a "$domain" "$public_ip" || die "新域名 A 记录尚未完全生效。" 4
    [[ -e "/etc/letsencrypt/renewal/$domain.conf" ]] && new_cert_preexisting=1
  else
    new_cert_preexisting="$old_cert_preexisting"
  fi
  if [[ -e "$CERT_HOOK" ]]; then
    grep -q '^# Managed by kmrinit$' "$CERT_HOOK" || die "$CERT_HOOK 已存在且不属于 kmrinit。" 4
    hook_preexisting=1
  fi
  for required in "$KOMARI_SERVICE_FILE" "$NGINX_SITE" "$NGINX_DEFAULT" "$NGINX_SITE_LINK" "$STATE_FILE"; do
    [[ -e "$required" || -L "$required" ]] || die "缺少托管文件 ${required}，拒绝在不完整状态下修改配置。" 4
  done
  backup_dir="$RUNTIME_DIR/configure-backup"
  install -d -m 0700 "$backup_dir"
  cp -a "$KOMARI_SERVICE_FILE" "$backup_dir/komari.service"
  cp -a "$NGINX_SITE" "$backup_dir/nginx-site"
  cp -a "$NGINX_DEFAULT" "$backup_dir/nginx-default"
  cp -a "$NGINX_SITE_LINK" "$backup_dir/nginx-site-link"
  cp -a "$STATE_FILE" "$backup_dir/state.conf"

  set +e
  ( set -Eeuo pipefail; perform_stack_configure "$old_domain" "$domain" "$port" "$email" "$public_ip" "$new_cert_preexisting" )
  rc=$?
  set -e
  if (( rc != 0 )); then
    [[ "$domain" == "$old_domain" ]] || new_domain_for_cleanup="$domain"
    rollback_stack_configure "$backup_dir" "$new_domain_for_cleanup" "$new_cert_preexisting" "$hook_preexisting"
    return "$rc"
  fi
  if [[ "$domain" != "$old_domain" && "$old_cert_preexisting" != 1 ]]; then
    certbot delete --non-interactive --cert-name "$old_domain" >/dev/null 2>&1 || log_warn "旧域名证书未能删除，请稍后人工检查。"
  elif [[ "$domain" == "$old_domain" && -n "$email" && "$email" != "$old_email" ]]; then
    certbot update_account --non-interactive --email "$email" >/dev/null || log_warn "Certbot 联系邮箱更新失败，现有证书不受影响。"
  fi
  log_ok "Komari 配置已更新。"
}

managed_stack_present() {
  [[ "$(state_get INSTALLED 2>/dev/null || true)" == 1 ]] || grep -q '^Description=Komari Server managed by kmrinit$' "$KOMARI_SERVICE_FILE" 2>/dev/null || grep -q '^# Managed by kmrinit$' "$NGINX_SITE" 2>/dev/null
}

uninstall_stack() {
  managed_stack_present || { log_warn "未发现由 kmrinit 安装的服务。"; return; }
  confirm_danger "将彻底删除 Komari、全部数据、Nginx、证书和本工具添加的 UFW 规则，不做备份。" || return
  local domain cert_preexisting added_packages ufw_clean=1
  domain="$(state_get DOMAIN 2>/dev/null || true)"
  cert_preexisting="$(state_get CERT_PREEXISTING 2>/dev/null || printf '0')"
  added_packages="$(state_get ADDED_PACKAGES 2>/dev/null || true)"
  systemctl disable --now "$KOMARI_SERVICE" >/dev/null 2>&1 || true
  rm -f "$KOMARI_SERVICE_FILE"; systemctl daemon-reload
  if [[ "$cert_preexisting" != 1 && -n "$domain" ]] && command -v certbot >/dev/null 2>&1; then
    certbot delete --non-interactive --cert-name "$domain" >/dev/null 2>&1 || true
  fi
  systemctl disable --now nginx >/dev/null 2>&1 || true
  rm -f "$NGINX_SITE_LINK" "$NGINX_SITE" "$NGINX_DEFAULT"
  rm -rf "$KOMARI_DIR"
  ufw_delete_web || ufw_clean=0
  purge_added_packages "$added_packages"
  rm -f "$CERT_HOOK"
  rm -rf /var/log/nginx
  if (( ufw_clean == 1 )); then
    rm -f "$STATE_FILE"
    log_ok "Komari、Nginx、证书和全部数据已清理。"
  else
    log_warn "服务已清理，但 UFW 规则删除失败；状态文件已保留，请处理 UFW 后重新执行卸载。"
  fi
}

status_stack() {
  printf 'kmrinit: %s\n' "$TOOL_VERSION"
  local domain port; domain="$(state_get DOMAIN 2>/dev/null || true)"; port="$(state_get KOMARI_PORT 2>/dev/null || true)"
  printf '域名：%s\n内部端口：%s\n记录版本：%s\n' "${domain:-未安装}" "${port:-未安装}" "$(state_get KOMARI_VERSION 2>/dev/null || printf '未知')"
  systemctl --no-pager --full status "$KOMARI_SERVICE" || true
  systemctl --no-pager --full status nginx || true
  command -v nginx >/dev/null 2>&1 && nginx -t || true
  [[ -n "$port" ]] && ss -lntup | awk -v p=":$port" 'NR==1 || $5 ~ p"$"'
  ss -lntup | awk 'NR==1 || $5 ~ /:(80|443)$/'
  [[ -n "$domain" ]] && { printf 'A 记录：\n'; dig +short A "$domain"; certbot certificates --cert-name "$domain" || true; curl -fsSI --max-time 15 "https://$domain/" | head -n 1 || true; }
  systemctl --no-pager status certbot.timer || true
  command -v ufw >/dev/null 2>&1 && ufw status || true
}

logs_nginx() { log_info "文件日志：/var/log/nginx/access.log 和 /var/log/nginx/error.log"; journalctl -u nginx --lines 100 --follow --no-pager; }
logs_komari() { journalctl -u "$KOMARI_SERVICE" --lines 100 --follow --no-pager; }

self_update() {
  local temp; temp="$(make_temp)"; download_file "$SELF_URL" "$temp"; grep -q 'TOOL_NAME="kmrinit"' "$temp" || die "下载内容不正确。" 5; bash -n "$temp" || die "新版本语法检查失败。" 5
  install -o root -g root -m 0755 "$temp" "$INSTALL_PATH"; log_ok "kmrinit 已从 main 分支更新。"
}

restart_after_self_update() {
  log_info "正在重新启动更新后的 kmrinit。"
  flock -u 9 >/dev/null 2>&1 || true
  exec 9>&-
  exec "$INSTALL_PATH"
}

self_uninstall() {
  confirm_danger "仅删除 kmrinit 工具、状态和日志，不卸载 Komari、Nginx或证书。" || return
  rm -f "$INSTALL_PATH"; rm -rf "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
  log_ok "kmrinit 工具已卸载，已部署服务保持不变。"
}

show_help() {
  cat <<'EOF'
用法：
  kmrinit
  kmrinit install|upgrade|configure|uninstall|status
  kmrinit logs nginx|komari
  kmrinit self-update
  kmrinit self-uninstall
EOF
}

main_menu() {
  local choice
  while true; do
    cat <<'EOF'

========== kmrinit ==========
1. 安装 Nginx + Komari
2. 升级 Komari
3. 修改 Komari 配置
4. 卸载 Nginx + Komari
5. 查看整体状态
6. 查看 Nginx 日志
7. 查看 Komari 日志
8. 更新 kmrinit
9. 卸载 kmrinit
0. 退出
EOF
    read -r -p '请选择：' choice
    case "$choice" in
      1) install_stack ;; 2) upgrade_komari ;; 3) configure_stack ;; 4) uninstall_stack ;;
      5) status_stack ;; 6) logs_nginx ;; 7) logs_komari ;; 8) self_update; restart_after_self_update ;; 9) self_uninstall; return ;; 0) return ;;
      *) log_error "无效选择。" ;;
    esac
  done
}

main() {
  if [[ "${1:-}" =~ ^(-h|--help|help)$ ]]; then show_help; return; fi
  bootstrap_self "$@"
  require_root; check_platform; ensure_dirs; start_logging
  if [[ "${1:-}" != status && "${1:-}" != logs ]]; then acquire_lock; fi
  case "${1:-}" in
    '') main_menu ;; install) install_stack ;; upgrade) upgrade_komari ;; configure) configure_stack ;; uninstall) uninstall_stack ;; status) status_stack ;;
    logs) case "${2:-}" in nginx) logs_nginx ;; komari) logs_komari ;; *) show_help; exit 2 ;; esac ;;
    self-update) self_update ;; self-uninstall) self_uninstall ;; *) show_help; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
