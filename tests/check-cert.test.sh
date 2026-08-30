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
make_chain "$tmp/wrong" "wrong.windowsed.me" 40
make_chain "$tmp/near-match" "$domain.attacker" 40

make_special_chain() {
  local output_dir="$1"
  local extensions="$2"
  local common_name="${3:-wrong.windowsed.me}"
  mkdir -p "$output_dir"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=ValoUtils Test CA" \
    -keyout "$output_dir/ca.key" -out "$output_dir/ca.pem" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$common_name" \
    -keyout "$output_dir/privkey.pem" -out "$output_dir/leaf.csr" >/dev/null 2>&1
  printf '%s\n' "$extensions" > "$output_dir/extensions.cnf"
  openssl x509 -req -in "$output_dir/leaf.csr" \
    -CA "$output_dir/ca.pem" -CAkey "$output_dir/ca.key" -CAcreateserial \
    -days 10 -extfile "$output_dir/extensions.cnf" -extensions certificate \
    -out "$output_dir/cert.pem" >/dev/null 2>&1
  cat "$output_dir/cert.pem" "$output_dir/ca.pem" > "$output_dir/fullchain.pem"
}

make_special_chain "$tmp/no-san" $'[certificate]\nextendedKeyUsage=serverAuth'
make_special_chain "$tmp/no-san-matching-cn" \
  $'[certificate]\nextendedKeyUsage=serverAuth' "$domain"
make_special_chain "$tmp/uri-comma" \
  $'[certificate]\nsubjectAltName=@alternative_names\nextendedKeyUsage=serverAuth\n[alternative_names]\nURI.1=https://evil.invalid/,DNS:'"$domain"

result=$(scripts/check-cert.sh "$tmp/valid/fullchain.pem" "$domain")
assert_eq "true" "$(json_get "$result" parseable)" "valid certificate parseability"
assert_eq "true" "$(json_get "$result" hostname_valid)" "valid certificate hostname"
assert_eq "false" "$(json_get "$result" renewal_required)" "forty-day renewal decision"
assert_eq "valid" "$(json_get "$result" reason)" "forty-day reason"

result=$(scripts/check-cert.sh "$tmp/threshold/fullchain.pem" "$domain")
assert_eq "true" "$(json_get "$result" renewal_required)" "ten-day renewal decision"
assert_eq "renewal-threshold" "$(json_get "$result" reason)" "ten-day reason"

result=$(scripts/check-cert.sh "$tmp/wrong/fullchain.pem" "$domain")
assert_eq "false" "$(json_get "$result" hostname_valid)" "wrong hostname"
assert_eq "true" "$(json_get "$result" renewal_required)" "wrong-host renewal decision"
assert_eq "hostname-mismatch" "$(json_get "$result" reason)" "wrong-host reason"

result=$(scripts/check-cert.sh "$tmp/near-match/fullchain.pem" "$domain")
assert_eq "false" "$(json_get "$result" hostname_valid)" "near-match hostname"
assert_eq "hostname-mismatch" "$(json_get "$result" reason)" "near-match reason"

result=$(scripts/check-cert.sh "$tmp/no-san/fullchain.pem" "$domain")
assert_eq "false" "$(json_get "$result" hostname_valid)" "missing SAN hostname"

result=$(scripts/check-cert.sh "$tmp/no-san-matching-cn/fullchain.pem" "$domain")
assert_eq "false" "$(json_get "$result" hostname_valid)" "matching CN without SAN"

result=$(scripts/check-cert.sh "$tmp/uri-comma/fullchain.pem" "$domain")
assert_eq "false" "$(json_get "$result" hostname_valid)" "URI comma hostname"

result=$(scripts/check-cert.sh "$tmp/missing.pem" "$domain")
assert_eq "false" "$(json_get "$result" parseable)" "missing certificate parseability"
assert_eq "missing" "$(json_get "$result" reason)" "missing certificate reason"

printf 'not a certificate\n' > "$tmp/malformed.pem"
result=$(scripts/check-cert.sh "$tmp/malformed.pem" "$domain")
assert_eq "parse-error" "$(json_get "$result" reason)" "malformed certificate reason"

not_after=$(openssl x509 -in "$tmp/valid/fullchain.pem" -noout -enddate | cut -d= -f2-)
expired_now=$(date -u -d "$not_after" +%s)
expired_now=$((expired_now + 1))
result=$(CHECK_NOW_EPOCH="$expired_now" scripts/check-cert.sh "$tmp/valid/fullchain.pem" "$domain")
assert_eq "true" "$(json_get "$result" expired)" "expired flag"
assert_eq "false" "$(json_get "$result" currently_valid)" "expired validity"
assert_eq "expired" "$(json_get "$result" reason)" "expired reason"

printf 'check-cert tests passed\n'
