#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
source tests/helpers.sh

domain="valoutils-tools.windowsed.me"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

make_chain "$tmp/valid" "$domain" 4
make_chain "$tmp/threshold" "$domain" 3
make_chain "$tmp/wrong" "wrong.windowsed.me" 10

result=$(scripts/check-cert.sh "$tmp/valid/fullchain.pem" "$domain")
assert_eq "true" "$(json_get "$result" parseable)" "valid certificate parseability"
assert_eq "true" "$(json_get "$result" hostname_valid)" "valid certificate hostname"
assert_eq "false" "$(json_get "$result" renewal_required)" "four-day renewal decision"
assert_eq "valid" "$(json_get "$result" reason)" "four-day reason"

result=$(scripts/check-cert.sh "$tmp/threshold/fullchain.pem" "$domain")
assert_eq "true" "$(json_get "$result" renewal_required)" "three-day renewal decision"
assert_eq "renewal-threshold" "$(json_get "$result" reason)" "three-day reason"

result=$(scripts/check-cert.sh "$tmp/wrong/fullchain.pem" "$domain")
assert_eq "false" "$(json_get "$result" hostname_valid)" "wrong hostname"
assert_eq "true" "$(json_get "$result" renewal_required)" "wrong-host renewal decision"
assert_eq "hostname-mismatch" "$(json_get "$result" reason)" "wrong-host reason"

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
