#!/usr/bin/env bash
set -euo pipefail

certificate_path="${1:?usage: generate-status.sh CERTIFICATE OUTPUT DOMAIN [STATUS_OVERRIDE] [RENEWAL_ISO]}"
output_path="${2:?usage: generate-status.sh CERTIFICATE OUTPUT DOMAIN [STATUS_OVERRIDE] [RENEWAL_ISO]}"
domain="${3:?usage: generate-status.sh CERTIFICATE OUTPUT DOMAIN [STATUS_OVERRIDE] [RENEWAL_ISO]}"
status_override="${4:-}"
renewal_iso="${5:-}"
now_iso="${STATUS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
now_epoch=$(date -u -d "$now_iso" +%s)

json_value() {
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
last_renewal="${renewal_iso:-$previous_renewal}"

inspection=$(CHECK_NOW_EPOCH="$now_epoch" scripts/check-cert.sh "$certificate_path" "$domain")
parseable=$(json_value "$inspection" parseable)
expired=$(json_value "$inspection" expired)
days_remaining=$(json_value "$inspection" days_remaining)
reason=$(json_value "$inspection" reason)

issuer=""
valid_from=""
valid_until=""
fingerprint=""

if [[ "$parseable" == true ]]; then
  issuer=$(openssl x509 -in "$certificate_path" -noout -issuer | sed 's/^issuer=//')
  not_before=$(openssl x509 -in "$certificate_path" -noout -startdate | cut -d= -f2-)
  not_after=$(openssl x509 -in "$certificate_path" -noout -enddate | cut -d= -f2-)
  valid_from=$(date -u -d "$not_before" +%Y-%m-%dT%H:%M:%SZ)
  valid_until=$(date -u -d "$not_after" +%Y-%m-%dT%H:%M:%SZ)
  fingerprint=$(openssl x509 -in "$certificate_path" -noout -fingerprint -sha256 | cut -d= -f2-)
fi

if [[ -n "$status_override" ]]; then
  status="$status_override"
elif [[ "$expired" == true ]]; then
  status=expired
elif [[ "$reason" == renewal-threshold ]]; then
  status=renewal-soon
elif [[ "$reason" == valid ]]; then
  status=valid
else
  status=error
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
LAST_CHECKED="$now_iso" \
LAST_RENEWAL="$last_renewal" \
  python - "$temporary_output" <<'PY'
import json
import os
import sys

status = {
    "domain": os.environ["DOMAIN"],
    "issuer": os.environ["ISSUER"],
    "valid_from": os.environ["VALID_FROM"],
    "valid_until": os.environ["VALID_UNTIL"],
    "days_remaining": int(os.environ["DAYS_REMAINING"]),
    "status": os.environ["STATUS"],
    "fingerprint_sha256": os.environ["FINGERPRINT"],
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
