#!/usr/bin/env bash
set -euo pipefail

pfx_path="${1:?usage: check-pfx.sh PFX_PATH EXPECTED_DOMAIN}"
expected_domain="${2:?usage: check-pfx.sh PFX_PATH EXPECTED_DOMAIN}"

[[ -s "$pfx_path" ]] || exit 1
(( $(wc -c < "$pfx_path") <= 1048576 )) || exit 1

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
leaf="$work_dir/leaf.pem"
chain="$work_dir/chain.pem"
private_key="$work_dir/private-key.pem"
all_certificates="$work_dir/all-certificates.pem"

openssl pkcs12 -in "$pfx_path" -passin pass: -clcerts -nokeys \
  -out "$leaf" >/dev/null 2>&1
openssl pkcs12 -in "$pfx_path" -passin pass: -cacerts -nokeys \
  -out "$chain" >/dev/null 2>&1
openssl pkcs12 -in "$pfx_path" -passin pass: -nocerts -nodes \
  -out "$private_key" >/dev/null 2>&1
openssl pkcs12 -in "$pfx_path" -passin pass: -nokeys \
  -out "$all_certificates" >/dev/null 2>&1

certificate_count=$(awk '/BEGIN CERTIFICATE/{count++} END{print count+0}' "$all_certificates")
(( certificate_count >= 2 )) || exit 1
openssl verify -CAfile "$chain" "$leaf" >/dev/null

san_entries=$(openssl x509 -in "$leaf" -noout -ext subjectAltName \
  | tail -n +2 | tr ',' '\n' | sed 's/^[[:space:]]*//')
grep -Fxq "DNS:$expected_domain" <<<"$san_entries"

not_before=$(openssl x509 -in "$leaf" -noout -startdate | cut -d= -f2-)
not_after=$(openssl x509 -in "$leaf" -noout -enddate | cut -d= -f2-)
not_before_epoch=$(date -u -d "$not_before" +%s)
not_after_epoch=$(date -u -d "$not_after" +%s)
now_epoch=$(date -u +%s)
(( now_epoch >= not_before_epoch && now_epoch < not_after_epoch ))

openssl x509 -in "$leaf" -noout -ext extendedKeyUsage \
  | grep -Eq 'TLS Web Server Authentication|serverAuth'

certificate_key_hash=$(
  openssl x509 -in "$leaf" -pubkey -noout \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | openssl dgst -sha256
)
private_key_hash=$(
  openssl pkey -in "$private_key" -pubout -outform DER 2>/dev/null \
    | openssl dgst -sha256
)
[[ "$certificate_key_hash" == "$private_key_hash" ]]
