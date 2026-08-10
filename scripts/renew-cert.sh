#!/usr/bin/env bash
set -euo pipefail

domain="${1:?usage: renew-cert.sh DOMAIN PUBLIC_CERT_PATH PFX_PATH}"
public_certificate_path="${2:?usage: renew-cert.sh DOMAIN PUBLIC_CERT_PATH PFX_PATH}"
pfx_path="${3:?usage: renew-cert.sh DOMAIN PUBLIC_CERT_PATH PFX_PATH}"

: "${CF_API_TOKEN:?CF_API_TOKEN is required}"
: "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL is required}"

umask 077
work_dir=$(mktemp -d)
public_tmp=""
pfx_tmp=""

cleanup() {
  rm -rf "$work_dir"
  [[ -z "$public_tmp" ]] || rm -f "$public_tmp"
  [[ -z "$pfx_tmp" ]] || rm -f "$pfx_tmp"
}
trap cleanup EXIT

credentials_path="$work_dir/cloudflare.ini"
printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" > "$credentials_path"
chmod 600 "$credentials_path"

certbot certonly \
  --non-interactive \
  --agree-tos \
  --email "$LETSENCRYPT_EMAIL" \
  --preferred-challenges dns-01 \
  --authenticator dns-cloudflare \
  --dns-cloudflare-credentials "$credentials_path" \
  --dns-cloudflare-propagation-seconds 60 \
  --config-dir "$work_dir/config" \
  --work-dir "$work_dir/work" \
  --logs-dir "$work_dir/logs" \
  --cert-name "$domain" \
  -d "$domain"

certificate="$work_dir/config/live/$domain/cert.pem"
chain="$work_dir/config/live/$domain/chain.pem"
fullchain="$work_dir/config/live/$domain/fullchain.pem"
private_key="$work_dir/config/live/$domain/privkey.pem"

for required_file in "$certificate" "$chain" "$fullchain" "$private_key"; do
  [[ -s "$required_file" ]] || {
    printf 'Required Certbot output is missing: %s\n' "$required_file" >&2
    exit 1
  }
done

openssl x509 -in "$certificate" -noout >/dev/null
openssl x509 -in "$fullchain" -noout >/dev/null

san_entries=$(openssl x509 -in "$certificate" -noout -ext subjectAltName \
  | tail -n +2 | tr ',' '\n' | sed 's/^[[:space:]]*//')
grep -Fxq "DNS:$domain" <<<"$san_entries" || {
  printf 'Issued certificate SAN does not contain %s\n' "$domain" >&2
  exit 1
}

not_before=$(openssl x509 -in "$certificate" -noout -startdate | cut -d= -f2-)
not_after=$(openssl x509 -in "$certificate" -noout -enddate | cut -d= -f2-)
not_before_epoch=$(date -u -d "$not_before" +%s)
not_after_epoch=$(date -u -d "$not_after" +%s)
now_epoch=$(date -u +%s)
(( now_epoch >= not_before_epoch && now_epoch < not_after_epoch )) || {
  printf 'Issued certificate is not currently valid\n' >&2
  exit 1
}

chain_count=$(grep -c 'BEGIN CERTIFICATE' "$fullchain")
(( chain_count >= 2 )) || {
  printf 'Issued certificate does not contain a full issuer chain\n' >&2
  exit 1
}
openssl verify -CAfile "$chain" "$certificate" >/dev/null

openssl x509 -in "$certificate" -noout -ext extendedKeyUsage \
  | grep -Eq 'TLS Web Server Authentication|serverAuth' || {
    printf 'Issued certificate does not allow TLS server authentication\n' >&2
    exit 1
  }

certificate_key_hash=$(
  openssl x509 -in "$certificate" -pubkey -noout \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | openssl dgst -sha256
)
private_key_hash=$(
  openssl pkey -in "$private_key" -pubout -outform DER 2>/dev/null \
    | openssl dgst -sha256
)
[[ "$certificate_key_hash" == "$private_key_hash" ]] || {
  printf 'Issued certificate and private key do not match\n' >&2
  exit 1
}

raw_pfx="$work_dir/$domain.pfx"
openssl pkcs12 -export \
  -inkey "$private_key" \
  -in "$certificate" \
  -certfile "$chain" \
  -out "$raw_pfx" \
  -name "$domain" \
  -passout pass:
openssl pkcs12 -in "$raw_pfx" -passin pass: -info -noout >/dev/null 2>&1
pfx_certificate_count=$(
  openssl pkcs12 -in "$raw_pfx" -passin pass: -nokeys 2>/dev/null \
    | grep -c 'BEGIN CERTIFICATE'
)
(( pfx_certificate_count >= 2 )) || {
  printf 'Generated PFX does not contain the full certificate chain\n' >&2
  exit 1
}
openssl pkcs12 -in "$raw_pfx" -passin pass: -nocerts -nodes 2>/dev/null \
  | openssl pkey -noout >/dev/null

mkdir -p "$(dirname "$public_certificate_path")" "$(dirname "$pfx_path")"
public_tmp=$(mktemp "$(dirname "$public_certificate_path")/.certificate.XXXXXX")
pfx_tmp=$(mktemp "$(dirname "$pfx_path")/.certificate-pfx.XXXXXX")
cp "$fullchain" "$public_tmp"
cp "$raw_pfx" "$pfx_tmp"
[[ -s "$pfx_tmp" ]] || {
  printf 'PFX output is empty\n' >&2
  exit 1
}

mv "$public_tmp" "$public_certificate_path"
public_tmp=""
mv "$pfx_tmp" "$pfx_path"
pfx_tmp=""

printf 'last_renewal=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
