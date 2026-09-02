#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../vpsinit.sh
source "$ROOT_DIR/vpsinit.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_true() { "$@" || fail "$*"; }
assert_false() { if "$@"; then fail "unexpected success: $*"; fi; }

assert_true valid_uuid '550e8400-e29b-41d4-a716-446655440000'
assert_false valid_uuid 'not-a-uuid'
assert_true valid_short_id '0123456789abcdef'
assert_false valid_short_id '123'
assert_true valid_domain 'www.bing.com'
assert_false valid_domain 'https://www.bing.com/'
assert_true valid_ipv4 '203.0.113.10'
assert_false valid_ipv4 '203.0.113.999'
[[ "$(printf 'Tokyo 01\n' | prompt_node_name)" == 'Tokyo 01' ]] || fail 'manual node name input failed'
[[ "$(printf '\t\nTokyo 02\n' | prompt_node_name 2>/dev/null)" == 'Tokyo 02' ]] || fail 'node name control character validation failed'
[[ "$(urlencode '香港 #1')" == '%E9%A6%99%E6%B8%AF%20%231' ]] || fail 'VLESS node name URL encoding failed'
[[ "$(yaml_double_quote 'HK: "01"')" == '"HK: \"01\""' ]] || fail 'Mihomo node name YAML quoting failed'
assert_true ssh_ports_are_single_value 7133
assert_true ssh_ports_are_single_value 7133 7133
assert_false ssh_ports_are_single_value 22 7133
SSH_PORT_CONFIG="$RUNTIME_DIR/sshd_config"
printf 'Port 7133\n# Port 22\nPermitRootLogin yes\n' > "$SSH_PORT_CONFIG"
disable_ssh_port_directives "$SSH_PORT_CONFIG"
grep -Fqx '# Disabled by vpsinit: Port 7133' "$SSH_PORT_CONFIG" || fail 'random SSH port directive was not disabled'
grep -Fqx '# Port 22' "$SSH_PORT_CONFIG" || fail 'commented SSH port example was modified'
grep -Fqx 'PermitRootLogin yes' "$SSH_PORT_CONFIG" || fail 'unrelated SSH setting was modified'
apt-get() { return 137; }
free() { :; }
swapon() { :; }
df() { :; }
journalctl() { :; }
dpkg() { :; }
if run_apt_get install -y test-package >/dev/null 2>&1; then
  fail 'apt-get SIGKILL was accepted as success'
else
  [[ "$?" -eq 137 ]] || fail 'apt-get SIGKILL exit code was not preserved'
fi
unset -f apt-get free swapon df journalctl dpkg
dpkg-query() { [[ "${1:-}" == -W && "${3:-}" == ufw ]] && printf 'install ok installed\n'; }
assert_true package_is_installed ufw
assert_false package_is_installed fail2ban
unset -f dpkg-query
[[ "$(printf '\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest manual@example\n' | prompt_root_ssh_key 2>/dev/null)" == 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest manual@example' ]] || fail 'manual SSH key input failed'
[[ "$(printf '\n58911\n' | read_required_port 'test' 2>/dev/null)" == 58911 ]] || fail 'required SSH port input failed'

xray() {
  case "${1:-}" in
    uuid) printf '550e8400-e29b-41d4-a716-446655440000\n' ;;
    x25519)
      if [[ "${2:-}" == -i && "${3:-}" == private-manual ]]; then
        printf 'Password: public-manual\n'
      elif [[ -z "${2:-}" ]]; then
        printf 'Private key: private-auto\nPassword: public-auto\n'
      else
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}
openssl() { [[ "${1:-}" == rand && "${2:-}" == -hex && "${3:-}" == 8 ]] && printf '0123456789abcdef\n'; }
[[ "$(printf '\n' | prompt_uuid)" == '550e8400-e29b-41d4-a716-446655440000' ]] || fail 'UUID Enter-default automatic generation failed'
[[ "$(printf 'a\n550e8400-e29b-41d4-a716-446655440001\n' | prompt_uuid)" == '550e8400-e29b-41d4-a716-446655440001' ]] || fail 'UUID manual selection failed'
[[ "$(printf 'b\n\n' | prompt_uuid 2>/dev/null)" == '550e8400-e29b-41d4-a716-446655440000' ]] || fail 'invalid UUID method did not retry'
[[ "$(printf '\n' | prompt_short_id)" == '0123456789abcdef' ]] || fail 'Short ID Enter-default automatic generation failed'
[[ "$(printf 'a\nAABBCCDDEEFF0011\n' | prompt_short_id)" == 'aabbccddeeff0011' ]] || fail 'Short ID manual selection failed'
[[ "$(printf 'b\n\n' | prompt_short_id 2>/dev/null)" == '0123456789abcdef' ]] || fail 'invalid Short ID method did not retry'
check_reality_target() { [[ "$1" == manual.example ]]; }
[[ "$(printf '\nmanual.example\n' | prompt_target 2>/dev/null)" == manual.example ]] || fail 'manual REALITY target input failed'
unset -f check_reality_target
[[ "$(printf '\n' | prompt_reality_keys)" == $'private-auto\npublic-auto' ]] || fail 'REALITY Enter-default automatic key generation failed'
[[ "$(printf 'a\nprivate-manual\npublic-manual\n' | prompt_reality_keys)" == $'private-manual\npublic-manual' ]] || fail 'REALITY manual key input failed'
[[ "$(printf 'b\n\n' | prompt_reality_keys 2>/dev/null)" == $'private-auto\npublic-auto' ]] || fail 'invalid REALITY key method did not retry'
unset -f xray openssl

ORIGINAL_IPV6_CONF_DIR="$IPV6_CONF_DIR"
ORIGINAL_IPV6_SNAPSHOT="$IPV6_SNAPSHOT"
IPV6_CONF_DIR="$RUNTIME_DIR/ipv6-conf"
IPV6_SNAPSHOT="$RUNTIME_DIR/ipv6-before-disable.conf"
mkdir -p "$IPV6_CONF_DIR"/{all,default,eth0,lo}
printf '1\n' > "$IPV6_CONF_DIR/all/disable_ipv6"
printf '1\n' > "$IPV6_CONF_DIR/default/disable_ipv6"
printf '0\n' > "$IPV6_CONF_DIR/eth0/disable_ipv6"
printf '1\n' > "$IPV6_CONF_DIR/lo/disable_ipv6"
[[ "$(ipv6_enabled_interfaces)" == eth0 ]] || fail 'enabled IPv6 interface was not detected'
IPV6_STATE_TEXT="$(snapshot_ipv6_disable_states)"
grep -q $'^eth0\t0$' <<<"$IPV6_STATE_TEXT" || fail 'IPv6 interface state snapshot missing eth0'
assert_false ipv6_runtime_fully_disabled
assert_false ipv6_all_interfaces_enabled
cat > "$IPV6_SNAPSHOT" <<'EOF'
# Managed by vpsinit
# IPv6 disable-state snapshot version 1
all	0
default	0
eth0	0
lo	1
EOF
assert_true ipv6_snapshot_valid
mkdir -p "$IPV6_CONF_DIR/eth1"
printf '1\n' > "$IPV6_CONF_DIR/eth1/disable_ipv6"
apply_ipv6_enable_values
[[ "$(<"$IPV6_CONF_DIR/all/disable_ipv6")" == 0 ]] || fail 'IPv6 all state was not restored'
[[ "$(<"$IPV6_CONF_DIR/default/disable_ipv6")" == 0 ]] || fail 'IPv6 default state was not restored'
[[ "$(<"$IPV6_CONF_DIR/eth0/disable_ipv6")" == 0 ]] || fail 'IPv6 interface state was not restored'
[[ "$(<"$IPV6_CONF_DIR/lo/disable_ipv6")" == 1 ]] || fail 'IPv6 disabled interface state was not restored'
[[ "$(<"$IPV6_CONF_DIR/eth1/disable_ipv6")" == 0 ]] || fail 'new IPv6 interface did not use saved default state'
assert_true ipv6_enable_values_verified
IPV6_CONF_DIR="$ORIGINAL_IPV6_CONF_DIR"
IPV6_SNAPSHOT="$ORIGINAL_IPV6_SNAPSHOT"

JSON_TEMP="$(make_temp_json)"
[[ "$JSON_TEMP" == *.json && -f "$JSON_TEMP" ]] || fail 'Xray temporary config does not use .json suffix'

TEST_PORT_COUNTER="$RUNTIME_DIR/test-port-counter"
printf '0\n' > "$TEST_PORT_COUNTER"
read_port() {
  local attempt
  attempt="$(cat "$TEST_PORT_COUNTER")"
  attempt=$((attempt + 1))
  printf '%s\n' "$attempt" > "$TEST_PORT_COUNTER"
  if (( attempt == 1 )); then printf '443\n'; else printf '30443\n'; fi
}
require_free_port() { [[ "$1" == 30443 ]]; }
[[ "$(read_free_port 'test' 443)" == 30443 ]] || fail 'occupied port did not retry'

sshd() {
  cat <<'EOF'
port 58911
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
assert_true validate_ssh_effective_settings 58911
sshd() {
  cat <<'EOF'
port 58911
permitrootlogin yes
passwordauthentication no
pubkeyauthentication yes
permitemptypasswords no
maxauthtries 8
logingracetime 60
x11forwarding no
allowagentforwarding no
allowtcpforwarding yes
EOF
}
if validate_ssh_effective_settings 58911 2>/dev/null; then fail 'SSH effective setting mismatch was accepted'; fi

UFW_CALLS="$RUNTIME_DIR/ufw-calls"
TEST_UFW_STATE=443
ufw() { local IFS=' '; printf '%s\n' "$*" >> "$UFW_CALLS"; }
state_get() { [[ "$1" == UFW_XRAY_PORT && -n "$TEST_UFW_STATE" ]] && printf '%s\n' "$TEST_UFW_STATE"; }
state_delete() { [[ "$1" == UFW_XRAY_PORT ]] && TEST_UFW_STATE=""; }
assert_true ufw_delete_owned XRAY
grep -q '^--force delete allow 443/tcp$' "$UFW_CALLS" || fail 'inactive UFW rule was not deleted'
[[ -z "$TEST_UFW_STATE" ]] || fail 'UFW ownership state was not cleared'

XRAY_CONFIG="$RUNTIME_DIR/config.json"
cat > "$XRAY_CONFIG" <<'EOF'
{
  "inbounds": [{
    "port": 443,
    "settings": {"clients": [{"id": "550e8400-e29b-41d4-a716-446655440000"}]},
    "streamSettings": {"realitySettings": {
      "serverNames": ["www.bing.com"],
      "privateKey": "private-test-key",
      "shortIds": ["0123456789abcdef"]
    }}
  }]
}
EOF
[[ "$(xray_config_port)" == 443 ]] || fail 'Xray port parse failed'
[[ "$(xray_config_uuid)" == '550e8400-e29b-41d4-a716-446655440000' ]] || fail 'Xray UUID parse failed'
[[ "$(xray_config_private_key)" == 'private-test-key' ]] || fail 'Xray private key parse failed'
[[ "$(xray_config_short_id)" == '0123456789abcdef' ]] || fail 'Xray Short ID parse failed'
[[ "$(xray_config_target)" == 'www.bing.com' ]] || fail 'Xray target parse failed'

getent() { [[ "$1" == group && "$2" == nogroup ]]; }
id() { [[ "$1" == -gn && "$2" == nobody ]] && printf 'nogroup\n'; }
[[ "$(resolve_service_group nobody nobody)" == nogroup ]] || fail 'Xray service group fallback failed'

SSH_CONNECTION='2001:db8::10 50000 2001:db8::20 58911'
assert_true current_ssh_uses_ipv6
SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 58911'
assert_false current_ssh_uses_ipv6
unset SSH_CONNECTION

help_output="$(show_help)"
grep -q 'vpsinit xray install' <<<"$help_output" || fail 'help missing xray install'
grep -q 'vpsinit system' <<<"$help_output" || fail 'help missing system'
grep -q 'vpsinit system ipv6' <<<"$help_output" || fail 'help missing IPv6 command'
grep -q 'vpsinit system ipv6-status' <<<"$help_output" || fail 'help missing IPv6 status command'
grep -q 'vpsinit system ipv6-enable' <<<"$help_output" || fail 'help missing IPv6 enable command'
grep -q 'vpsinit system ipv6-disable' <<<"$help_output" || fail 'help missing IPv6 disable command'
grep -q 'vpsinit system ufw-status' <<<"$help_output" || fail 'help missing UFW status command'
grep -q 'vpsinit version' <<<"$help_output" || fail 'help missing version command'
[[ "$(bash "$ROOT_DIR/vpsinit.sh" version)" == 'vpsinit 0.1.28' ]] || fail 'version command output mismatch'

grep -q 'LLMNR=no' "$ROOT_DIR/vpsinit.sh" || fail 'LLMNR setting missing'
grep -q 'net.ipv6.conf.all.disable_ipv6 = 1' "$ROOT_DIR/vpsinit.sh" || fail 'IPv6 disable setting missing'
grep -q 'current_ssh_uses_ipv6' "$ROOT_DIR/vpsinit.sh" || fail 'IPv6 SSH lockout check missing'
grep -Fq 'net/ipv6/conf/*/disable_ipv6 = 1' "$ROOT_DIR/vpsinit.sh" || fail 'per-interface IPv6 disable setting missing'
grep -q 'snapshot_ipv6_disable_states' "$ROOT_DIR/vpsinit.sh" || fail 'per-interface IPv6 rollback snapshot missing'
grep -Fq 'sysctl -p "$IPV6_SYSCTL"' "$ROOT_DIR/vpsinit.sh" || fail 'IPv6 config is not applied in isolation'
if declare -f configure_ipv6 | grep -Fq 'sysctl --system'; then fail 'IPv6 configuration reloads unrelated sysctl files'; fi
if declare -f restore_ipv6_config | grep -Fq 'sysctl --system'; then fail 'IPv6 rollback reloads unrelated sysctl files'; fi
grep -Fq 'IPv6 已启用，但没有公网 IPv6 地址。' "$ROOT_DIR/vpsinit.sh" || fail 'enabled IPv6 without a global address is not reported'
if grep -Fq '未检测到公网 IPv6 地址，保持当前 IPv6 配置。' "$ROOT_DIR/vpsinit.sh"; then fail 'enabled IPv6 without a global address is incorrectly skipped'; fi
grep -q 'findtime = 10m' "$ROOT_DIR/vpsinit.sh" || fail 'Fail2ban findtime mismatch'
grep -Fq 'filter = vpsinit-sshd' "$ROOT_DIR/vpsinit.sh" || fail 'Fail2ban custom SSH filter is not enabled'
grep -Fq '_daemon = sshd(?:-session)?' "$ROOT_DIR/vpsinit.sh" || fail 'Fail2ban sshd-session daemon match missing'
grep -Fq 'journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session' "$ROOT_DIR/vpsinit.sh" || fail 'Fail2ban sshd-session journal match missing'
grep -Fq 'fail2ban-regex "$test_log" "$FAIL2BAN_SSHD_FILTER" -o ip' "$ROOT_DIR/vpsinit.sh" || fail 'Fail2ban sshd-session validation missing'
if grep -nP '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]' "$ROOT_DIR/vpsinit.sh"; then fail 'unbraced variable adjacent to non-ASCII text'; fi
grep -Fq '8) self_update; restart_after_self_update ;;' "$ROOT_DIR/vpsinit.sh" || fail 'menu self-update does not restart the new script'
grep -Fq 'flock -u 9' "$ROOT_DIR/vpsinit.sh" || fail 'menu self-update does not release the operation lock'
grep -Fq 'timeout --foreground --signal=TERM --kill-after=15s 180s unattended-upgrade --dry-run --debug' "$ROOT_DIR/vpsinit.sh" || fail 'unattended-upgrade dry-run timeout missing'
grep -Fq '自动安全更新模拟校验超过 180 秒' "$ROOT_DIR/vpsinit.sh" || fail 'unattended-upgrade timeout warning missing'
if declare -f system_update | grep -q 'systemctl reboot'; then fail 'system update can reboot before hardening completes'; fi
grep -Fq '全部系统加固步骤已完成，是否现在重启？' "$ROOT_DIR/vpsinit.sh" || fail 'final reboot prompt missing'
grep -Fq 'prompt_reboot_after_hardening' "$ROOT_DIR/vpsinit.sh" || fail 'final reboot handler is not called'
grep -Fq "suffix='[y/n，回车默认为y]'" "$ROOT_DIR/vpsinit.sh" || fail 'yes-default prompt wording mismatch'
grep -Fq "suffix='[y/n，回车默认为n]'" "$ROOT_DIR/vpsinit.sh" || fail 'no-default prompt wording mismatch'
if grep -Fq "suffix='[Y/n]'" "$ROOT_DIR/vpsinit.sh" || grep -Fq "suffix='[y/N]'" "$ROOT_DIR/vpsinit.sh"; then fail 'yes/no prompt still encodes defaults with letter case'; fi
grep -Fq 'ensure_package_installed ufw' "$ROOT_DIR/vpsinit.sh" || fail 'UFW installation does not check existing package'
grep -Fq 'ensure_package_installed fail2ban' "$ROOT_DIR/vpsinit.sh" || fail 'Fail2ban installation does not check existing package'
if grep -Fq 'wizard_step "是否查看 UFW 状态及出入站配置信息？"' "$ROOT_DIR/vpsinit.sh"; then fail 'UFW status remains inside hardening wizard'; fi
grep -Fq '10. 查看 UFW 状态及出入站信息' "$ROOT_DIR/vpsinit.sh" || fail 'UFW status main-menu option missing'
grep -Fq 'ipv6) configure_ipv6' "$ROOT_DIR/vpsinit.sh" || fail 'IPv6 command dispatch missing'
grep -Fq 'ipv6-status) show_ipv6_status' "$ROOT_DIR/vpsinit.sh" || fail 'IPv6 status command dispatch missing'
grep -Fq 'ipv6-enable) enable_ipv6' "$ROOT_DIR/vpsinit.sh" || fail 'IPv6 enable command dispatch missing'
grep -Fq 'ipv6-disable) disable_ipv6' "$ROOT_DIR/vpsinit.sh" || fail 'IPv6 disable command dispatch missing'
grep -Fq 'ufw-status) show_ufw_status' "$ROOT_DIR/vpsinit.sh" || fail 'UFW status command dispatch missing'
grep -Fq 'xray:status|xray:logs|system:ufw-status|system:ipv6-status)' "$ROOT_DIR/vpsinit.sh" || fail 'read-only status command incorrectly takes mutation lock'
if grep -Eq 'system:ipv6-(enable|disable)[^)]*\)' "$ROOT_DIR/vpsinit.sh"; then fail 'IPv6 mutation command incorrectly bypasses operation lock'; fi
grep -Fq 'show_ipv6_status' <<<"$(declare -f enable_ipv6)" || fail 'IPv6 enable does not show status first'
grep -Fq 'show_ipv6_status' <<<"$(declare -f disable_ipv6)" || fail 'IPv6 disable does not show status first'
grep -Fq 'save_ipv6_restore_snapshot' <<<"$(declare -f disable_ipv6)" || fail 'IPv6 disable does not save restore snapshot'
grep -Fq '[[ ! -e "$IPV6_SYSCTL" && -z "$external" ]]' <<<"$(declare -f enable_ipv6)" || fail 'IPv6 enable can ignore persistent disable configuration'
grep -Fq 'ufw status verbose' "$ROOT_DIR/vpsinit.sh" || fail 'UFW verbose status output missing'
grep -Fq 'ufw show added' "$ROOT_DIR/vpsinit.sh" || fail 'UFW configured rules output missing'
grep -Fq 'apt-get 收到 SIGKILL' "$ROOT_DIR/vpsinit.sh" || fail 'apt-get SIGKILL diagnosis missing'
grep -Fq "journalctl -k -b --no-pager" "$ROOT_DIR/vpsinit.sh" || fail 'kernel OOM log collection missing'
if grep -Fq 'DEBIAN_FRONTEND=noninteractive apt-get update' "$ROOT_DIR/vpsinit.sh"; then fail 'apt-get update bypasses shared error handling'; fi
grep -q 'MaxAuthTries 8' "$ROOT_DIR/vpsinit.sh" || fail 'SSH MaxAuthTries mismatch'
grep -Fq '请粘贴一整行 root SSH 公钥' "$ROOT_DIR/vpsinit.sh" || fail 'manual root SSH key prompt missing'
grep -Fq 'wizard_step "是否覆盖 root SSH 公钥？" y configure_root_key' "$ROOT_DIR/vpsinit.sh" || fail 'root SSH key step is not enabled by default'
grep -Fq 'port="$(read_required_port '\''请输入新的 SSH 端口'\'')"' "$ROOT_DIR/vpsinit.sh" || fail 'SSH port still has a default value'
grep -Fq 'UUID 获取方式 [回车：自动生成；a：手动指定]' "$ROOT_DIR/vpsinit.sh" || fail 'UUID method prompt mismatch'
grep -Fq 'Short ID 获取方式 [回车：自动生成；a：手动指定]' "$ROOT_DIR/vpsinit.sh" || fail 'Short ID method prompt mismatch'
[[ "$(grep -Fc '请按回车自动生成，或输入 a 手动指定。' "$ROOT_DIR/vpsinit.sh")" -eq 3 ]] || fail 'Xray credential invalid-choice prompt mismatch'
grep -Fq '请输入 REALITY 目标域名' "$ROOT_DIR/vpsinit.sh" || fail 'manual REALITY target prompt missing'
if grep -Eq 'DEFAULT_(ROOT_SSH_KEY|XRAY_UUID|XRAY_SHORT_ID)|REALITY 目标域名 \[www\.bing\.com\]|请输入新的 SSH 端口.*58911' "$ROOT_DIR/vpsinit.sh"; then fail 'removed default values remain'; fi
grep -Fq '"target": "$target:443"' "$ROOT_DIR/vpsinit.sh" || fail 'REALITY target is not derived from domain and port 443'
grep -Fq '"serverNames": [' "$ROOT_DIR/vpsinit.sh" || fail 'REALITY serverNames config missing'
grep -Fq 'REALITY 密钥获取方式 [回车：自动生成；a：手动指定]' "$ROOT_DIR/vpsinit.sh" || fail 'REALITY key selection prompt mismatch'
grep -q 'SSH_DROPIN="/etc/ssh/sshd_config.d/00-vpsinit.conf"' "$ROOT_DIR/vpsinit.sh" || fail 'SSH drop-in priority mismatch'
grep -Fq '检测到当前 SSH 配置端口：${configured_ports[0]}，将替换为 ${port}。' "$ROOT_DIR/vpsinit.sh" || fail 'existing random SSH port is not accepted for replacement'
grep -Fq '检测到多个 SSH 配置端口：${configured_port_list}，拒绝自动接管。' "$ROOT_DIR/vpsinit.sh" || fail 'multiple SSH port conflict guard missing'
grep -q 'show_xray_client "$@" >/dev/tty' "$ROOT_DIR/vpsinit.sh" || fail 'one-time Xray output is not terminal-only'
grep -Fq '请输入客户端节点名称（用于 VLESS 分享链接和 Clash/Mihomo 节点）' "$ROOT_DIR/vpsinit.sh" || fail 'manual client node name prompt missing'
if grep -Fq '#vpsinit' "$ROOT_DIR/vpsinit.sh" || grep -Fq -- '- name: vpsinit' "$ROOT_DIR/vpsinit.sh"; then fail 'hard-coded client node name remains'; fi
grep -q 'temp="$(make_temp_json)"' "$ROOT_DIR/vpsinit.sh" || fail 'Xray config validation does not use JSON temp file'
grep -q 'chmod 0710 "$RUNTIME_DIR"' "$ROOT_DIR/vpsinit.sh" || fail 'Xray service cannot traverse runtime directory'
grep -q '"tag": "vless-reality-in"' "$ROOT_DIR/vpsinit.sh" || fail 'Xray inbound tag mismatch'
grep -q '"network": "raw"' "$ROOT_DIR/vpsinit.sh" || fail 'Xray transport is not raw'
grep -q '"outboundTag": "block"' "$ROOT_DIR/vpsinit.sh" || fail 'Xray block routing tag mismatch'
grep -q '"bittorrent"' "$ROOT_DIR/vpsinit.sh" || fail 'Xray BitTorrent block rule missing'
if grep -Eq 'state_set XRAY_(UUID|PUBLIC_KEY|SHORT_ID|TARGET|ENDPOINT)' "$ROOT_DIR/vpsinit.sh"; then fail 'Xray client data is persisted in state'; fi
grep -q "SELF_URL=\"https://raw.githubusercontent.com/chenqingjian/vpsinit/main/vpsinit.sh\"" "$ROOT_DIR/vpsinit.sh" || fail 'self URL mismatch'

printf 'PASS: vpsinit static tests\n'
