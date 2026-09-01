#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../kmrinit.sh
source "$ROOT_DIR/kmrinit.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
[[ "$TOOL_VERSION" == '0.1.4' ]] || fail 'version constant mismatch'
if grep -nP '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]' "$ROOT_DIR/kmrinit.sh"; then fail 'unbraced variable adjacent to non-ASCII text'; fi
grep -Fq '8) self_update; restart_after_self_update ;;' "$ROOT_DIR/kmrinit.sh" || fail 'menu self-update does not restart the new script'
grep -Fq 'flock -u 9' "$ROOT_DIR/kmrinit.sh" || fail 'menu self-update does not release the operation lock'
grep -Fq "suffix='[y/n，回车默认为y]'" "$ROOT_DIR/kmrinit.sh" || fail 'yes-default prompt wording mismatch'
grep -Fq "suffix='[y/n，回车默认为n]'" "$ROOT_DIR/kmrinit.sh" || fail 'no-default prompt wording mismatch'
if grep -Fq "suffix='[Y/n]'" "$ROOT_DIR/kmrinit.sh" || grep -Fq "suffix='[y/N]'" "$ROOT_DIR/kmrinit.sh"; then fail 'yes/no prompt still encodes defaults with letter case'; fi
assert_true() { "$@" || fail "$*"; }
assert_false() { if "$@"; then fail "unexpected success: $*"; fi; }

assert_true valid_domain 'monitor.example.com'
assert_false valid_domain 'https://monitor.example.com'
assert_true valid_email ''
assert_true valid_email 'admin@example.com'
assert_false valid_email 'invalid-email'
assert_true valid_ipv4 '203.0.113.10'
assert_false valid_ipv4 '999.0.0.1'

IPV6_DISABLE_FILE="$RUNTIME_DIR/disable-ipv6"
printf '1\n' > "$IPV6_DISABLE_FILE"
assert_false ipv6_listen_enabled
printf '0\n' > "$IPV6_DISABLE_FILE"
assert_true ipv6_listen_enabled

TEST_PORT_COUNTER="$RUNTIME_DIR/test-port-counter"
printf '0\n' > "$TEST_PORT_COUNTER"
read_port() {
  local attempt
  attempt="$(cat "$TEST_PORT_COUNTER")"
  attempt=$((attempt + 1))
  printf '%s\n' "$attempt" > "$TEST_PORT_COUNTER"
  case "$attempt" in
    1) printf '80\n' ;;
    2) printf '443\n' ;;
    *) printf '30774\n' ;;
  esac
}
require_free_port() { return 0; }
[[ "$(read_komari_port 'test' 30774 2>/dev/null)" == 30774 ]] || fail 'reserved Komari ports did not retry'

UFW_CALLS="$RUNTIME_DIR/ufw-calls"
TEST_UFW_STATE=3
ufw() { local IFS=' '; printf '%s\n' "$*" >> "$UFW_CALLS"; }
state_get() { [[ "$1" == UFW_WEB && -n "$TEST_UFW_STATE" ]] && printf '%s\n' "$TEST_UFW_STATE"; }
state_delete() { [[ "$1" == UFW_WEB ]] && TEST_UFW_STATE=""; }
assert_true ufw_delete_web
grep -q '^--force delete allow 80/tcp$' "$UFW_CALLS" || fail 'inactive UFW 80 rule was not deleted'
grep -q '^--force delete allow 443/tcp$' "$UFW_CALLS" || fail 'inactive UFW 443 rule was not deleted'
[[ -z "$TEST_UFW_STATE" ]] || fail 'UFW ownership state was not cleared'

ROLLBACK_DIR="$RUNTIME_DIR/rollback"
BACKUP_DIR="$ROLLBACK_DIR/backup"
mkdir -p "$BACKUP_DIR"
KOMARI_SERVICE_FILE="$ROLLBACK_DIR/komari.service"
NGINX_SITE="$ROLLBACK_DIR/nginx-site"
NGINX_DEFAULT="$ROLLBACK_DIR/nginx-default"
NGINX_SITE_LINK="$ROLLBACK_DIR/nginx-link"
STATE_FILE="$ROLLBACK_DIR/state.conf"
for pair in 'komari.service' 'nginx-site' 'nginx-default' 'nginx-site-link' 'state.conf'; do printf 'old-%s\n' "$pair" > "$BACKUP_DIR/$pair"; done
printf 'new\n' > "$KOMARI_SERVICE_FILE"
printf 'new\n' > "$NGINX_SITE"
printf 'new\n' > "$NGINX_DEFAULT"
printf 'new\n' > "$NGINX_SITE_LINK"
printf 'new\n' > "$STATE_FILE"
systemctl() { return 0; }
nginx() { return 0; }
rollback_stack_configure "$BACKUP_DIR" '' 1 1
cmp -s "$BACKUP_DIR/komari.service" "$KOMARI_SERVICE_FILE" || fail 'Komari service rollback failed'
cmp -s "$BACKUP_DIR/nginx-site" "$NGINX_SITE" || fail 'Nginx site rollback failed'
cmp -s "$BACKUP_DIR/nginx-default" "$NGINX_DEFAULT" || fail 'Nginx default rollback failed'
cmp -s "$BACKUP_DIR/nginx-site-link" "$NGINX_SITE_LINK" || fail 'Nginx link rollback failed'
cmp -s "$BACKUP_DIR/state.conf" "$STATE_FILE" || fail 'state rollback failed'

NGINX_TEST_DIR="$RUNTIME_DIR/nginx-config"
NGINX_SITE="$NGINX_TEST_DIR/sites-available/kmrinit.conf"
NGINX_SITE_LINK="$NGINX_TEST_DIR/sites-enabled/kmrinit.conf"
NGINX_DEFAULT="$NGINX_TEST_DIR/conf.d/default.conf"
IPV6_DISABLE_FILE="$NGINX_TEST_DIR/disable-ipv6"
mkdir -p "$NGINX_TEST_DIR"
install() {
  if [[ "$1" == -d ]]; then
    mkdir -p "${@: -1}"
  else
    mkdir -p "$(dirname "${@: -1}")"
    cp "${@: -2:1}" "${@: -1}"
  fi
}
ln() { cp "$2" "$3"; }
printf '1\n' > "$IPV6_DISABLE_FILE"
write_nginx_configs monitor.example.com 30774 http
if grep -q 'listen \[::\]' "$NGINX_SITE" "$NGINX_DEFAULT"; then fail 'IPv6 listen remained while IPv6 disabled'; fi
printf '0\n' > "$IPV6_DISABLE_FILE"
write_nginx_configs monitor.example.com 30774 http
grep -q 'listen \[::\]:80' "$NGINX_SITE" || fail 'IPv6 listen missing while IPv6 enabled'

help_output="$(show_help)"
grep -q 'kmrinit install' <<<"$help_output" || fail 'help missing install'
grep -q 'kmrinit logs nginx|komari' <<<"$help_output" || fail 'help missing logs'

grep -q '127.0.0.1:\$port' "$ROOT_DIR/kmrinit.sh" || fail 'loopback bind missing'
grep -q 'ssl_reject_handshake on' "$ROOT_DIR/kmrinit.sh" || fail 'unknown HTTPS host rejection missing'
grep -q 'if ipv6_listen_enabled' "$ROOT_DIR/kmrinit.sh" || fail 'conditional Nginx IPv6 listen missing'
grep -q 'rollback_stack_configure' "$ROOT_DIR/kmrinit.sh" || fail 'configure rollback missing'
grep -q 'state_set ADDED_PACKAGES' "$ROOT_DIR/kmrinit.sh" || fail 'package ownership tracking missing'
if grep -q 'apt-get autoremove' "$ROOT_DIR/kmrinit.sh"; then fail 'unbounded autoremove remains'; fi
grep -q "SELF_URL=\"https://raw.githubusercontent.com/chenqingjian/vpsinit/main/kmrinit.sh\"" "$ROOT_DIR/kmrinit.sh" || fail 'self URL mismatch'

release_json() {
  cat <<'JSON'
{"tag_name":"v1.2.3","draft":false,"prerelease":false,"assets":[{"name":"komari-linux-amd64","browser_download_url":"https://github.com/komari-monitor/komari/releases/download/v1.2.3/komari-linux-amd64","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
JSON
}
python3() { python "$@"; }
release_info="$(komari_release_info)"
[[ "$(sed -n '1p' <<<"$release_info")" == 'v1.2.3' ]] || fail 'release tag parse failed'
[[ "$(sed -n '2p' <<<"$release_info")" == *'/komari-linux-amd64' ]] || fail 'release asset parse failed'
[[ "$(sed -n '3p' <<<"$release_info")" == 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]] || fail 'release digest parse failed'

printf 'PASS: kmrinit static tests\n'
