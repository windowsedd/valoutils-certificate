#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
source tests/helpers.sh

domain="valoutils-tools.windowsed.me"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

make_chain "$tmp/valid" "$domain" 10
make_chain "$tmp/near-match" "$domain.attacker" 10

openssl pkcs12 -export \
  -inkey "$tmp/valid/privkey.pem" \
  -in "$tmp/valid/cert.pem" \
  -certfile "$tmp/valid/ca.pem" \
  -out "$tmp/valid.pfx" \
  -passout pass: >/dev/null 2>&1

openssl pkcs12 -export \
  -inkey "$tmp/valid/privkey.pem" \
  -in "$tmp/valid/cert.pem" \
  -out "$tmp/leaf-only.pfx" \
  -passout pass: >/dev/null 2>&1

openssl pkcs12 -export \
  -inkey "$tmp/near-match/privkey.pem" \
  -in "$tmp/near-match/cert.pem" \
  -certfile "$tmp/near-match/ca.pem" \
  -out "$tmp/near-match.pfx" \
  -passout pass: >/dev/null 2>&1

bash scripts/check-pfx.sh "$tmp/valid.pfx" "$domain"

if bash scripts/check-pfx.sh "$tmp/missing.pfx" "$domain" >/dev/null 2>&1; then
  fail "missing PFX unexpectedly passed validation"
fi
if bash scripts/check-pfx.sh "$tmp/leaf-only.pfx" "$domain" >/dev/null 2>&1; then
  fail "leaf-only PFX unexpectedly passed validation"
fi
if bash scripts/check-pfx.sh "$tmp/near-match.pfx" "$domain" >/dev/null 2>&1; then
  fail "near-match SAN unexpectedly passed validation"
fi

printf 'check-pfx tests passed\n'
