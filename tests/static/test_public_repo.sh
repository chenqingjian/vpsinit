#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

legacy_uuid='e11a650c-6ac3-4b0a-891a-'"a919f7a8098d"
legacy_short_id='7639d9da'"ee12c97b"
legacy_key_fragment='AAAAB3NzaC1yc2EAAAADAQABAAABgQCwkgzP252QnMhd'"XejJbNqjsn44"

for value in "$legacy_uuid" "$legacy_short_id" "$legacy_key_fragment"; do
  if git grep -I -Fq "$value" -- . ':!tests/static/test_public_repo.sh'; then
    fail "known legacy value remains in tracked files"
  fi
done

if git grep -n -I -E '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' -- .; then
  fail 'secret-like value found in tracked files'
fi

if grep -Eq 'SSH 高位端口，默认|Xray UUID 默认使用' README.md; then
  fail 'README still documents removed provisioning defaults'
fi

printf 'PASS: public repository safety checks\n'
