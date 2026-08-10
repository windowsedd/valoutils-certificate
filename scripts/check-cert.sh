#!/usr/bin/env bash
set -euo pipefail

certificate_path="${1:?usage: check-cert.sh CERTIFICATE_PATH EXPECTED_DOMAIN}"
expected_domain="${2:?usage: check-cert.sh CERTIFICATE_PATH EXPECTED_DOMAIN}"
now_epoch="${CHECK_NOW_EPOCH:-$(date -u +%s)}"
renewal_threshold_seconds=$((3 * 86400))

emit_result() {
  PARSEABLE="$1" \
  HOSTNAME_VALID="$2" \
  CURRENTLY_VALID="$3" \
  EXPIRED="$4" \
  DAYS_REMAINING="$5" \
  RENEWAL_REQUIRED="$6" \
  REASON="$7" \
    python - <<'PY'
import json
import os

def boolean(name):
    return os.environ[name] == "true"

print(json.dumps({
    "parseable": boolean("PARSEABLE"),
    "hostname_valid": boolean("HOSTNAME_VALID"),
    "currently_valid": boolean("CURRENTLY_VALID"),
    "expired": boolean("EXPIRED"),
    "days_remaining": int(os.environ["DAYS_REMAINING"]),
    "renewal_required": boolean("RENEWAL_REQUIRED"),
    "reason": os.environ["REASON"],
}, separators=(",", ":")))
PY
}

if [[ ! -s "$certificate_path" ]]; then
  emit_result false false false false 0 true missing
  exit 0
fi

if ! openssl x509 -in "$certificate_path" -noout >/dev/null 2>&1; then
  emit_result false false false false 0 true parse-error
  exit 0
fi

hostname_valid=$(
  CERTIFICATE_PATH="$certificate_path" EXPECTED_DOMAIN="$expected_domain" \
    python - <<'PY'
import os
import ssl

certificate = ssl._ssl._test_decode_cert(os.environ["CERTIFICATE_PATH"])
expected = os.environ["EXPECTED_DOMAIN"].casefold()
matches = any(
    kind == "DNS" and value.casefold() == expected
    for kind, value in certificate.get("subjectAltName", ())
)
print("true" if matches else "false")
PY
)

not_before=$(openssl x509 -in "$certificate_path" -noout -startdate | cut -d= -f2-)
not_after=$(openssl x509 -in "$certificate_path" -noout -enddate | cut -d= -f2-)
not_before_epoch=$(date -u -d "$not_before" +%s)
not_after_epoch=$(date -u -d "$not_after" +%s)
seconds_remaining=$((not_after_epoch - now_epoch))
days_remaining=$((seconds_remaining / 86400))
if (( days_remaining < 0 )); then
  days_remaining=0
fi

currently_valid=true
expired=false
renewal_required=true
reason=valid

if [[ "$hostname_valid" != true ]]; then
  currently_valid=false
  reason=hostname-mismatch
elif (( now_epoch < not_before_epoch )); then
  currently_valid=false
  reason=not-yet-valid
elif (( now_epoch >= not_after_epoch )); then
  currently_valid=false
  expired=true
  reason=expired
elif (( seconds_remaining <= renewal_threshold_seconds )); then
  reason=renewal-threshold
else
  renewal_required=false
fi

emit_result true "$hostname_valid" "$currently_valid" "$expired" \
  "$days_remaining" "$renewal_required" "$reason"
