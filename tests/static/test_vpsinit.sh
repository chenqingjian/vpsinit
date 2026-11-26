#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../vpsinit.sh
source "$ROOT_DIR/vpsinit.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_true() { "$@" || fail "$*"; }
assert_false() { if "$@"; then fail "unexpected success: $*"; fi; }

assert_true platform_supported debian 12
assert_true platform_supported debian 13
assert_true platform_supported ubuntu 24.04
assert_true platform_supported ubuntu 26.04
assert_false platform_supported ubuntu 22.04
assert_false platform_supported ubuntu 24.10
assert_false platform_supported ubuntu 25.04
assert_false platform_supported linuxmint 24.04
[[ "$(normalize_arch x86_64)" == amd64 ]] || fail 'x86_64 normalization failed'
[[ "$(normalize_arch amd64)" == amd64 ]] || fail 'amd64 normalization failed'
[[ "$(normalize_arch aarch64)" == arm64 ]] || fail 'aarch64 normalization failed'
[[ "$(normalize_arch arm64)" == arm64 ]] || fail 'arm64 normalization failed'
assert_false normalize_arch armv7l
SYSTEM_ID=ubuntu
SYSTEM_ARCH=amd64
[[ "$(distro_connectivity_host)" == archive.ubuntu.com ]] || fail 'Ubuntu connectivity host mismatch'
SYSTEM_ARCH=arm64
[[ "$(distro_connectivity_host)" == ports.ubuntu.com ]] || fail 'Ubuntu ARM64 connectivity host mismatch'
[[ "$(distro_connectivity_url)" == https://ports.ubuntu.com/ubuntu-ports/ ]] || fail 'Ubuntu ARM64 connectivity URL mismatch'
ubuntu_origins="$(unattended_origin_patterns)"
grep -Fqx 'origin=Ubuntu,codename=${distro_codename},label=Ubuntu' <<<"$ubuntu_origins" || fail 'Ubuntu base origin mismatch'
grep -Fqx 'origin=Ubuntu,codename=${distro_codename}-security,label=Ubuntu' <<<"$ubuntu_origins" || fail 'Ubuntu security origin mismatch'
SYSTEM_ID=debian
SYSTEM_ARCH=amd64
[[ "$(distro_connectivity_host)" == deb.debian.org ]] || fail 'Debian connectivity host mismatch'
debian_origins="$(unattended_origin_patterns)"
grep -Fqx 'origin=Debian,codename=${distro_codename},label=Debian-Security' <<<"$debian_origins" || fail 'Debian security origin mismatch'
grep -Fqx 'origin=Debian,codename=${distro_codename}-security,label=Debian-Security' <<<"$debian_origins" || fail 'Debian codename-security origin mismatch'

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
(
  printf() {
    local ordinal
    if [[ "${1:-}" == -v && "${4:-}" == "'"* ]]; then
      builtin printf -v ordinal '%d' "$4"
      if (( (ordinal & 0xff) >= 0x80 )); then
        builtin printf -v "$2" "$3" "$((0xdf00 | (ordinal & 0xff)))"
        return
      fi
    fi
    builtin printf "$@"
  }
  node_name=$'\xf0\x9f\x87\xaf\xf0\x9f\x87\xb5 \xe6\x97\xa5\xe6\x9c\xacLazyCat | BIGLOBE Mini'
  name_fragment='%F0%9F%87%AF%F0%9F%87%B5%20%E6%97%A5%E6%9C%ACLazyCat%20%7C%20BIGLOBE%20Mini'
  client_output="$(show_xray_client node.example 443 fixture-uuid fixture-key 0123 target.example "$node_name")"
  [[ "$client_output" == *"&support-x25519mlkem768=true#$name_fragment"$'\n'* ]] || fail 'VLESS node name encoding leaked C locale code units'
)
[[ "$(yaml_double_quote 'HK: "01"')" == '"HK: \"01\""' ]] || fail 'Mihomo node name YAML quoting failed'
assert_true ssh_ports_are_single_value 7133
assert_true ssh_ports_are_single_value 7133 7133
assert_false ssh_ports_are_single_value 22 7133
SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 26308'
[[ "$(current_ssh_server_port)" == 26308 ]] || fail 'current SSH server port parse failed'
assert_true ssh_ports_are_safe_to_migrate 22 26308
assert_true ssh_ports_are_safe_to_migrate 22 22 26308 26308
assert_true ssh_ports_are_safe_to_migrate 7133 7133
assert_false ssh_ports_are_safe_to_migrate 22 26308 443
SSH_CONNECTION='192.0.2.10 50000 192.0.2.20 58911'
assert_false ssh_ports_are_safe_to_migrate 22 26308
unset SSH_CONNECTION
assert_true ssh_ports_are_safe_to_migrate 7133
assert_false ssh_ports_are_safe_to_migrate 22 26308
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
ufw() {
  case "${1:-}:${2:-}" in
    status:) printf 'Status: inactive\n' ;;
    show:added) printf "ufw allow 58911/tcp comment 'vpsinit-ssh'\n" ;;
    *) return 1 ;;
  esac
}
assert_true ufw_has_allow_rule 58911
assert_false ufw_has_allow_rule 22
unset -f ufw
ORIGINAL_FAIL2BAN_JAIL="$FAIL2BAN_JAIL"
FAIL2BAN_JAIL="$RUNTIME_DIR/fail2ban-jail.local"
printf '# Managed by vpsinit\n[sshd]\nport = 58911\n' > "$FAIL2BAN_JAIL"
[[ "$(fail2ban_configured_ssh_port)" == 58911 ]] || fail 'Fail2ban configured SSH port parse failed'
FAIL2BAN_JAIL="$ORIGINAL_FAIL2BAN_JAIL"
(
  FAIL2BAN_JAIL="$RUNTIME_DIR/jail-generated.local"
  FAIL2BAN_SSHD_FILTER="$RUNTIME_DIR/filter-generated.conf"
  ensure_package_installed() { :; }
  read_range() { printf '%s\n' "$2"; }
  effective_ssh_port() { printf '58911\n'; }
  fail2ban-regex() { printf '192.0.2.123\n'; }
  fail2ban-client() { [[ "$1" == -t ]]; }
  service_enable_now() { :; }
  service_restart() { :; }
  wait_for_fail2ban_sshd() { :; }
  install() {
    case "${@: -1}" in
      /etc/fail2ban/filter.d|/etc/fail2ban/jail.d) return 0 ;;
      "$FAIL2BAN_JAIL"|"$FAIL2BAN_SSHD_FILTER") cp -- "${@: -2:1}" "${@: -1}" ;;
      *) return 1 ;;
    esac
  }
  is_alpine() { return 1; }
  configure_fail2ban >/dev/null
  grep -Fxq 'journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session' "$FAIL2BAN_JAIL" \
    || fail 'Fail2ban managed jail did not override the Debian journalmatch default'

  is_alpine() { return 0; }
  nft() { :; }
  alpine_ssh_log_path() { printf '/var/log/auth.log\n'; }
  configure_fail2ban >/dev/null
  grep -Fxq 'backend = polling' "$FAIL2BAN_JAIL" || fail 'Alpine Fail2ban jail lost its polling backend'
  if grep -q '^journalmatch' "$FAIL2BAN_JAIL"; then fail 'Alpine Fail2ban jail gained a journalmatch override'; fi
)
(
  fail2ban_checks=0
  fail2ban_sleeps=0
  service_active() { [[ "$1" == fail2ban ]] && (( fail2ban_sleeps >= 1 )); }
  timeout() {
    [[ "$#" == 4 && "$1" == 2 && "$2" == fail2ban-client && "$3" == status && "$4" == sshd ]] || return 2
    (( ++fail2ban_checks >= 3 ))
  }
  sleep() { (( ++fail2ban_sleeps )); }
  assert_true wait_for_fail2ban_sshd
  [[ "$fail2ban_checks:$fail2ban_sleeps" == 3:3 ]] || fail 'Fail2ban readiness did not wait for service and jail'

  fail2ban_checks=0
  fail2ban_sleeps=0
  service_active() { return 0; }
  timeout() { (( ++fail2ban_checks )); return 1; }
  assert_false wait_for_fail2ban_sshd
  [[ "$fail2ban_checks:$fail2ban_sleeps" == 10:9 ]] || fail 'Fail2ban readiness did not stop at the retry limit'
)
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
apply_ipv6_disable_values
[[ "$(<"$IPV6_CONF_DIR/all/disable_ipv6")" == 1 ]] || fail 'IPv6 all state was not disabled'
[[ "$(<"$IPV6_CONF_DIR/default/disable_ipv6")" == 1 ]] || fail 'IPv6 default state was not disabled'
[[ "$(<"$IPV6_CONF_DIR/eth0/disable_ipv6")" == 1 ]] || fail 'IPv6 interface state was not disabled'
[[ "$(<"$IPV6_CONF_DIR/lo/disable_ipv6")" == 1 ]] || fail 'IPv6 loopback state was not disabled'
[[ "$(<"$IPV6_CONF_DIR/eth1/disable_ipv6")" == 1 ]] || fail 'new IPv6 interface state was not disabled'
IPV6_CONF_DIR="$ORIGINAL_IPV6_CONF_DIR"
IPV6_SNAPSHOT="$ORIGINAL_IPV6_SNAPSHOT"

(
  mktemp() {
    [[ "$1" == *XXXXXX ]] || return 1
    command mktemp "$@"
  }
  JSON_TEMP="$(make_temp_json)" || fail 'Xray JSON temp file fails with BusyBox mktemp template rules'
  [[ "$JSON_TEMP" == *.json && -f "$JSON_TEMP" ]] || fail 'Xray temporary config does not use .json suffix'
)

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
kbdinteractiveauthentication no
permitemptypasswords no
maxauthtries 8
logingracetime 60
x11forwarding no
allowagentforwarding no
allowtcpforwarding yes
EOF
}
assert_true validate_ssh_effective_settings 58911
assert_true validate_ssh_auth_settings yes
sshd() {
  cat <<'EOF'
port 58911
permitrootlogin prohibit-password
passwordauthentication no
pubkeyauthentication yes
kbdinteractiveauthentication no
permitemptypasswords no
maxauthtries 8
logingracetime 60
x11forwarding no
allowagentforwarding no
allowtcpforwarding yes
EOF
}
assert_true validate_ssh_effective_settings 58911
assert_true validate_ssh_auth_settings no
if validate_ssh_auth_settings yes 2>/dev/null; then fail 'SSH authentication mismatch was accepted'; fi

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
grep -q 'vpsinit system ufw-enable' <<<"$help_output" || fail 'help missing UFW enable command'
grep -q 'vpsinit system ufw-disable' <<<"$help_output" || fail 'help missing UFW disable command'
grep -q 'vpsinit system ufw-status' <<<"$help_output" || fail 'help missing UFW status command'
grep -q 'vpsinit system fail2ban-status' <<<"$help_output" || fail 'help missing Fail2ban status command'
grep -q 'vpsinit system fail2ban-enable' <<<"$help_output" || fail 'help missing Fail2ban enable command'
grep -q 'vpsinit system fail2ban-disable' <<<"$help_output" || fail 'help missing Fail2ban disable command'
grep -q 'vpsinit version' <<<"$help_output" || fail 'help missing version command'
[[ "$(bash "$ROOT_DIR/vpsinit.sh" version)" == 'vpsinit 0.1.43' ]] || fail 'version command output mismatch'
grep -Fq 'vpsinit update|self-update' <<<"$help_output" || fail 'help missing update alias'

grep -q 'LLMNR=no' "$ROOT_DIR/vpsinit.sh" || fail 'LLMNR setting missing'
grep -q 'net.ipv6.conf.all.disable_ipv6 = 1' "$ROOT_DIR/vpsinit.sh" || fail 'IPv6 disable setting missing'
grep -q 'current_ssh_uses_ipv6' "$ROOT_DIR/vpsinit.sh" || fail 'IPv6 SSH lockout check missing'
grep -Fq 'net.ipv6.conf.*.disable_ipv6 = 1' "$ROOT_DIR/vpsinit.sh" || fail 'systemd-sysctl per-interface IPv6 persistence missing'
grep -Fq 'apply_ipv6_disable_values' "$ROOT_DIR/vpsinit.sh" || fail 'per-interface IPv6 disable application missing'
grep -Fq 'After=network-online.target cloud-init-network.service' "$ROOT_DIR/vpsinit.sh" || fail 'post-network IPv6 persistence ordering missing'
grep -Fq 'ExecStart=$IPV6_BOOT_HELPER' "$ROOT_DIR/vpsinit.sh" || fail 'IPv6 boot helper service missing'
grep -Fq 'install_ipv6_boot_service' <<<"$(declare -f disable_ipv6)" || fail 'IPv6 disable does not install boot persistence service'
grep -Fq 'remove_ipv6_boot_service' <<<"$(declare -f enable_ipv6)" || fail 'IPv6 enable does not remove boot persistence service'
grep -Fq 'ipv6_disable_persistence_ready' <<<"$(declare -f disable_ipv6)" || fail 'IPv6 disabled fast path ignores persistence health'
grep -Fq 'ensure_package_installed "$package"' <<<"$(declare -f disable_ipv6)" || fail 'IPv6 disable does not skip installed dependencies'
if declare -f disable_ipv6 | grep -Fq 'install_packages iproute2'; then fail 'IPv6 disable still unconditionally invokes apt'; fi
if declare -f enable_ipv6 | grep -Fq 'install_packages iproute2'; then fail 'IPv6 enable still unconditionally invokes apt'; fi
grep -q 'snapshot_ipv6_disable_states' "$ROOT_DIR/vpsinit.sh" || fail 'per-interface IPv6 rollback snapshot missing'
if declare -f disable_ipv6 | grep -Fq 'sysctl -p'; then fail 'IPv6 disable still feeds a systemd-sysctl glob to procps sysctl'; fi
if declare -f restore_ipv6_config | grep -Fq 'sysctl -p'; then fail 'IPv6 rollback still feeds a systemd-sysctl glob to procps sysctl'; fi
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
grep -Fq 'update|self-update) self_update ;;' "$ROOT_DIR/vpsinit.sh" || fail 'update command alias missing'
(
  require_root() { :; }
  download_file() {
    printf '%s\n' '#!/usr/bin/env bash' 'TOOL_NAME="vpsinit"' 'printf "%s\\n" "$1"' >"$2"
  }
  install() {
    [[ "$1:$2:$3:$4:$5" == '-D:-o:root:-g:root' ]] || fail 'bootstrap install flags changed'
    shift 5
    command install -D "$@"
  }
  VPSINIT_SKIP_BOOTSTRAP=0
  INSTALL_PATH="$RUNTIME_DIR/bootstrap/usr/local/sbin/vpsinit"
  [[ "$(bootstrap_self bootstrap-ok 2>/dev/null | tail -n 1)" == bootstrap-ok ]] || fail 'first install without destination directory failed'
  [[ -x "$INSTALL_PATH" ]] || fail 'bootstrap did not install the executable'
  INSTALL_PATH="$RUNTIME_DIR/self-update/usr/local/sbin/vpsinit"
  self_update >/dev/null 2>&1
  [[ -x "$INSTALL_PATH" ]] || fail 'self-update did not create the destination directory'
)
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
grep -Fq 'ufw) configure_ufw_standalone' "$ROOT_DIR/vpsinit.sh" || fail 'UFW configure command dispatch missing'
grep -Fq 'ufw-status) show_ufw_status' "$ROOT_DIR/vpsinit.sh" || fail 'UFW status command dispatch missing'
grep -Fq 'ufw-enable) enable_ufw' "$ROOT_DIR/vpsinit.sh" || fail 'UFW enable command dispatch missing'
grep -Fq 'ufw-disable) disable_ufw' "$ROOT_DIR/vpsinit.sh" || fail 'UFW disable command dispatch missing'
grep -Fq 'fail2ban) configure_fail2ban_standalone' "$ROOT_DIR/vpsinit.sh" || fail 'Fail2ban configure command dispatch missing'
grep -Fq 'fail2ban-status) show_fail2ban_status' "$ROOT_DIR/vpsinit.sh" || fail 'Fail2ban status command dispatch missing'
grep -Fq 'fail2ban-enable) enable_fail2ban' "$ROOT_DIR/vpsinit.sh" || fail 'Fail2ban enable command dispatch missing'
grep -Fq 'fail2ban-disable) disable_fail2ban' "$ROOT_DIR/vpsinit.sh" || fail 'Fail2ban disable command dispatch missing'
grep -Fq 'xray:status|xray:logs|system:ufw-status|system:fail2ban-status|system:ipv6-status)' "$ROOT_DIR/vpsinit.sh" || fail 'read-only status command incorrectly takes mutation lock'
if grep -Eq 'system:ipv6-(enable|disable)[^)]*\)' "$ROOT_DIR/vpsinit.sh"; then fail 'IPv6 mutation command incorrectly bypasses operation lock'; fi
if grep -Eq 'system:(ufw|fail2ban)-(enable|disable)[^)]*\)' "$ROOT_DIR/vpsinit.sh"; then fail 'firewall mutation command incorrectly bypasses operation lock'; fi
grep -Fq 'show_ipv6_status' <<<"$(declare -f enable_ipv6)" || fail 'IPv6 enable does not show status first'
grep -Fq 'show_ipv6_status' <<<"$(declare -f disable_ipv6)" || fail 'IPv6 disable does not show status first'
grep -Fq 'save_ipv6_restore_snapshot' <<<"$(declare -f disable_ipv6)" || fail 'IPv6 disable does not save restore snapshot'
grep -Fq '[[ ! -e "$IPV6_SYSCTL" && -z "$external" ]]' <<<"$(declare -f enable_ipv6)" || fail 'IPv6 enable can ignore persistent disable configuration'
grep -Fq 'show_ufw_status' <<<"$(declare -f enable_ufw)" || fail 'UFW enable does not show status first'
grep -Fq 'show_ufw_status' <<<"$(declare -f disable_ufw)" || fail 'UFW disable does not show status first'
grep -Fq 'ufw_has_allow_rule "$ssh_port"' <<<"$(declare -f enable_ufw)" || fail 'UFW enable does not protect current SSH port'
grep -Fq 'show_fail2ban_status' <<<"$(declare -f enable_fail2ban)" || fail 'Fail2ban enable does not show status first'
grep -Fq 'show_fail2ban_status' <<<"$(declare -f disable_fail2ban)" || fail 'Fail2ban disable does not show status first'
grep -Fq 'fail2ban-client -t' <<<"$(declare -f enable_fail2ban)" || fail 'Fail2ban enable does not validate configuration'
grep -Fq 'configured_port' <<<"$(declare -f enable_fail2ban)" || fail 'Fail2ban enable does not verify SSH port'
grep -Fq 'fail2ban-client get sshd actions' <<<"$(declare -f show_fail2ban_status)" || fail 'Fail2ban status does not show ban actions'
grep -Fq 'ufw status verbose' "$ROOT_DIR/vpsinit.sh" || fail 'UFW verbose status output missing'
grep -Fq 'ufw show added' "$ROOT_DIR/vpsinit.sh" || fail 'UFW configured rules output missing'
grep -Fq 'apt-get 收到 SIGKILL' "$ROOT_DIR/vpsinit.sh" || fail 'apt-get SIGKILL diagnosis missing'
grep -Fq "journalctl -k -b --no-pager" "$ROOT_DIR/vpsinit.sh" || fail 'kernel OOM log collection missing'
if grep -Fq 'DEBIAN_FRONTEND=noninteractive apt-get update' "$ROOT_DIR/vpsinit.sh"; then fail 'apt-get update bypasses shared error handling'; fi
grep -q 'MaxAuthTries 8' "$ROOT_DIR/vpsinit.sh" || fail 'SSH MaxAuthTries mismatch'
grep -Fq '请粘贴一整行 root SSH 公钥' "$ROOT_DIR/vpsinit.sh" || fail 'manual root SSH key prompt missing'
grep -Fq 'wizard_step "是否覆盖 root SSH 公钥？" y configure_root_key' "$ROOT_DIR/vpsinit.sh" || fail 'root SSH key step is not enabled by default'
grep -Fq 'port="$(read_required_port '\''请输入新的 SSH 端口'\'')"' "$ROOT_DIR/vpsinit.sh" || fail 'SSH port still has a default value'
grep -Fq '是否允许 root 用户使用密码登录？' "$ROOT_DIR/vpsinit.sh" || fail 'root password-login prompt missing'
grep -Fq 'SSH_AUTH_DROPIN="/etc/ssh/sshd_config.d/00-vpsinit-auth.conf"' "$ROOT_DIR/vpsinit.sh" || fail 'independent SSH authentication drop-in missing'
grep -Fq 'run_wizard_action configure_root_login_policy' "$ROOT_DIR/vpsinit.sh" || fail 'root login policy is not an independent wizard action'
key_step_line="$(grep -nF 'wizard_step "是否覆盖 root SSH 公钥？"' "$ROOT_DIR/vpsinit.sh" | cut -d: -f1)"
auth_step_line="$(grep -nF 'run_wizard_action configure_root_login_policy' "$ROOT_DIR/vpsinit.sh" | cut -d: -f1)"
port_step_line="$(grep -nF 'wizard_step "是否修改 SSH 端口并应用加固策略？"' "$ROOT_DIR/vpsinit.sh" | cut -d: -f1)"
(( key_step_line < auth_step_line && auth_step_line < port_step_line )) || fail 'SSH key, authentication and port steps are not independent and ordered'
grep -Fq 'PermitRootLogin $permit_root_login' <<<"$(declare -f configure_root_login_policy)" || fail 'root login policy is not configurable'
grep -Fq 'PasswordAuthentication $password_authentication' <<<"$(declare -f configure_root_login_policy)" || fail 'password authentication policy is not configurable'
grep -Fq 'KbdInteractiveAuthentication no' "$ROOT_DIR/vpsinit.sh" || fail 'keyboard-interactive authentication is not disabled'
if declare -f configure_ssh | grep -Eq 'PermitRootLogin|PasswordAuthentication|ROOT_PASSWORD_LOGIN'; then fail 'SSH port step still overwrites root login policy'; fi
grep -Fq 'UUID 获取方式 [回车：自动生成；a：手动指定]' "$ROOT_DIR/vpsinit.sh" || fail 'UUID method prompt mismatch'
grep -Fq 'Short ID 获取方式 [回车：自动生成；a：手动指定]' "$ROOT_DIR/vpsinit.sh" || fail 'Short ID method prompt mismatch'
[[ "$(grep -Fc '请按回车自动生成，或输入 a 手动指定。' "$ROOT_DIR/vpsinit.sh")" -eq 3 ]] || fail 'Xray credential invalid-choice prompt mismatch'
grep -Fq '请输入 REALITY 目标域名' "$ROOT_DIR/vpsinit.sh" || fail 'manual REALITY target prompt missing'
if grep -Eq 'DEFAULT_(ROOT_SSH_KEY|XRAY_UUID|XRAY_SHORT_ID)|REALITY 目标域名 \[www\.bing\.com\]|请输入新的 SSH 端口.*58911' "$ROOT_DIR/vpsinit.sh"; then fail 'removed default values remain'; fi
grep -Fq '"target": "$target:443"' "$ROOT_DIR/vpsinit.sh" || fail 'REALITY target is not derived from domain and port 443'
grep -Fq '"serverNames": [' "$ROOT_DIR/vpsinit.sh" || fail 'REALITY serverNames config missing'
grep -Fq 'REALITY 密钥获取方式 [回车：自动生成；a：手动指定]' "$ROOT_DIR/vpsinit.sh" || fail 'REALITY key selection prompt mismatch'
grep -q 'SSH_DROPIN="/etc/ssh/sshd_config.d/00-vpsinit.conf"' "$ROOT_DIR/vpsinit.sh" || fail 'SSH drop-in priority mismatch'
grep -Fq '检测到当前 SSH 配置端口：${configured_port_list}，将全部替换为 ${port}。' "$ROOT_DIR/vpsinit.sh" || fail 'existing SSH ports are not reported for replacement'
grep -Fq '检测到多个 SSH 配置端口：${configured_port_list}，拒绝自动接管。' "$ROOT_DIR/vpsinit.sh" || fail 'multiple SSH port conflict guard missing'
grep -Fq 'ssh_ports_are_safe_to_migrate "${configured_ports[@]}"' "$ROOT_DIR/vpsinit.sh" || fail 'safe SSH multi-port migration guard missing'
grep -Fq 'prior_ufw_ssh_port="$(state_get UFW_SSH_PORT' "$ROOT_DIR/vpsinit.sh" || fail 'prior owned SSH UFW rule is not tracked'
if grep -Fq 'delete allow "$old_port/tcp"' "$ROOT_DIR/vpsinit.sh"; then fail 'SSH migration still deletes an unowned old-port UFW rule'; fi
grep -q 'show_xray_client "$@" >/dev/tty' "$ROOT_DIR/vpsinit.sh" || fail 'one-time Xray output is not terminal-only'
client_output="$(show_xray_client node.example 443 fixture-uuid fixture-key 0123 target.example 'Test Node')"
awk '/^  reality-opts:$/ {in_reality=1; next} /^  [^ ]/ {in_reality=0} in_reality && /^    support-x25519mlkem768: true$/ {found=1} END {exit !found}' <<<"$client_output" \
  || fail 'Mihomo REALITY hybrid key exchange option missing'
grep -Eq '^vless://[^#]+&support-x25519mlkem768=true#Test%20Node$' <<<"$client_output" \
  || fail 'VLESS URL missing hybrid key exchange query parameter before the node name'
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

(
  SYSTEM_ID=alpine
  SYSTEM_ARCH=arm64
  assert_true platform_supported alpine 3.21
  assert_true platform_supported alpine 3.21.0
  assert_true platform_supported alpine 3.22.1
  assert_true platform_supported alpine 3.23.2
  assert_true platform_supported alpine 3.24
  assert_true platform_supported alpine 3.25.1
  assert_true platform_supported alpine 4.0
  assert_false platform_supported alpine 3.20.9
  assert_false platform_supported alpine 3.21.0_rc1
  assert_false platform_supported alpine edge
  [[ "$(distro_connectivity_host)" == dl-cdn.alpinelinux.org ]] || fail 'Alpine connectivity host mismatch'
  [[ "$(alpine_xray_asset amd64)" == Xray-linux-64.zip ]] || fail 'Alpine x86_64 release mismatch'
  [[ "$(alpine_xray_asset arm64)" == Xray-linux-arm64-v8a.zip ]] || fail 'Alpine ARM64 release mismatch'
  [[ "$(xray_service_user)" == vpsinit-xray ]] || fail 'Alpine Xray must use the dedicated service account'
  [[ "$(xray_service_name)" == xray ]] || fail 'Alpine Xray OpenRC service name mismatch'
  (
    XRAY_CONFIG="$RUNTIME_DIR/legacy-xray.json"
    XRAY_ALPINE_CONFIG="$RUNTIME_DIR/new-xray.json"
    touch "$XRAY_CONFIG"
    select_alpine_xray_config
    [[ "$XRAY_CONFIG" == "$RUNTIME_DIR/legacy-xray.json" ]] || fail 'existing Alpine Xray config was not preserved'
    rm "$XRAY_CONFIG"
    select_alpine_xray_config
    [[ "$XRAY_CONFIG" == "$XRAY_ALPINE_CONFIG" ]] || fail 'fresh Alpine install uses legacy config path'
  )

  calls="$RUNTIME_DIR/alpine-calls"
  systemctl() { fail 'unexpected systemctl on Alpine'; }
  apt-get() { fail 'unexpected apt-get on Alpine'; }
  sshd() { :; }
  apk() {
    if [[ "$*" == $'info\n-e\nnot-installed' ]]; then return 1; fi
    printf 'apk %s\n' "$(IFS=' '; printf '%s' "$*")" >>"$calls"
  }
  install_packages openssh-server iproute2
  assert_true package_is_installed ufw
  assert_false package_is_installed not-installed
  system_update
  grep -Fxq 'apk add --update-cache openssh-server-common-openrc iproute2 iproute2-ss' "$calls" || fail 'Alpine package mapping mismatch'
  grep -Fxq 'apk upgrade --update-cache' "$calls" || fail 'Alpine upgrade not executed'

  runlevels="$RUNTIME_DIR/mock-runlevels"
  mkdir -p "$runlevels"
  rc-service() {
    printf 'rc-service %s %s\n' "$1" "$2" >>"$calls"
    case "$2" in
      status) [[ -e "$RUNTIME_DIR/$1.active" ]] ;;
      start|restart) touch "$RUNTIME_DIR/$1.active" ;;
      stop) rm -f "$RUNTIME_DIR/$1.active" ;;
      reload) [[ "$1" == sshd ]] ;;
      *) fail "unexpected rc-service action $2" ;;
    esac
  }
  rc-update() {
    local entry
    case "$1" in
      show)
        for entry in "$RUNTIME_DIR/mock-runlevels/"*; do
          if [[ -f "$entry" ]]; then cat "$entry"; fi
        done
        ;;
      add) printf '%s | %s\n' "$2" "$3" >"$RUNTIME_DIR/mock-runlevels/$2" ;;
      del) rm "$RUNTIME_DIR/mock-runlevels/$2" ;;
      *) fail "unexpected rc-update action $1" ;;
    esac
  }
  assert_false ssh_socket_enabled
  restart_ssh_service
  grep -Fxq 'rc-service sshd reload' "$calls" || fail 'Alpine SSH port migration stops existing sessions'
  assert_false service_active xray
  service_enable_now xray
  assert_true service_enabled xray
  assert_true service_active xray
  (
    sleep() { touch "$RUNTIME_DIR/mock-xray-ready"; }
    ss() {
      [[ "$1:$2:$3" == '-H:-ltn:sport = :443' ]] || fail 'unexpected Alpine Xray socket check'
      if [[ -e "$RUNTIME_DIR/mock-xray-ready" ]]; then printf 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*\n'; fi
    }
    assert_true wait_for_alpine_xray_listener 443
    [[ -e "$RUNTIME_DIR/mock-xray-ready" ]] || fail 'Xray readiness probe did not retry'
    sleep() { :; }
    ss() { :; }
    assert_false wait_for_alpine_xray_listener 443
  )
  service_disable_now xray
  assert_false service_enabled xray
  assert_false service_active xray

  IPV6_SYSCTL="$RUNTIME_DIR/ipv6-sysctl"
  IPV6_BOOT_HELPER="$RUNTIME_DIR/ipv6-helper"
  IPV6_BOOT_SERVICE="$RUNTIME_DIR/ipv6-openrc"
  IPV6_BOOT_SERVICE_NAME="ipv6-openrc"
  printf '%s\n' '# Managed by vpsinit' 'net.ipv6.conf.all.disable_ipv6 = 1' >"$IPV6_SYSCTL"
  install() {
    if [[ "$1" == -d ]]; then return 0; fi
    cp "${@: -2}"
    chmod +x "${@: -1}"
  }
  install_ipv6_boot_service
  assert_true ipv6_disable_persistence_ready
  grep -Fxq '#!/sbin/openrc-run' "$IPV6_BOOT_SERVICE" || fail 'IPv6 persistence does not use OpenRC'
  grep -Fxq '    need net' "$IPV6_BOOT_SERVICE" || fail 'IPv6 persistence does not wait on the network'
  remove_ipv6_boot_service
  assert_false ipv6_disable_persistence_ready
  [[ ! -e "$IPV6_BOOT_HELPER" && ! -e "$IPV6_BOOT_SERVICE" ]] || fail 'IPv6 persistence files not removed'
  unset -f install

  (
    LOG_DIR="$RUNTIME_DIR"
    XRAY_LOG="$RUNTIME_DIR/mock-xray-service.log"
    printf 'mock startup failure\n' >"$XRAY_LOG"
    save_alpine_xray_startup_log
    rm "$XRAY_LOG"
    [[ "$(xray_logs)" == 'mock startup failure' ]] || fail 'Alpine Xray logs lost startup failure after rollback'
  )

  asset_url='https://github.com/XTLS/Xray-core/releases/download/v1.0.0/Xray-linux-arm64-v8a.zip'
  printf 'synthetic release archive' >"$RUNTIME_DIR/archive-fixture"
  fixture_digest="sha256:$(sha256sum "$RUNTIME_DIR/archive-fixture" | cut -d ' ' -f 1)"
  download_file() {
    case "$1" in
      "$XRAY_RELEASE_API") printf '{}' >"$2" ;;
      "$asset_url") cp "$RUNTIME_DIR/archive-fixture" "$2" ;;
      *) fail "unexpected Xray URL $1" ;;
    esac
  }
  jq() {
    [[ "$3" == asset && "$4" == Xray-linux-arm64-v8a.zip ]] || fail 'incorrect Xray asset selection'
    case "$5" in
      *.browser_download_url) printf '%s\n' "$asset_url" ;;
      *.digest) printf '%s\n' "$fixture_digest" ;;
      *) fail 'unexpected jq expression' ;;
    esac
  }
  unzip() {
    printf 'xray fixture' >"$5/xray"
    touch "$RUNTIME_DIR/extracted"
  }
  bundle="$(download_alpine_xray_release)"
  [[ -s "$bundle/xray" ]] || fail 'Xray archive was not extracted after checksum verification'
  rm "$RUNTIME_DIR/extracted"
  fixture_digest="sha256:$(printf '%064d' 0)"
  if (download_alpine_xray_release) >/dev/null 2>&1; then fail 'Xray accepted a corrupt release'; fi
  [[ ! -e "$RUNTIME_DIR/extracted" ]] || fail 'Xray extracted the archive before checksum verification'
)

printf 'PASS: vpsinit static tests\n'
