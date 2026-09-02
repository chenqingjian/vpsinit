#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TOOL_VERSION="0.1.28"
TOOL_NAME="vpsinit"
INSTALL_PATH="/usr/local/sbin/vpsinit"
SELF_URL="https://raw.githubusercontent.com/chenqingjian/vpsinit/main/vpsinit.sh"
CONFIG_DIR="/etc/vpsinit"
STATE_DIR="/var/lib/vpsinit"
LOG_DIR="/var/log/vpsinit"
STATE_FILE="$STATE_DIR/state.conf"
LOG_FILE="$LOG_DIR/vpsinit.log"
LOCK_FILE="/run/lock/vpsinit.lock"
XRAY_INSTALLER_URL="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_SERVICE="xray.service"
SSH_DROPIN="/etc/ssh/sshd_config.d/00-vpsinit.conf"
LEGACY_SSH_DROPIN="/etc/ssh/sshd_config.d/90-vpsinit.conf"
SSH_SOCKET_DROPIN="/etc/systemd/system/ssh.socket.d/90-vpsinit-port.conf"
LLMNR_DROPIN="/etc/systemd/resolved.conf.d/90-vpsinit-disable-llmnr.conf"
FAIL2BAN_JAIL="/etc/fail2ban/jail.d/90-vpsinit-sshd.local"
FAIL2BAN_SSHD_FILTER="/etc/fail2ban/filter.d/vpsinit-sshd.conf"
IPV6_SYSCTL="/etc/sysctl.d/90-vpsinit-disable-ipv6.conf"
IPV6_CONF_DIR="/proc/sys/net/ipv6/conf"
IPV6_SNAPSHOT="$STATE_DIR/ipv6-before-disable.conf"
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log_info() { printf '%s[信息]%s %s\n' "$BLUE" "$NC" "$*" >&2; }
log_ok() { printf '%s[完成]%s %s\n' "$GREEN" "$NC" "$*" >&2; }
log_warn() { printf '%s[警告]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
log_error() { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; }
die() { local code="${2:-1}"; log_error "$1"; exit "$code"; }

RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vpsinit.XXXXXX")"
cleanup() {
  [[ -n "${RUNTIME_DIR:-}" && -d "$RUNTIME_DIR" && "$(basename "$RUNTIME_DIR")" == vpsinit.* ]] && rm -rf -- "$RUNTIME_DIR"
}
trap cleanup EXIT
trap 'log_error "第 $LINENO 行执行失败。"' ERR

make_temp() {
  mktemp "$RUNTIME_DIR/file.XXXXXX"
}

make_temp_json() {
  mktemp "$RUNTIME_DIR/file.XXXXXX.json"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "请使用 root 用户运行。" 3
}

check_platform() {
  [[ -r /etc/os-release ]] || die "无法识别操作系统。" 3
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || die "仅支持官方 Debian。" 3
  case "${VERSION_ID:-}" in
    12|13) ;;
    *) die "仅支持 Debian 12 或 Debian 13。" 3 ;;
  esac
  [[ "$(uname -m)" == "x86_64" ]] || die "仅支持 amd64/x86_64。" 3
  command -v systemctl >/dev/null 2>&1 || die "系统必须使用 systemd。" 3
}

ensure_base_dirs() {
  install -d -m 700 "$CONFIG_DIR" "$STATE_DIR"
  install -d -m 750 "$LOG_DIR"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
}

start_logging() {
  [[ "${VPSINIT_LOGGING_STARTED:-0}" == 1 ]] && return
  export VPSINIT_LOGGING_STARTED=1
  exec > >(tee -a "$LOG_FILE") 2>&1
}

acquire_lock() {
  install -d -m 755 "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "已有另一个 vpsinit 变更操作正在运行。" 1
}

download_file() {
  local url="$1" output="$2"
  curl --fail --show-error --location --connect-timeout 15 --max-time 180 \
    --retry 2 --retry-delay 2 --output "$output" "$url"
  [[ -s "$output" ]] || die "下载文件为空：$url" 5
}

bootstrap_self() {
  [[ "${VPSINIT_SKIP_BOOTSTRAP:-0}" == 1 ]] && return
  [[ "$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")" == "$INSTALL_PATH" ]] && return
  require_root
  local temp
  temp="$(make_temp)"
  log_info "正在安装 vpsinit 到 $INSTALL_PATH"
  download_file "$SELF_URL" "$temp"
  grep -q 'TOOL_NAME="vpsinit"' "$temp" || die "下载内容不是预期的 vpsinit 脚本。" 5
  bash -n "$temp" || die "下载脚本未通过 Bash 语法检查。" 5
  install -o root -g root -m 0755 "$temp" "$INSTALL_PATH"
  log_ok "vpsinit 已安装。"
  exec "$INSTALL_PATH" "$@"
}

state_get() {
  local wanted="$1" key value
  [[ -r "$STATE_FILE" ]] || return 1
  while IFS='=' read -r key value; do
    [[ "$key" == "$wanted" ]] && { printf '%s\n' "$value"; return 0; }
  done < "$STATE_FILE"
  return 1
}

state_set() {
  local wanted="$1" new_value="$2" temp key value found=0
  ensure_base_dirs
  temp="$(make_temp)"
  if [[ -r "$STATE_FILE" ]]; then
    while IFS='=' read -r key value; do
      [[ -z "$key" ]] && continue
      if [[ "$key" == "$wanted" ]]; then
        printf '%s=%s\n' "$wanted" "$new_value" >> "$temp"
        found=1
      else
        printf '%s=%s\n' "$key" "$value" >> "$temp"
      fi
    done < "$STATE_FILE"
  fi
  [[ "$found" -eq 1 ]] || printf '%s=%s\n' "$wanted" "$new_value" >> "$temp"
  install -o root -g root -m 0600 "$temp" "$STATE_FILE"
}

state_delete() {
  local wanted="$1" temp key value
  [[ -r "$STATE_FILE" ]] || return 0
  temp="$(make_temp)"
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == "$wanted" ]] && continue
    printf '%s=%s\n' "$key" "$value" >> "$temp"
  done < "$STATE_FILE"
  install -o root -g root -m 0600 "$temp" "$STATE_FILE"
}

purge_legacy_xray_client_state() {
  state_delete XRAY_UUID
  state_delete XRAY_PUBLIC_KEY
  state_delete XRAY_SHORT_ID
  state_delete XRAY_TARGET
  state_delete XRAY_ENDPOINT
}

ask_yes_no() {
  local prompt="$1" default="${2:-n}" answer suffix
  [[ "$default" == y ]] && suffix='[y/n，回车默认为y]' || suffix='[y/n，回车默认为n]'
  read -r -p "$prompt $suffix " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

confirm_danger() {
  local prompt="$1" answer
  log_warn "$prompt"
  read -r -p '请输入大写 YES 继续：' answer
  [[ "$answer" == YES ]] || { log_warn "操作已取消。"; return 1; }
}

read_port() {
  local prompt="$1" default="$2" value
  while true; do
    read -r -p "$prompt [$default]：" value
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
      printf '%s\n' "$value"
      return
    fi
    log_error "端口必须是 1-65535 的整数。"
  done
}

read_required_port() {
  local prompt="$1" value
  while true; do
    read -r -p "${prompt}：" value
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
      printf '%s\n' "$value"
      return
    fi
    log_error "端口必须是 1-65535 的整数，不能为空。"
  done
}

port_is_listening() {
  local port="$1"
  ss -H -lntup 2>/dev/null | awk -v p=":$port" '$5 ~ p"$" {found=1} END {exit !found}'
}

require_free_port() {
  local port="$1"
  if port_is_listening "$port"; then
    log_error "端口 $port 已被占用："
    ss -lntup 2>/dev/null | awk -v p=":$port" 'NR==1 || $5 ~ p"$"'
    return 1
  fi
}

read_free_port() {
  local prompt="$1" default="$2" current="${3:-}" port
  while true; do
    port="$(read_port "$prompt" "$default")"
    if [[ -n "$current" && "$port" == "$current" ]]; then
      printf '%s\n' "$port"
      return
    fi
    if require_free_port "$port"; then
      printf '%s\n' "$port"
      return
    fi
  done
}

ufw_active() {
  command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'
}

ufw_allow_owned() {
  local port="$1" owner_key="$2"
  ufw_active || { log_warn "UFW 未启用，未自动放行 $port/tcp。"; return 0; }
  if ufw status | grep -Eq "^${port}/tcp[[:space:]]+ALLOW"; then
    log_warn "UFW 已存在 $port/tcp 放行规则，vpsinit 不取得该规则所有权。"
    return 0
  fi
  ufw allow "$port/tcp" comment "$TOOL_NAME-$owner_key"
  state_set "UFW_${owner_key}_PORT" "$port"
}

ufw_delete_owned() {
  local owner_key="$1" port
  port="$(state_get "UFW_${owner_key}_PORT" 2>/dev/null || true)"
  [[ -n "$port" ]] || return 0
  if ! command -v ufw >/dev/null 2>&1; then
    log_warn "未找到 UFW，无法删除 $port/tcp 规则，保留所有权记录。"
    return 1
  fi
  if ! ufw --force delete allow "$port/tcp" >/dev/null 2>&1; then
    log_warn "无法删除由 vpsinit 创建的 UFW 规则 $port/tcp，保留所有权记录。"
    return 1
  fi
  state_delete "UFW_${owner_key}_PORT"
}

report_apt_failure() {
  local rc="$1"
  log_error "apt-get 执行失败，退出码：${rc}。"
  if (( rc == 137 )); then
    log_error "apt-get 收到 SIGKILL，常见原因是内存或 cgroup 内存额度不足触发 OOM。"
    printf '\n===== 当前内存 =====\n' >&2
    command -v free >/dev/null 2>&1 && free -h >&2 || true
    printf '\n===== 当前 Swap =====\n' >&2
    command -v swapon >/dev/null 2>&1 && swapon --show >&2 || true
    printf '\n===== 根分区空间 =====\n' >&2
    df -h / >&2 || true
    printf '\n===== 最近的内核 OOM 记录 =====\n' >&2
    journalctl -k -b --no-pager 2>/dev/null | grep -Ei 'out of memory|oom-kill|killed process|memory cgroup out of memory' | tail -n 20 >&2 || true
  fi
  printf '\n===== dpkg 待处理状态 =====\n' >&2
  dpkg --audit >&2 || true
}

run_apt_get() {
  local rc
  if DEBIAN_FRONTEND=noninteractive apt-get "$@"; then
    return 0
  else
    rc=$?
  fi
  report_apt_failure "$rc"
  return "$rc"
}

install_packages() {
  run_apt_get update
  run_apt_get install -y "$@"
}

package_is_installed() {
  dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -qx 'install ok installed'
}

ensure_package_installed() {
  local package="$1"
  if package_is_installed "$package"; then
    log_info "$package 已安装，跳过软件包安装。"
  else
    log_info "未检测到 ${package}，正在安装。"
    install_packages "$package"
  fi
}

system_update() {
  log_info "正在更新 Debian 系统。"
  run_apt_get update
  run_apt_get full-upgrade -y
  run_apt_get autoremove -y
  log_ok "系统更新完成。"
  if [[ -f /var/run/reboot-required ]]; then
    log_warn "系统需要重启，将在全部加固步骤完成后统一询问。"
  fi
}

prompt_reboot_after_hardening() {
  [[ -f /var/run/reboot-required ]] || return 0
  log_warn "系统更新要求重启。"
  if ask_yes_no "全部系统加固步骤已完成，是否现在重启？" n; then
    log_info "正在重启系统。"
    systemctl reboot
  else
    log_warn "本次未重启，请稍后手动执行 reboot 使更新完整生效。"
  fi
}

password_is_strong() {
  local value="$1" classes=0
  (( ${#value} >= 12 )) || return 1
  [[ "$value" =~ [a-z] ]] && ((classes+=1))
  [[ "$value" =~ [A-Z] ]] && ((classes+=1))
  [[ "$value" =~ [0-9] ]] && ((classes+=1))
  [[ "$value" =~ [^a-zA-Z0-9] ]] && ((classes+=1))
  (( classes >= 3 ))
}

configure_root_password() {
  local first second
  while true; do
    read -r -s -p '请输入新的 root 密码：' first; printf '\n'
    read -r -s -p '请再次输入：' second; printf '\n'
    [[ "$first" == "$second" ]] || { log_error "两次密码不一致。"; continue; }
    password_is_strong "$first" || { log_error "密码至少 12 位，并包含四类字符中的至少三类。"; continue; }
    printf 'root:%s\n' "$first" | chpasswd
    unset first second
    log_ok "root 密码已更新。"
    return
  done
}

prompt_root_ssh_key() {
  local key
  while true; do
    read -r -p '请粘贴一整行 root SSH 公钥：' key
    [[ -n "${key//[[:space:]]/}" ]] || { log_error "SSH 公钥不能为空。"; continue; }
    printf '%s\n' "$key"
    return
  done
}

configure_root_key() {
  local key temp fingerprint
  command -v ssh-keygen >/dev/null 2>&1 || install_packages openssh-client
  key="$(prompt_root_ssh_key)"
  temp="$(make_temp)"
  printf '%s\n' "$key" > "$temp"
  ssh-keygen -l -f "$temp" >/dev/null 2>&1 || die "SSH 公钥格式无效。" 2
  fingerprint="$(ssh-keygen -l -f "$temp" | awk '{print $2 " " $3}')"
  log_info "将使用 SSH 公钥：$fingerprint"
  confirm_danger "该操作将覆盖 root 当前的全部 SSH 公钥。" || return 0
  install -d -o root -g root -m 0700 /root/.ssh
  install -o root -g root -m 0600 "$temp" /root/.ssh/authorized_keys
  log_ok "root SSH 公钥已覆盖。"
}

effective_ssh_port() {
  sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}'
}

ssh_ports_are_single_value() {
  local first="" value
  for value in "$@"; do
    if [[ -z "$first" ]]; then
      first="$value"
    elif [[ "$value" != "$first" ]]; then
      return 1
    fi
  done
}

disable_ssh_port_directives() {
  sed -Ei 's/^([[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]*(#.*)?)?)$/# Disabled by vpsinit: \1/' "$1"
}

validate_ssh_effective_settings() {
  local expected_port="$1" output key expected actual
  output="$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null)" || return 1
  [[ "$(printf '%s\n' "$output" | awk '$1=="port" {count++; value=$2} END {if (count==1) print value}')" == "$expected_port" ]] || return 1
  while IFS=' ' read -r key expected; do
    actual="$(printf '%s\n' "$output" | awk -v wanted="$key" '$1==wanted {print $2; exit}')"
    [[ "$actual" == "$expected" ]] || {
      log_error "SSH 最终配置不符合预期：${key}=${actual:-未设置}，期望 ${expected}。"
      return 1
    }
  done <<'EOF'
permitrootlogin yes
passwordauthentication yes
pubkeyauthentication yes
permitemptypasswords no
maxauthtries 8
logingracetime 60
x11forwarding no
allowagentforwarding no
allowtcpforwarding yes
EOF
}

configure_ssh() {
  install_packages openssh-server iproute2
  local port old_port temp socket_active=0 file value backup_dir had_dropin=0 had_legacy_dropin=0 had_socket_dropin=0 ufw_rule_added=0 index=0 configured_port_list
  local -a port_files=()
  local -a port_backups=()
  local -a configured_ports=()
  port="$(read_required_port '请输入新的 SSH 端口')"
  old_port="$(effective_ssh_port || true)"
  [[ "$port" == "$old_port" ]] || require_free_port "$port" || return 4

  while IFS= read -r file; do
    [[ "$file" == "$SSH_DROPIN" || "$file" == "$LEGACY_SSH_DROPIN" ]] && continue
    while IFS= read -r value; do
      configured_ports+=("$value")
    done < <(awk 'tolower($1)=="port" && $2 ~ /^[0-9]+$/ {print $2}' "$file")
    port_files+=("$file")
  done < <(grep -RslE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null || true)

  if ! ssh_ports_are_single_value "${configured_ports[@]}"; then
    configured_port_list="$(printf '%s\n' "${configured_ports[@]}" | sort -nu | paste -sd ',' -)"
    log_error "检测到多个 SSH 配置端口：${configured_port_list}，拒绝自动接管。"
    return 4
  fi
  if (( ${#configured_ports[@]} > 0 )); then
    log_info "检测到当前 SSH 配置端口：${configured_ports[0]}，将替换为 ${port}。"
  fi

  confirm_danger "脚本会直接切换到端口 $port 并关闭旧端口。请确认云安全组已放行新端口。" || return 0
  if ufw_active && ! ufw status | grep -Eq "^${port}/tcp[[:space:]]+ALLOW"; then
    ufw allow "$port/tcp" comment 'vpsinit-ssh'
    ufw_rule_added=1
  fi

  install -d -m 0755 /etc/ssh/sshd_config.d
  backup_dir="$RUNTIME_DIR/ssh-backup"
  install -d -m 0700 "$backup_dir"
  [[ -e "$SSH_DROPIN" ]] && { cp -a "$SSH_DROPIN" "$backup_dir/tool-dropin"; had_dropin=1; }
  [[ -e "$LEGACY_SSH_DROPIN" ]] && { cp -a "$LEGACY_SSH_DROPIN" "$backup_dir/legacy-tool-dropin"; had_legacy_dropin=1; }
  [[ -e "$SSH_SOCKET_DROPIN" ]] && { cp -a "$SSH_SOCKET_DROPIN" "$backup_dir/socket-dropin"; had_socket_dropin=1; }
  for file in "${port_files[@]}"; do
    cp -a "$file" "$backup_dir/port-file-$index"
    port_backups+=("$backup_dir/port-file-$index")
    index=$((index + 1))
    disable_ssh_port_directives "$file"
  done
  temp="$(make_temp)"
  cat > "$temp" <<EOF
# Managed by vpsinit
Port $port
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 8
LoginGraceTime 60
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding yes
EOF
  install -o root -g root -m 0644 "$temp" "$SSH_DROPIN"
  rm -f "$LEGACY_SSH_DROPIN"
  if ! sshd -t; then
    for index in "${!port_files[@]}"; do cp -a "${port_backups[$index]}" "${port_files[$index]}"; done
    [[ "$had_dropin" -eq 1 ]] && cp -a "$backup_dir/tool-dropin" "$SSH_DROPIN" || rm -f "$SSH_DROPIN"
    [[ "$had_legacy_dropin" -eq 1 ]] && cp -a "$backup_dir/legacy-tool-dropin" "$LEGACY_SSH_DROPIN" || rm -f "$LEGACY_SSH_DROPIN"
    [[ "$ufw_rule_added" -eq 1 ]] && ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
    die "SSH 配置检查失败，已恢复原配置。" 6
  fi
  if ! validate_ssh_effective_settings "$port"; then
    for index in "${!port_files[@]}"; do cp -a "${port_backups[$index]}" "${port_files[$index]}"; done
    [[ "$had_dropin" -eq 1 ]] && cp -a "$backup_dir/tool-dropin" "$SSH_DROPIN" || rm -f "$SSH_DROPIN"
    [[ "$had_legacy_dropin" -eq 1 ]] && cp -a "$backup_dir/legacy-tool-dropin" "$LEGACY_SSH_DROPIN" || rm -f "$LEGACY_SSH_DROPIN"
    [[ "$ufw_rule_added" -eq 1 ]] && ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
    die "SSH 最终生效配置检查失败，已恢复原配置。" 6
  fi

  if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    socket_active=1
    install -d -m 0755 "$(dirname "$SSH_SOCKET_DROPIN")"
    cat > "$SSH_SOCKET_DROPIN" <<EOF
[Socket]
ListenStream=
ListenStream=$port
EOF
    systemctl daemon-reload
    if ! systemctl restart ssh.socket; then
      for index in "${!port_files[@]}"; do cp -a "${port_backups[$index]}" "${port_files[$index]}"; done
      [[ "$had_dropin" -eq 1 ]] && cp -a "$backup_dir/tool-dropin" "$SSH_DROPIN" || rm -f "$SSH_DROPIN"
      [[ "$had_legacy_dropin" -eq 1 ]] && cp -a "$backup_dir/legacy-tool-dropin" "$LEGACY_SSH_DROPIN" || rm -f "$LEGACY_SSH_DROPIN"
      [[ "$had_socket_dropin" -eq 1 ]] && cp -a "$backup_dir/socket-dropin" "$SSH_SOCKET_DROPIN" || rm -f "$SSH_SOCKET_DROPIN"
      systemctl daemon-reload; systemctl restart ssh.socket || true
      [[ "$ufw_rule_added" -eq 1 ]] && ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
      die "ssh.socket 重启失败，已尝试恢复原配置。" 6
    fi
  else
    if ! systemctl restart ssh.service; then
      for index in "${!port_files[@]}"; do cp -a "${port_backups[$index]}" "${port_files[$index]}"; done
      [[ "$had_dropin" -eq 1 ]] && cp -a "$backup_dir/tool-dropin" "$SSH_DROPIN" || rm -f "$SSH_DROPIN"
      [[ "$had_legacy_dropin" -eq 1 ]] && cp -a "$backup_dir/legacy-tool-dropin" "$LEGACY_SSH_DROPIN" || rm -f "$LEGACY_SSH_DROPIN"
      systemctl restart ssh.service || true
      [[ "$ufw_rule_added" -eq 1 ]] && ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
      die "ssh.service 重启失败，已尝试恢复原配置。" 6
    fi
  fi

  sleep 1
  if ! port_is_listening "$port"; then
    for index in "${!port_files[@]}"; do cp -a "${port_backups[$index]}" "${port_files[$index]}"; done
    if [[ "$had_dropin" -eq 1 ]]; then cp -a "$backup_dir/tool-dropin" "$SSH_DROPIN"; else rm -f "$SSH_DROPIN"; fi
    if [[ "$had_legacy_dropin" -eq 1 ]]; then cp -a "$backup_dir/legacy-tool-dropin" "$LEGACY_SSH_DROPIN"; else rm -f "$LEGACY_SSH_DROPIN"; fi
    if [[ "$socket_active" -eq 1 ]]; then
      if [[ "$had_socket_dropin" -eq 1 ]]; then cp -a "$backup_dir/socket-dropin" "$SSH_SOCKET_DROPIN"; else rm -f "$SSH_SOCKET_DROPIN"; fi
      systemctl daemon-reload; systemctl restart ssh.socket || true
    else
      systemctl restart ssh.service || true
    fi
    [[ "$ufw_rule_added" -eq 1 ]] && ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
    die "SSH 未在新端口 $port 监听，已尝试恢复原配置。" 6
  fi
  state_set SSH_PORT "$port"
  state_set SSH_SOCKET_MODE "$socket_active"
  if ufw_active; then
    state_set UFW_SSH_PORT "$port"
    if [[ -n "$old_port" && "$old_port" != "$port" ]]; then
      ufw --force delete allow "$old_port/tcp" >/dev/null 2>&1 || true
    fi
  fi
  log_ok "SSH 已切换到端口 ${port}。"
}

configure_ufw() {
  ensure_package_installed ufw
  local ssh_port
  ssh_port="$(effective_ssh_port || true)"
  [[ -n "$ssh_port" ]] || ssh_port=22
  ufw default deny incoming
  ufw default allow outgoing
  if ! ufw status | grep -Eq "^${ssh_port}/tcp[[:space:]]+ALLOW"; then
    ufw allow "$ssh_port/tcp" comment 'vpsinit-ssh'
  fi
  ufw --force enable
  state_set UFW_SSH_PORT "$ssh_port"
  log_ok "UFW 已启用，SSH 端口为 $ssh_port/tcp。"
}

show_ufw_status() {
  if ! package_is_installed ufw || ! command -v ufw >/dev/null 2>&1; then
    log_warn "当前系统未安装 UFW，无法查看状态和规则。"
    return 0
  fi
  printf '\n===== UFW 当前状态与默认出入站策略 =====\n'
  ufw status verbose
  printf '\n===== UFW 已添加的入站/出站规则 =====\n'
  ufw show added
}

read_range() {
  local prompt="$1" default="$2" min="$3" max="$4" value
  while true; do
    read -r -p "$prompt [$default]：" value
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )); then
      printf '%s\n' "$value"; return
    fi
    log_error "请输入 $min-$max 范围内的整数。"
  done
}

configure_fail2ban() {
  ensure_package_installed fail2ban
  local retries minutes port temp filter_temp test_log matched_ip
  retries="$(read_range '连续失败次数' 8 1 120)"
  minutes="$(read_range '封禁时间（分钟）' 10 1 120)"
  port="$(effective_ssh_port || true)"; port="${port:-22}"

  if [[ -e "$FAIL2BAN_SSHD_FILTER" ]] && ! grep -Fqx '# Managed by vpsinit' "$FAIL2BAN_SSHD_FILTER"; then
    die "检测到非 vpsinit 管理的 Fail2ban SSH 过滤器：${FAIL2BAN_SSHD_FILTER}，请先处理该文件。" 6
  fi
  filter_temp="$(make_temp)"
  cat > "$filter_temp" <<'EOF'
# Managed by vpsinit
[INCLUDES]
before = sshd.conf

[DEFAULT]
_daemon = sshd(?:-session)?

[Definition]
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session
EOF
  install -d -m 0755 /etc/fail2ban/filter.d
  install -o root -g root -m 0644 "$filter_temp" "$FAIL2BAN_SSHD_FILTER"

  test_log='Aug 25 04:55:07 test-host sshd-session[1800]: Failed password for root from 192.0.2.123 port 7900 ssh2'
  matched_ip="$(fail2ban-regex "$test_log" "$FAIL2BAN_SSHD_FILTER" -o ip 2>/dev/null || true)"
  [[ "$matched_ip" == '192.0.2.123' ]] || die "Fail2ban SSH 过滤器无法识别 sshd-session 登录失败日志。" 6

  temp="$(make_temp)"
  cat > "$temp" <<EOF
# Managed by vpsinit
[sshd]
enabled = true
filter = vpsinit-sshd
port = $port
backend = systemd
maxretry = $retries
findtime = 10m
bantime = ${minutes}m
EOF
  install -d -m 0755 /etc/fail2ban/jail.d
  install -o root -g root -m 0644 "$temp" "$FAIL2BAN_JAIL"
  fail2ban-client -t
  systemctl enable --now fail2ban
  systemctl restart fail2ban
  log_ok "Fail2ban 已启用：10 分钟内失败 $retries 次，封禁 $minutes 分钟。"
}

configure_unattended_upgrades() {
  local dry_run_log rc
  install_packages unattended-upgrades apt-listchanges
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  cat > /etc/apt/apt.conf.d/52vpsinit-unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  dry_run_log="$(make_temp)"
  log_info "正在执行自动安全更新模拟校验，最多等待 180 秒。"
  if timeout --foreground --signal=TERM --kill-after=15s 180s unattended-upgrade --dry-run --debug >"$dry_run_log" 2>&1; then
    log_ok "自动安全更新模拟校验通过。"
  else
    rc=$?
    case "$rc" in
      124|137)
        log_warn "自动安全更新模拟校验超过 180 秒，已终止本次模拟；配置仍已启用。"
        tail -n 20 "$dry_run_log" >&2 || true
        ;;
      *)
        log_error "自动安全更新模拟校验失败，退出码：$rc"
        tail -n 30 "$dry_run_log" >&2 || true
        return "$rc"
        ;;
    esac
  fi
  log_ok "自动安全更新已启用，不会自动重启。"
}

global_ipv6_addresses() {
  command -v ip >/dev/null 2>&1 || return 0
  ip -6 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}' | sort -u
}

link_local_ipv6_addresses() {
  command -v ip >/dev/null 2>&1 || return 0
  ip -6 -o addr show scope link 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $2 " " $4}' | sort -u
}

ipv6_enabled_interfaces() {
  local file interface
  for file in "$IPV6_CONF_DIR"/*/disable_ipv6; do
    [[ -r "$file" ]] || continue
    if [[ "$(<"$file")" != 1 ]]; then
      interface="$(basename "$(dirname "$file")")"
      printf '%s\n' "$interface"
    fi
  done
}

ipv6_runtime_fully_disabled() {
  local file found=0
  for file in "$IPV6_CONF_DIR"/*/disable_ipv6; do
    [[ -r "$file" ]] || continue
    found=1
    [[ "$(<"$file")" == 1 ]] || return 1
  done
  (( found == 1 ))
}

ipv6_all_interfaces_enabled() {
  local file found=0
  for file in "$IPV6_CONF_DIR"/*/disable_ipv6; do
    [[ -r "$file" ]] || continue
    found=1
    [[ "$(<"$file")" == 0 ]] || return 1
  done
  (( found == 1 ))
}

snapshot_ipv6_disable_states() {
  local file interface
  for file in "$IPV6_CONF_DIR"/*/disable_ipv6; do
    [[ -r "$file" ]] || continue
    interface="$(basename "$(dirname "$file")")"
    printf '%s\t%s\n' "$interface" "$(<"$file")"
  done
}

ipv6_snapshot_valid() {
  [[ -r "$IPV6_SNAPSHOT" ]] || return 1
  grep -Fqx '# Managed by vpsinit' "$IPV6_SNAPSHOT" || return 1
  awk -F '\t' '
    $1 == "all" && $2 ~ /^[01]$/ {all=1}
    $1 == "default" && $2 ~ /^[01]$/ {default_value=1}
    END {exit !(all && default_value)}
  ' "$IPV6_SNAPSHOT"
}

save_ipv6_restore_snapshot() {
  local temp
  ensure_base_dirs
  temp="$(make_temp)"
  {
    printf '# Managed by vpsinit\n'
    printf '# IPv6 disable-state snapshot version 1\n'
    snapshot_ipv6_disable_states
  } > "$temp"
  install -o root -g root -m 0600 "$temp" "$IPV6_SNAPSHOT"
  ipv6_snapshot_valid || die "IPv6 关闭前状态快照校验失败。" 6
}

ipv6_snapshot_value() {
  local interface="$1"
  awk -F '\t' -v wanted="$interface" '$1 == wanted && $2 ~ /^[01]$/ {print $2; exit}' "$IPV6_SNAPSHOT"
}

apply_ipv6_enable_values() {
  local file interface value default_value=0 use_snapshot=0
  if ipv6_snapshot_valid; then
    use_snapshot=1
    default_value="$(ipv6_snapshot_value default)"
  fi
  for file in "$IPV6_CONF_DIR"/*/disable_ipv6; do
    [[ -w "$file" ]] || continue
    interface="$(basename "$(dirname "$file")")"
    value=""
    (( use_snapshot == 0 )) || value="$(ipv6_snapshot_value "$interface")"
    value="${value:-$default_value}"
    printf '%s\n' "$value" > "$file"
  done
}

ipv6_enable_values_verified() {
  local file interface expected default_value=0 use_snapshot=0 found=0
  if ipv6_snapshot_valid; then
    use_snapshot=1
    default_value="$(ipv6_snapshot_value default)"
  fi
  for file in "$IPV6_CONF_DIR"/*/disable_ipv6; do
    [[ -r "$file" ]] || continue
    found=1
    interface="$(basename "$(dirname "$file")")"
    expected=""
    (( use_snapshot == 0 )) || expected="$(ipv6_snapshot_value "$interface")"
    expected="${expected:-$default_value}"
    [[ "$(<"$file")" == "$expected" ]] || return 1
  done
  (( found == 1 ))
}

ipv6_kernel_cmdline_disabled() {
  [[ -r /proc/cmdline ]] && grep -Eq '(^|[[:space:]])ipv6\.disable=1([[:space:]]|$)' /proc/cmdline
}

ipv6_external_disable_configs() {
  local file
  local -a candidates=(
    /etc/sysctl.conf
    /etc/sysctl.d/*.conf
    /run/sysctl.d/*.conf
    /usr/local/lib/sysctl.d/*.conf
    /usr/lib/sysctl.d/*.conf
  )
  for file in "${candidates[@]}"; do
    [[ -f "$file" && "$file" != "$IPV6_SYSCTL" ]] || continue
    grep -HEn '^[[:space:]]*net[./]ipv6[./]conf[./][^[:space:]=]+[./]disable_ipv6[[:space:]]*=[[:space:]]*1([[:space:]]|$)' "$file" || true
  done
}

show_ipv6_status() {
  local addresses links enabled_interfaces external recorded
  addresses="$(global_ipv6_addresses || true)"
  links="$(link_local_ipv6_addresses || true)"
  enabled_interfaces="$(ipv6_enabled_interfaces || true)"
  external="$(ipv6_external_disable_configs)"
  recorded="$(state_get IPV6_DISABLED 2>/dev/null || true)"

  printf '\n===== IPv6 当前状态 =====\n'
  if ipv6_kernel_cmdline_disabled; then
    printf '内核启动参数：ipv6.disable=1（已禁用）\n'
  else
    printf '内核启动参数：未禁用 IPv6\n'
  fi
  if [[ -e "$IPV6_SYSCTL" ]]; then
    if grep -Fqx '# Managed by vpsinit' "$IPV6_SYSCTL"; then
      printf 'vpsinit 持久化配置：已存在\n'
    else
      printf 'vpsinit 持久化配置：路径被非 vpsinit 文件占用\n'
    fi
  else
    printf 'vpsinit 持久化配置：不存在\n'
  fi
  printf 'vpsinit 状态记录：%s\n' "${recorded:-无}"
  printf '关闭前状态快照：%s\n' "$([[ -e "$IPV6_SNAPSHOT" ]] && printf '存在' || printf '不存在')"

  printf '\n接口开关（1=关闭，0=启用）：\n'
  local file interface
  for file in "$IPV6_CONF_DIR"/*/disable_ipv6; do
    [[ -r "$file" ]] || continue
    interface="$(basename "$(dirname "$file")")"
    printf '  %s=%s\n' "$interface" "$(<"$file")"
  done
  [[ -n "$addresses" ]] && printf '\n公网 IPv6 地址：\n%s\n' "$addresses" || printf '\n公网 IPv6 地址：无\n'
  [[ -n "$links" ]] && printf '\n链路本地 IPv6 地址：\n%s\n' "$links" || printf '\n链路本地 IPv6 地址：无\n'
  if command -v ip >/dev/null 2>&1; then
    printf '\nIPv6 默认路由：\n'
    ip -6 route show default 2>/dev/null || true
  fi
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    current_ssh_uses_ipv6 && printf '当前 SSH：IPv6\n' || printf '当前 SSH：IPv4\n'
  else
    printf '当前 SSH：无法判断\n'
  fi
  [[ -z "$external" ]] || printf '\n其他关闭 IPv6 的 sysctl 配置：\n%s\n' "$external"

  printf '\n结论：'
  if ipv6_kernel_cmdline_disabled; then
    printf 'IPv6 被内核启动参数禁用。\n'
  elif ipv6_runtime_fully_disabled; then
    printf 'IPv6 已完全关闭。\n'
  elif [[ -n "$addresses" ]]; then
    printf 'IPv6 已启用，并检测到公网 IPv6 地址。\n'
  elif [[ -n "$enabled_interfaces" ]]; then
    printf 'IPv6 已启用，但没有公网 IPv6 地址。\n'
  else
    printf 'IPv6 状态不完整或无法确定。\n'
  fi
  return 0
}

current_ssh_uses_ipv6() {
  local client_ip client_port server_ip server_port
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  IFS=' ' read -r client_ip client_port server_ip server_port <<<"$SSH_CONNECTION"
  [[ "$client_ip" == *:* || "$server_ip" == *:* ]]
}

restore_ipv6_config() {
  local backup="$1" states_backup="$2" interface value file
  if [[ -n "$backup" ]]; then
    install -o root -g root -m 0644 "$backup" "$IPV6_SYSCTL"
    sysctl -p "$IPV6_SYSCTL" >/dev/null 2>&1 || true
  else
    rm -f "$IPV6_SYSCTL"
  fi
  while IFS=$'\t' read -r interface value; do
    [[ -n "$interface" && "$value" =~ ^[01]$ ]] || continue
    file="$IPV6_CONF_DIR/$interface/disable_ipv6"
    [[ -w "$file" ]] && printf '%s\n' "$value" > "$file" || true
  done < "$states_backup"
}

disable_ipv6() {
  local enabled_interfaces temp backup="" states_backup snapshot_created=0
  show_ipv6_status
  if ipv6_runtime_fully_disabled; then
    log_ok "IPv6 已处于关闭状态。"
    return
  fi
  ask_yes_no "是否关闭本机 IPv6？" n || { log_info "保留 IPv6。"; return 0; }
  if current_ssh_uses_ipv6; then
    log_error "当前 SSH 会话正在使用 IPv6，直接关闭会导致连接中断。请先通过 IPv4 重新登录后再执行。"
    return 4
  fi
  confirm_danger "关闭 IPv6 会移除公网 IPv6 地址；请确认当前服务器可通过 IPv4 管理。" || return 0
  install_packages iproute2 procps curl ca-certificates
  if [[ -e "$IPV6_SYSCTL" ]] && ! grep -q '^# Managed by vpsinit$' "$IPV6_SYSCTL"; then
    die "$IPV6_SYSCTL 已存在且不属于 vpsinit。" 4
  fi
  if [[ -e "$IPV6_SNAPSHOT" ]]; then
    ipv6_snapshot_valid || die "$IPV6_SNAPSHOT 已存在但不是有效的 vpsinit 状态快照。" 4
  else
    save_ipv6_restore_snapshot
    snapshot_created=1
  fi
  states_backup="$(make_temp)"
  snapshot_ipv6_disable_states > "$states_backup"
  [[ -e "$IPV6_SYSCTL" ]] && { backup="$(make_temp)"; cp -a "$IPV6_SYSCTL" "$backup"; }
  temp="$(make_temp)"
  cat > "$temp" <<'EOF'
# Managed by vpsinit
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net/ipv6/conf/*/disable_ipv6 = 1
EOF
  install -o root -g root -m 0644 "$temp" "$IPV6_SYSCTL"
  if ! sysctl -p "$IPV6_SYSCTL" >/dev/null; then
    restore_ipv6_config "$backup" "$states_backup"
    (( snapshot_created == 0 )) || rm -f "$IPV6_SNAPSHOT"
    die "应用 IPv6 关闭配置失败，已恢复原配置。" 6
  fi
  sleep 1
  enabled_interfaces="$(ipv6_enabled_interfaces)"
  if [[ -n "$enabled_interfaces" || -n "$(global_ipv6_addresses)" ]]; then
    [[ -n "$enabled_interfaces" ]] && log_error "以下接口的 IPv6 仍处于启用状态：$(printf '%s' "$enabled_interfaces" | paste -sd ',')"
    restore_ipv6_config "$backup" "$states_backup"
    (( snapshot_created == 0 )) || rm -f "$IPV6_SNAPSHOT"
    die "IPv6 关闭后的状态验证失败，已恢复原配置。" 6
  fi
  if ! getent ahostsv4 deb.debian.org >/dev/null || ! curl -4fsSI --max-time 15 https://deb.debian.org/ >/dev/null; then
    restore_ipv6_config "$backup" "$states_backup"
    (( snapshot_created == 0 )) || rm -f "$IPV6_SNAPSHOT"
    die "关闭 IPv6 后 IPv4 DNS 或 HTTPS 验证失败，已恢复原配置。" 6
  fi
  state_set IPV6_DISABLED 1
  log_ok "IPv6 已关闭，IPv4 DNS 和 HTTPS 验证正常。"
}

enable_ipv6() {
  local external states_backup config_backup="" use_snapshot=0
  show_ipv6_status
  external="$(ipv6_external_disable_configs)"
  if ipv6_all_interfaces_enabled \
    && ! ipv6_kernel_cmdline_disabled \
    && [[ ! -e "$IPV6_SYSCTL" && -z "$external" ]]; then
    log_ok "IPv6 已处于启用状态，无需恢复。"
    state_delete IPV6_DISABLED
    return
  fi
  if ipv6_kernel_cmdline_disabled; then
    die "检测到内核启动参数 ipv6.disable=1，请先人工修改启动参数并重启。" 4
  fi
  [[ -z "$external" ]] || { printf '%s\n' "$external" >&2; die "IPv6 由非 vpsinit sysctl 配置关闭，拒绝自动覆盖。" 4; }
  if [[ -e "$IPV6_SYSCTL" ]] && ! grep -Fqx '# Managed by vpsinit' "$IPV6_SYSCTL"; then
    die "$IPV6_SYSCTL 已存在且不属于 vpsinit。" 4
  fi
  if [[ -e "$IPV6_SNAPSHOT" ]]; then
    ipv6_snapshot_valid || die "$IPV6_SNAPSHOT 已存在但不是有效的 vpsinit 状态快照。" 4
    use_snapshot=1
    log_info "将按照 ipv6-disable 保存的关闭前状态恢复 IPv6。"
  else
    log_warn "未找到关闭前状态快照，将统一启用所有现有接口的 IPv6。"
  fi
  ask_yes_no "是否恢复本机 IPv6？" n || { log_info "保持当前 IPv6 配置。"; return 0; }
  confirm_danger "恢复 IPv6 会重新开放 IPv6 网络栈，但不保证云厂商已分配公网 IPv6。" || return 0
  install_packages iproute2 procps

  states_backup="$(make_temp)"
  snapshot_ipv6_disable_states > "$states_backup"
  [[ -e "$IPV6_SYSCTL" ]] && { config_backup="$(make_temp)"; cp -a "$IPV6_SYSCTL" "$config_backup"; }
  rm -f "$IPV6_SYSCTL"
  apply_ipv6_enable_values
  sleep 1
  if ! ipv6_enable_values_verified; then
    restore_ipv6_config "$config_backup" "$states_backup"
    die "IPv6 恢复后的接口状态验证失败，已恢复操作前配置。" 6
  fi
  state_delete IPV6_DISABLED
  (( use_snapshot == 0 )) || rm -f "$IPV6_SNAPSHOT"
  if (( use_snapshot == 1 )); then
    log_ok "已按关闭前快照恢复 IPv6 接口状态。公网 IPv6 地址仍取决于云厂商和网络配置。"
  else
    log_ok "已启用所有现有接口的 IPv6。公网 IPv6 地址仍取决于云厂商和网络配置。"
  fi
  show_ipv6_status
}

configure_ipv6() {
  disable_ipv6
}

configure_llmnr() {
  local listeners owner temp backup=""
  install_packages iproute2 curl ca-certificates
  listeners="$(ss -H -lntup 2>/dev/null | awk '$5 ~ /:5355$/')"
  if [[ -z "$listeners" ]]; then
    log_ok "未发现 5355 监听，LLMNR 无需调整。"
    return
  fi
  printf '%s\n' "$listeners"
  owner="$(printf '%s\n' "$listeners" | grep -o 'users:(("[^"]*"' | head -n1 | cut -d'"' -f2 || true)"
  [[ "$owner" == "systemd-resolve" || "$owner" == "systemd-resolved" ]] || {
    log_error "5355 由未知进程 ${owner:-无法识别} 监听，拒绝盲目修改 DNS。"
    return 4
  }
  if [[ -e "$LLMNR_DROPIN" ]] && ! grep -q '^# Managed by vpsinit$' "$LLMNR_DROPIN"; then
    die "$LLMNR_DROPIN 已存在且不属于 vpsinit。" 4
  fi
  [[ -e "$LLMNR_DROPIN" ]] && { backup="$(make_temp)"; cp -a "$LLMNR_DROPIN" "$backup"; }
  install -d -m 0755 "$(dirname "$LLMNR_DROPIN")"
  temp="$(make_temp)"
  cat > "$temp" <<'EOF'
# Managed by vpsinit
[Resolve]
LLMNR=no
EOF
  install -o root -g root -m 0644 "$temp" "$LLMNR_DROPIN"
  systemctl restart systemd-resolved
  sleep 1
  if ss -H -lntup 2>/dev/null | awk '$5 ~ /:5355$/ {found=1} END {exit !found}'; then
    log_error "关闭 LLMNR 后仍检测到 5355 监听。"
    [[ -n "$backup" ]] && install -m 0644 "$backup" "$LLMNR_DROPIN" || rm -f "$LLMNR_DROPIN"
    systemctl restart systemd-resolved
    return 6
  fi
  if ! getent ahostsv4 deb.debian.org >/dev/null || ! curl -fsSI --max-time 15 https://deb.debian.org/ >/dev/null; then
    log_error "关闭 LLMNR 后 DNS 或 HTTPS 验证失败，正在恢复。"
    [[ -n "$backup" ]] && install -m 0644 "$backup" "$LLMNR_DROPIN" || rm -f "$LLMNR_DROPIN"
    systemctl restart systemd-resolved
    return 6
  fi
  state_set LLMNR_DISABLED 1
  log_ok "LLMNR 已关闭，5355 不再监听，DNS/HTTPS 验证正常。"
}

wizard_step() {
  local prompt="$1" default="$2" function_name="$3" rc
  ask_yes_no "$prompt" "$default" || return 0
  set +e
  ( set -Eeuo pipefail; "$function_name" )
  rc=$?
  set -e
  if (( rc != 0 )); then
    log_error "该步骤执行失败，退出码：$rc"
    ask_yes_no "是否继续执行后续步骤？" y || return "$rc"
  fi
}

system_wizard() {
  wizard_step "是否更新系统？" y system_update || return
  wizard_step "是否修改 root 密码？" y configure_root_password || return
  wizard_step "是否覆盖 root SSH 公钥？" y configure_root_key || return
  wizard_step "是否修改 SSH 端口并应用加固策略？" y configure_ssh || return
  wizard_step "是否安装并启用 UFW？" y configure_ufw || return
  wizard_step "是否安装并启用 Fail2ban？" y configure_fail2ban || return
  wizard_step "是否启用自动安全更新？" y configure_unattended_upgrades || return
  wizard_step "是否检测公网 IPv6？" y configure_ipv6 || return
  wizard_step "是否检查并关闭 LLMNR/5355？" y configure_llmnr || return
  log_ok "系统初始化向导执行结束。"
  prompt_reboot_after_hardening
}

install_xray_binary() {
  install_packages curl ca-certificates openssl unzip iproute2
  local installer
  installer="$(make_temp)"
  download_file "$XRAY_INSTALLER_URL" "$installer"
  bash -n "$installer" || die "Xray 官方安装器语法检查失败。" 5
  bash "$installer" install
  command -v xray >/dev/null 2>&1 || die "Xray 安装后未找到命令。" 6
}

resolve_service_group() {
  local service_user="$1" configured_group="$2" primary_group
  if [[ -n "$configured_group" ]] && getent group "$configured_group" >/dev/null 2>&1; then
    printf '%s\n' "$configured_group"
    return
  fi
  primary_group="$(id -gn "$service_user" 2>/dev/null || true)"
  [[ -n "$primary_group" ]] && getent group "$primary_group" >/dev/null 2>&1 || die "无法确定 Xray 服务用户 $service_user 的有效用户组。" 6
  printf '%s\n' "$primary_group"
}

valid_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; }
valid_short_id() { [[ "$1" =~ ^[0-9a-fA-F]{2,16}$ ]] && (( ${#1} % 2 == 0 )); }
valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_ipv4() { awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i<0 || $i>255) exit 1; exit 0} {exit 1}' <<<"$1"; }

prompt_uuid() {
  local mode value
  while true; do
    read -r -p 'UUID 获取方式 [回车：自动生成；a：手动指定]：' mode
    case "${mode,,}" in
      '') xray uuid; return ;;
      a)
        while true; do
          read -r -p '请输入 UUID：' value
          valid_uuid "$value" && { printf '%s\n' "${value,,}"; return; }
          log_error "UUID 格式无效。"
        done
        ;;
      *) log_error "请按回车自动生成，或输入 a 手动指定。" ;;
    esac
  done
}

prompt_reality_keys() {
  local mode private public derived output
  while true; do
    read -r -p 'REALITY 密钥获取方式 [回车：自动生成；a：手动指定]：' mode
    case "${mode,,}" in
      '')
        output="$(xray x25519)"
        private="$(printf '%s\n' "$output" | awk -F': ' 'tolower($1) ~ /private/ {print $2; exit}')"
        public="$(printf '%s\n' "$output" | awk -F': ' 'tolower($1) ~ /(public|password)/ {print $2; exit}')"
        [[ -n "$private" && -n "$public" ]] || die "无法解析 Xray 生成的 REALITY 密钥。" 6
        break
        ;;
      a)
        read -r -p '请输入 REALITY 私钥：' private
        read -r -p '请输入 REALITY 公钥：' public
        derived="$(xray x25519 -i "$private" 2>/dev/null | awk -F': ' 'tolower($1) ~ /(public|password)/ {print $2; exit}' || true)"
        [[ -n "$derived" && "$derived" == "$public" ]] || die "REALITY 公私钥不配套。" 2
        break
        ;;
      *) log_error "请按回车自动生成，或输入 a 手动指定。" ;;
    esac
  done
  printf '%s\n%s\n' "$private" "$public"
}

prompt_short_id() {
  local mode value
  while true; do
    read -r -p 'Short ID 获取方式 [回车：自动生成；a：手动指定]：' mode
    case "${mode,,}" in
      '') openssl rand -hex 8; return ;;
      a)
        while true; do
          read -r -p '请输入 Short ID（偶数长度十六进制，2-16 字符）：' value
          valid_short_id "$value" && { printf '%s\n' "${value,,}"; return; }
          log_error "Short ID 格式无效。"
        done
        ;;
      *) log_error "请按回车自动生成，或输入 a 手动指定。" ;;
    esac
  done
}

check_reality_target() {
  local domain="$1"
  getent ahostsv4 "$domain" >/dev/null 2>&1 || return 1
  timeout 15 openssl s_client -connect "$domain:443" -servername "$domain" -tls1_3 -verify_return_error </dev/null 2>/dev/null | grep -q 'Verify return code: 0'
}

prompt_target() {
  local value
  while true; do
    read -r -p '请输入 REALITY 目标域名：' value
    [[ -n "$value" ]] || { log_error "REALITY 目标域名不能为空。"; continue; }
    valid_domain "$value" || { log_error "域名格式无效。"; continue; }
    log_info "正在检查 $value:443"
    if check_reality_target "$value"; then
      log_info "REALITY target 将使用 ${value}:443，serverName 将使用 ${value}。"
      printf '%s\n' "${value,,}"
      return
    fi
    log_error "目标域名的 DNS、TCP 443、TLS 1.3 或证书检查失败，请重新输入。"
  done
}

detect_public_ipv4() {
  local first second
  first="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  second="$(curl -4fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '$1=="ip" {print $2}' || true)"
  if [[ "$first" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && ( -z "$second" || "$first" == "$second" ) ]]; then printf '%s\n' "$first"; return 0; fi
  return 1
}

prompt_endpoint() {
  local detected value
  detected="$(detect_public_ipv4 || true)"
  while true; do
    if [[ -n "$detected" ]]; then
      read -r -p "客户端节点地址 [$detected]：" value
      value="${value:-$detected}"
    else
      read -r -p '无法自动确定公网 IPv4，请输入客户端节点 IP 或域名：' value
    fi
    value="${value,,}"
    if valid_ipv4 "$value" || valid_domain "$value"; then
      printf '%s\n' "$value"
      return
    fi
    log_error "客户端节点地址必须是有效的 IPv4 或域名。"
  done
}

prompt_node_name() {
  local value
  while true; do
    read -r -p '请输入客户端节点名称（用于 VLESS 分享链接和 Clash/Mihomo 节点）：' value
    [[ -n "${value//[[:space:]]/}" ]] || { log_error "客户端节点名称不能为空。"; continue; }
    if printf '%s' "$value" | LC_ALL=C grep -q '[[:cntrl:]]'; then
      log_error "客户端节点名称不能包含控制字符。"
      continue
    fi
    printf '%s\n' "$value"
    return
  done
}

urlencode() {
  local LC_ALL=C value="$1" encoded="" char index hex
  for (( index=0; index<${#value}; index++ )); do
    char="${value:index:1}"
    case "$char" in
      [A-Za-z0-9._~-]) encoded+="$char" ;;
      *) printf -v hex '%%%02X' "'$char"; encoded+="$hex" ;;
    esac
  done
  printf '%s\n' "$encoded"
}

yaml_double_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"\n' "$value"
}

write_xray_config() {
  local port="$1" uuid="$2" private_key="$3" short_id="$4" target="$5" temp service_user service_group
  temp="$(make_temp_json)"
  cat > "$temp" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$uuid",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$target:443",
          "xver": 0,
          "serverNames": [
            "$target"
          ],
          "privateKey": "$private_key",
          "shortIds": [
            "$short_id"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
  service_user="$(systemctl show "$XRAY_SERVICE" -p User --value 2>/dev/null || true)"; service_user="${service_user:-root}"
  service_group="$(systemctl show "$XRAY_SERVICE" -p Group --value 2>/dev/null || true)"
  service_group="$(resolve_service_group "$service_user" "$service_group")"
  chown root:"$service_group" "$RUNTIME_DIR"
  chmod 0710 "$RUNTIME_DIR"
  chown root:"$service_group" "$temp"
  chmod 0640 "$temp"
  runuser -u "$service_user" -- xray run -test -config "$temp"
  install -d -o root -g "$service_group" -m 0750 "$(dirname "$XRAY_CONFIG")"
  install -o root -g "$service_group" -m 0640 "$temp" "$XRAY_CONFIG"
}

show_xray_client() {
  local endpoint="$1" port="$2" uuid="$3" public_key="$4" short_id="$5" target="$6" node_name="$7" encoded_target encoded_name yaml_name
  encoded_target="$(urlencode "$target")"
  encoded_name="$(urlencode "$node_name")"
  yaml_name="$(yaml_double_quote "$node_name")"
  printf '\n%sVLESS 分享链接（仅显示本次）：%s\n' "$GREEN" "$NC"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' "$uuid" "$endpoint" "$port" "$encoded_target" "$public_key" "$short_id" "$encoded_name"
  printf '\n%sClash/Mihomo 节点（仅显示本次）：%s\n' "$GREEN" "$NC"
  cat <<EOF
- name: $yaml_name
  type: vless
  server: $endpoint
  port: $port
  uuid: $uuid
  network: tcp
  tls: true
  udp: true
  flow: xtls-rprx-vision
  servername: $target
  reality-opts:
    public-key: $public_key
    short-id: $short_id
  client-fingerprint: chrome
EOF
}

show_xray_client_once() {
  if [[ -c /dev/tty ]] && show_xray_client "$@" >/dev/tty; then
    return
  fi
  log_warn "当前没有可用终端，无法显示一次性客户端配置。"
}

xray_config_uuid() { sed -n 's/.*"clients": \[{"id": "\([^"]*\)".*/\1/p' "$XRAY_CONFIG" | head -n 1; }
xray_config_port() { sed -n 's/.*"port": \([0-9][0-9]*\).*/\1/p' "$XRAY_CONFIG" | head -n 1; }
xray_config_private_key() { sed -n 's/.*"privateKey": "\([^"]*\)".*/\1/p' "$XRAY_CONFIG" | head -n 1; }
xray_config_short_id() { sed -n 's/.*"shortIds": \["\([^"]*\)"\].*/\1/p' "$XRAY_CONFIG" | head -n 1; }
xray_config_target() { sed -n 's/.*"serverNames": \["\([^"]*\)"\].*/\1/p' "$XRAY_CONFIG" | head -n 1; }

xray_present() {
  command -v xray >/dev/null 2>&1 || [[ -x /usr/local/bin/xray ]] || systemctl cat "$XRAY_SERVICE" >/dev/null 2>&1 || [[ -e "$XRAY_CONFIG" ]]
}

cleanup_failed_xray_install() {
  log_warn "Xray 安装未完成，正在清理本次创建的资源。"
  systemctl disable --now "$XRAY_SERVICE" >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
  rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
  rm -f /usr/local/bin/xray
  rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  systemctl daemon-reload >/dev/null 2>&1 || true
  ufw_delete_owned XRAY || true
  state_delete XRAY_INSTALLED; state_delete XRAY_PORT; state_delete XRAY_UUID; state_delete XRAY_PUBLIC_KEY; state_delete XRAY_SHORT_ID; state_delete XRAY_TARGET; state_delete XRAY_ENDPOINT
}

perform_xray_install() {
  local port uuid private_key public_key short_id target endpoint node_name keys
  port="$(read_free_port 'Xray 监听端口' 443)"
  uuid="$(prompt_uuid)"
  keys="$(prompt_reality_keys)"; private_key="$(printf '%s\n' "$keys" | sed -n '1p')"; public_key="$(printf '%s\n' "$keys" | sed -n '2p')"
  short_id="$(prompt_short_id)"
  target="$(prompt_target)"
  endpoint="$(prompt_endpoint)"
  node_name="$(prompt_node_name)"
  write_xray_config "$port" "$uuid" "$private_key" "$short_id" "$target"
  systemctl enable --now "$XRAY_SERVICE"
  systemctl restart "$XRAY_SERVICE"
  sleep 1
  systemctl is-active --quiet "$XRAY_SERVICE" || die "Xray 服务启动失败。" 6
  port_is_listening "$port" || die "Xray 未监听端口 ${port}。" 6
  ufw_allow_owned "$port" XRAY
  state_set XRAY_INSTALLED 1; state_set XRAY_PORT "$port"
  log_ok "Xray 安装完成。"
  show_xray_client_once "$endpoint" "$port" "$uuid" "$public_key" "$short_id" "$target" "$node_name"
}

xray_install() {
  if xray_present; then
    die "检测到 Xray 已存在，请使用 upgrade、configure 或 uninstall。" 4
  fi
  local rc
  set +e
  ( set -Eeuo pipefail; install_xray_binary; perform_xray_install )
  rc=$?
  set -e
  if (( rc != 0 )); then cleanup_failed_xray_install; return "$rc"; fi
}

xray_upgrade() {
  command -v xray >/dev/null 2>&1 || die "Xray 尚未安装。" 4
  local installer service_user
  installer="$(make_temp)"; download_file "$XRAY_INSTALLER_URL" "$installer"; bash -n "$installer" || die "官方安装器语法检查失败。" 5
  bash "$installer" install
  service_user="$(systemctl show "$XRAY_SERVICE" -p User --value 2>/dev/null || true)"; service_user="${service_user:-root}"
  runuser -u "$service_user" -- xray run -test -config "$XRAY_CONFIG"
  systemctl restart "$XRAY_SERVICE"
  systemctl is-active --quiet "$XRAY_SERVICE" || die "Xray 升级后启动失败。" 6
  log_ok "Xray 已升级到官方最新稳定版。"
  xray version | head -n 1
}

xray_configure() {
  [[ -r "$XRAY_CONFIG" ]] || die "Xray 尚未由 vpsinit 安装。" 4
  local old_port port uuid private_key public_key short_id target endpoint node_name keys current config_backup
  old_port="$(state_get XRAY_PORT 2>/dev/null || xray_config_port)"
  [[ "$old_port" =~ ^[0-9]+$ ]] || die "无法确定当前 Xray 端口。" 6
  port="$(read_free_port '新的 Xray 端口' "$old_port" "$old_port")"
  current="$(xray_config_uuid)"; valid_uuid "$current" || die "无法从当前配置读取 UUID。" 6
  if ask_yes_no "是否保留当前 UUID？" y; then uuid="$current"; else uuid="$(prompt_uuid)"; fi
  if ask_yes_no "是否保留当前 REALITY 密钥？" y; then
    private_key="$(xray_config_private_key)"
    public_key="$(xray x25519 -i "$private_key" 2>/dev/null | awk -F': ' 'tolower($1) ~ /(public|password)/ {print $2; exit}' || true)"
    [[ -n "$private_key" && -n "$public_key" ]] || die "无法从当前配置恢复 REALITY 密钥。" 6
  else keys="$(prompt_reality_keys)"; private_key="$(printf '%s\n' "$keys" | sed -n '1p')"; public_key="$(printf '%s\n' "$keys" | sed -n '2p')"; fi
  current="$(xray_config_short_id)"; valid_short_id "$current" || die "无法从当前配置读取 Short ID。" 6
  if ask_yes_no "是否保留当前 Short ID？" y; then short_id="$current"; else short_id="$(prompt_short_id)"; fi
  current="$(xray_config_target)"; valid_domain "$current" || die "无法从当前配置读取目标站点。" 6
  if ask_yes_no "是否保留当前目标站点 ${current}？" y; then target="$current"; else target="$(prompt_target)"; fi
  endpoint="$(prompt_endpoint)"
  node_name="$(prompt_node_name)"
  config_backup="$(make_temp)"; cp -a "$XRAY_CONFIG" "$config_backup"
  write_xray_config "$port" "$uuid" "$private_key" "$short_id" "$target"
  if ! systemctl restart "$XRAY_SERVICE"; then
    cp -a "$config_backup" "$XRAY_CONFIG"; systemctl restart "$XRAY_SERVICE" || true
    die "Xray 配置修改后启动失败，已恢复原配置。" 6
  fi
  sleep 1
  if ! systemctl is-active --quiet "$XRAY_SERVICE" || ! port_is_listening "$port"; then
    cp -a "$config_backup" "$XRAY_CONFIG"; systemctl restart "$XRAY_SERVICE" || true
    die "Xray 新配置未正常运行，已恢复原配置。" 6
  fi
  if [[ "$port" != "$old_port" ]]; then
    if ! ufw_delete_owned XRAY; then
      cp -a "$config_backup" "$XRAY_CONFIG"; systemctl restart "$XRAY_SERVICE" || true
      die "旧 Xray UFW 规则删除失败，已恢复原配置。" 6
    fi
    if ! ufw_allow_owned "$port" XRAY; then
      ufw_allow_owned "$old_port" XRAY || true
      cp -a "$config_backup" "$XRAY_CONFIG"; systemctl restart "$XRAY_SERVICE" || true
      die "新 Xray UFW 规则创建失败，已恢复原配置。" 6
    fi
  fi
  state_set XRAY_PORT "$port"
  state_delete XRAY_UUID; state_delete XRAY_PUBLIC_KEY; state_delete XRAY_SHORT_ID; state_delete XRAY_TARGET; state_delete XRAY_ENDPOINT
  log_ok "Xray 配置已更新。"
  show_xray_client_once "$endpoint" "$port" "$uuid" "$public_key" "$short_id" "$target" "$node_name"
}

xray_uninstall() {
  xray_present || { log_warn "Xray 未安装。"; return; }
  confirm_danger "将彻底删除 Xray、配置、密钥、日志和对应 UFW 规则，不做备份。" || return
  local installer
  installer="$(make_temp)"; download_file "$XRAY_INSTALLER_URL" "$installer"; bash -n "$installer" || die "官方安装器语法检查失败。" 5
  if ! bash "$installer" remove --purge; then
    log_warn "Xray 官方卸载器执行失败，将继续清理已知的托管资源。"
  fi
  systemctl disable --now "$XRAY_SERVICE" >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service /usr/local/bin/xray
  rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  systemctl daemon-reload >/dev/null 2>&1 || true
  ufw_delete_owned XRAY || log_warn "Xray 已删除，但对应 UFW 规则未能自动清理。"
  state_delete XRAY_INSTALLED
  state_delete XRAY_PORT
  state_delete XRAY_UUID
  state_delete XRAY_PUBLIC_KEY
  state_delete XRAY_SHORT_ID
  state_delete XRAY_TARGET
  state_delete XRAY_ENDPOINT
  log_ok "Xray 已彻底卸载。"
}

xray_status() {
  printf 'vpsinit: %s\n' "$TOOL_VERSION"
  if command -v xray >/dev/null 2>&1; then xray version | head -n 1; else log_warn "Xray 未安装。"; return; fi
  systemctl --no-pager --full status "$XRAY_SERVICE" || true
  xray run -test -config "$XRAY_CONFIG" || true
  local port; port="$(state_get XRAY_PORT 2>/dev/null || true)"; [[ -n "$port" ]] && ss -lntup | awk -v p=":$port" 'NR==1 || $5 ~ p"$"'
  command -v ufw >/dev/null 2>&1 && ufw status || true
}

xray_logs() { journalctl -u "$XRAY_SERVICE" --lines 100 --follow --no-pager; }

self_update() {
  local temp
  temp="$(make_temp)"; download_file "$SELF_URL" "$temp"; grep -q 'TOOL_NAME="vpsinit"' "$temp" || die "下载内容不正确。" 5; bash -n "$temp" || die "新版本语法检查失败。" 5
  install -o root -g root -m 0755 "$temp" "$INSTALL_PATH"
  log_ok "vpsinit 已从 main 分支更新。"
}

restart_after_self_update() {
  log_info "正在重新启动更新后的 vpsinit。"
  flock -u 9 >/dev/null 2>&1 || true
  exec 9>&-
  exec "$INSTALL_PATH"
}

self_uninstall() {
  confirm_danger "仅删除 vpsinit 工具、状态和日志，不恢复任何系统配置或卸载 Xray。" || return
  rm -f "$INSTALL_PATH"
  rm -rf "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR"
  log_ok "vpsinit 工具已卸载，已部署服务和系统配置保持不变。"
}

show_help() {
  cat <<'EOF'
用法：
  vpsinit
  vpsinit version
  vpsinit system
  vpsinit system ipv6
  vpsinit system ipv6-status
  vpsinit system ipv6-enable
  vpsinit system ipv6-disable
  vpsinit system ufw-status
  vpsinit xray install|upgrade|configure|uninstall|status|logs
  vpsinit self-update
  vpsinit self-uninstall
EOF
}

show_version() {
  printf '%s %s\n' "$TOOL_NAME" "$TOOL_VERSION"
}

main_menu() {
  local choice
  while true; do
    cat <<'EOF'

========== vpsinit ==========
1. 系统初始化与安全加固
2. Xray 安装
3. Xray 升级
4. Xray 修改配置
5. Xray 卸载
6. Xray 状态
7. Xray 日志
8. 更新 vpsinit
9. 卸载 vpsinit
10. 查看 UFW 状态及出入站信息
0. 退出
EOF
    read -r -p '请选择：' choice
    case "$choice" in
      1) system_wizard ;;
      2) xray_install ;;
      3) xray_upgrade ;;
      4) xray_configure ;;
      5) xray_uninstall ;;
      6) xray_status ;;
      7) xray_logs ;;
      8) self_update; restart_after_self_update ;;
      9) self_uninstall; return ;;
      10) show_ufw_status ;;
      0) return ;;
      *) log_error "无效选择。" ;;
    esac
  done
}

main() {
  if [[ "${1:-}" =~ ^(-h|--help|help)$ ]]; then show_help; return; fi
  if [[ "${1:-}" =~ ^(version|--version)$ ]]; then show_version; return; fi
  bootstrap_self "$@"
  require_root
  check_platform
  ensure_base_dirs
  start_logging
  case "${1:-}:${2:-}" in
    xray:status|xray:logs|system:ufw-status|system:ipv6-status) ;;
    *) acquire_lock; purge_legacy_xray_client_state ;;
  esac
  case "${1:-}" in
    '') main_menu ;;
    system)
      case "${2:-}" in
        '') system_wizard ;;
        ipv6) configure_ipv6 ;;
        ipv6-status) show_ipv6_status ;;
        ipv6-enable) enable_ipv6 ;;
        ipv6-disable) disable_ipv6 ;;
        ufw-status) show_ufw_status ;;
        *) show_help; exit 2 ;;
      esac
      ;;
    xray)
      case "${2:-}" in
        install) xray_install ;; upgrade) xray_upgrade ;; configure) xray_configure ;;
        uninstall) xray_uninstall ;; status) xray_status ;; logs) xray_logs ;;
        *) show_help; exit 2 ;;
      esac ;;
    self-update) self_update ;;
    self-uninstall) self_uninstall ;;
    *) show_help; exit 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
