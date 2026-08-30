#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
source tests/helpers.sh

domain="valoutils-localhost.windowsed.me"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

make_chain "$tmp/valid" "$domain" 40
make_chain "$tmp/threshold" "$domain" 10
fixed_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

STATUS_NOW="$fixed_now" scripts/generate-status.sh \
  "$tmp/valid/fullchain.pem" "$tmp/status.json" "$domain"
status_json=$(<"$tmp/status.json")
assert_eq "$domain" "$(json_get "$status_json" domain)" "status domain"
assert_eq "valid" "$(json_get "$status_json" status)" "valid status"
assert_eq "$fixed_now" "$(json_get "$status_json" last_checked)" "last checked"
assert_eq "Let's Encrypt" "$(json_get "$status_json" issuer)" "issuer organization"
assert_eq "RSA 2048" "$(json_get "$status_json" key_algorithm)" "key algorithm"
python -c 'import json,sys; data=json.load(open(sys.argv[1], encoding="utf-8")); assert data["san"] == [sys.argv[2]], data["san"]' \
  "$tmp/status.json" "$domain"

python - "$tmp/status.json" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

assert data["valid_from"].endswith("Z")
assert data["valid_until"].endswith("Z")
assert isinstance(data["days_remaining"], int)
assert isinstance(data["san"], list) and data["san"] == ["valoutils-localhost.windowsed.me"]
assert re.fullmatch(r"([0-9A-F]{2}:){31}[0-9A-F]{2}", data["fingerprint_sha256"])
assert data["last_renewal"] == data["valid_from"], (
    "last_renewal should fall back to the certificate notBefore date"
)
PY

renewed_at="2026-08-09T14:40:00Z"
STATUS_NOW="$fixed_now" scripts/generate-status.sh \
  "$tmp/valid/fullchain.pem" "$tmp/status.json" "$domain" "$renewed_at"
status_json=$(<"$tmp/status.json")
assert_eq "$renewed_at" "$(json_get "$status_json" last_renewal)" "explicit renewal timestamp"

STATUS_NOW="$fixed_now" scripts/generate-status.sh \
  "$tmp/valid/fullchain.pem" "$tmp/status.json" "$domain"
status_json=$(<"$tmp/status.json")
assert_eq "$renewed_at" "$(json_get "$status_json" last_renewal)" "preserved renewal timestamp"

STATUS_NOW="$fixed_now" scripts/generate-status.sh \
  "$tmp/threshold/fullchain.pem" "$tmp/threshold-status.json" "$domain"
assert_eq "renewal-soon" \
  "$(json_get "$(<"$tmp/threshold-status.json")" status)" \
  "threshold status"

not_after=$(openssl x509 -in "$tmp/valid/fullchain.pem" -noout -enddate | cut -d= -f2-)
expired_epoch=$(date -u -d "$not_after" +%s)
expired_iso=$(date -u -d "@$((expired_epoch + 1))" +%Y-%m-%dT%H:%M:%SZ)
STATUS_NOW="$expired_iso" scripts/generate-status.sh \
  "$tmp/valid/fullchain.pem" "$tmp/expired-status.json" "$domain"
assert_eq "expired" "$(json_get "$(<"$tmp/expired-status.json")" status)" "expired status"

printf 'bad certificate\n' > "$tmp/malformed.pem"
STATUS_NOW="$fixed_now" scripts/generate-status.sh \
  "$tmp/malformed.pem" "$tmp/error-status.json" "$domain"
error_json=$(<"$tmp/error-status.json")
assert_eq "error" "$(json_get "$error_json" status)" "malformed certificate status"
assert_eq "" "$(json_get "$error_json" issuer)" "malformed issuer"
assert_eq "0" "$(json_get "$error_json" days_remaining)" "malformed days remaining"

printf 'generate-status tests passed\n'
