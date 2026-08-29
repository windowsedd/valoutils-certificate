#!/usr/bin/env bash
# Build the public certificate status JSON from a certificate file.
#
# usage: generate-status.sh CERTIFICATE OUTPUT DOMAIN [RENEWAL_ISO]
#
# RENEWAL_ISO (optional) is the exact UTC timestamp of a renewal that just
# succeeded. Without it, the previous output file's last_renewal is kept and,
# failing that, the certificate notBefore date is used, so the field survives
# runs that did not renew.
#
# The status is derived naturally from the certificate state; this script has
# no status override parameter. Set STATUS_NOW to control the "last_checked"
# timestamp (used by tests).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

certificate_path="${1:?usage: generate-status.sh CERTIFICATE OUTPUT DOMAIN [RENEWAL_ISO]}"
output_path="${2:?usage: generate-status.sh CERTIFICATE OUTPUT DOMAIN [RENEWAL_ISO]}"
domain="${3:?usage: generate-status.sh CERTIFICATE OUTPUT DOMAIN [RENEWAL_ISO]}"
renewal_iso="${4:-}"
now_iso="${STATUS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
now_epoch=$(date -u -d "$now_iso" +%s)

json_field() {
  python -c 'import json,sys; value=json.loads(sys.argv[1])[sys.argv[2]]; print(str(value).lower() if isinstance(value, bool) else value)' "$1" "$2"
}

previous_renewal=""
if [[ -s "$output_path" ]]; then
  previous_renewal=$(python -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        print(json.load(handle).get("last_renewal", ""))
except (OSError, ValueError, TypeError):
    print("")
' "$output_path")
fi

inspection=$(CHECK_NOW_EPOCH="$now_epoch" "$SCRIPT_DIR/check-cert.sh" "$certificate_path" "$domain")
parseable=$(json_field "$inspection" parseable)
expired=$(json_field "$inspection" expired)
days_remaining=$(json_field "$inspection" days_remaining)
reason=$(json_field "$inspection" reason)

issuer=""
valid_from=""
valid_until=""
fingerprint=""
san_entries=""
key_algorithm=""

if [[ "$parseable" == true ]]; then
  issuer_dn=$(openssl x509 -in "$certificate_path" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')
  issuer=$(ISSUER_DN="$issuer_dn" python - <<'PY'
import os

dn = os.environ["ISSUER_DN"]
organization = common_name = ""
for part in dn.split(","):
    key, _, value = part.partition("=")
    key = key.strip()
    if key == "O":
        organization = value.strip()
    elif key == "CN":
        common_name = value.strip()
print(organization or common_name or dn)
PY
)
  not_before=$(openssl x509 -in "$certificate_path" -noout -startdate | cut -d= -f2-)
  not_after=$(openssl x509 -in "$certificate_path" -noout -enddate | cut -d= -f2-)
  valid_from=$(date -u -d "$not_before" +%Y-%m-%dT%H:%M:%SZ)
  valid_until=$(date -u -d "$not_after" +%Y-%m-%dT%H:%M:%SZ)
  fingerprint=$(openssl x509 -in "$certificate_path" -noout -fingerprint -sha256 | cut -d= -f2-)

  san_raw=$(openssl x509 -in "$certificate_path" -noout -ext subjectAltName 2>/dev/null | tail -n +2 || true)
  san_entries=$(printf '%s\n' "$san_raw" \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep '^DNS:' | sed 's/^DNS://' || true)

  key_text=$(openssl x509 -in "$certificate_path" -noout -text 2>/dev/null || true)
  key_algo_name=$(printf '%s\n' "$key_text" \
    | sed -n 's/.*Public Key Algorithm: *//p' | head -n 1 | tr -d '[:space:]')
  key_bits=$(printf '%s\n' "$key_text" \
    | sed -n 's/.*Public-Key: (\([0-9][0-9]*\) bit).*/\1/p' | head -n 1)
  case "$key_algo_name" in
    rsaEncryption) key_algorithm="RSA${key_bits:+ $key_bits}" ;;
    id-ecPublicKey) key_algorithm="EC${key_bits:+ $key_bits}" ;;
    "") key_algorithm="" ;;
    *) key_algorithm="$key_algo_name${key_bits:+ $key_bits}" ;;
  esac
fi

if [[ "$expired" == true ]]; then
  status=expired
elif [[ "$reason" == renewal-threshold ]]; then
  status=renewal-soon
elif [[ "$reason" == valid ]]; then
  status=valid
else
  status=error
fi

last_renewal="$renewal_iso"
if [[ -z "$last_renewal" ]]; then
  last_renewal="$previous_renewal"
fi
if [[ -z "$last_renewal" && -n "$valid_from" ]]; then
  last_renewal="$valid_from"
fi

output_dir=$(dirname "$output_path")
mkdir -p "$output_dir"
temporary_output=$(mktemp "$output_dir/.cert-status.XXXXXX")
trap 'rm -f "$temporary_output"' EXIT

DOMAIN="$domain" \
ISSUER="$issuer" \
VALID_FROM="$valid_from" \
VALID_UNTIL="$valid_until" \
DAYS_REMAINING="$days_remaining" \
STATUS="$status" \
FINGERPRINT="$fingerprint" \
SAN_ENTRIES="$san_entries" \
KEY_ALGORITHM="$key_algorithm" \
LAST_CHECKED="$now_iso" \
LAST_RENEWAL="$last_renewal" \
  python - "$temporary_output" <<'PY'
import json
import os
import sys

san = [line.strip() for line in os.environ.get("SAN_ENTRIES", "").splitlines() if line.strip()]

status = {
    "domain": os.environ["DOMAIN"],
    "status": os.environ["STATUS"],
    "issuer": os.environ["ISSUER"],
    "valid_from": os.environ["VALID_FROM"],
    "valid_until": os.environ["VALID_UNTIL"],
    "days_remaining": int(os.environ["DAYS_REMAINING"]),
    "fingerprint_sha256": os.environ["FINGERPRINT"],
    "san": san,
    "key_algorithm": os.environ["KEY_ALGORITHM"],
    "last_checked": os.environ["LAST_CHECKED"],
    "last_renewal": os.environ["LAST_RENEWAL"],
}

with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as handle:
    json.dump(status, handle, indent=2)
    handle.write("\n")
PY

python -m json.tool "$temporary_output" >/dev/null
mv "$temporary_output" "$output_path"
trap - EXIT
