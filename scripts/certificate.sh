#!/usr/bin/env bash
# ValoUtils certificate manager.
#
# One entry point for the whole certificate lifecycle:
#   inspect -> issue/renew through Let's Encrypt (Cloudflare DNS-01) when
#   needed -> validate -> generate the local PFX -> refresh public files.
#
# usage: scripts/certificate.sh [--force-renew]
#
# Storage is always relative to the project root, never /etc/letsencrypt:
#   letsencrypt/config|work|logs   local Certbot state (gitignored)
#   pfx-output/DOMAIN.pfx          local PFX with an empty password (gitignored)
#   docs/certificate.pem           public chain (committed on renewal only)
#   docs/cert-status.json          public status (deployed to Pages, not committed)
#
# Credentials are only required when a certificate is issued or renewed:
#   CF_API_TOKEN        environment variable (GitHub Actions), or
#   .secrets/cloudflare.ini  local file containing
#                        dns_cloudflare_api_token = <token>
#   LETSENCRYPT_EMAIL   Let's Encrypt account email (used when registering)
#
# The script never prints credential values and never replaces a currently
# valid public certificate with unvalidated output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="${CERTIFICATE_BASE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# The certificate covers the app's loopback hostname (DNS A record to
# 127.0.0.1). The GitHub Pages dashboard lives at valoutils-tools.windowsed.me;
# only this issuance hostname changes here.
DOMAIN="valoutils-localhost.windowsed.me"
RENEWAL_THRESHOLD_DAYS=30
LE_CONFIG="$BASE_DIR/letsencrypt/config"
LE_WORK="$BASE_DIR/letsencrypt/work"
LE_LOGS="$BASE_DIR/letsencrypt/logs"
SECRETS_FILE="$BASE_DIR/.secrets/cloudflare.ini"
LIVE_DIR="$LE_CONFIG/live/$DOMAIN"
PFX_FILE="$BASE_DIR/pfx-output/$DOMAIN.pfx"
PUBLIC_CERT="$BASE_DIR/docs/certificate.pem"
STATUS_JSON="$BASE_DIR/docs/cert-status.json"

force_renew=false
for argument in "$@"; do
  case "$argument" in
    --force-renew) force_renew=true ;;
    *)
      printf 'Unknown option: %s\nusage: certificate.sh [--force-renew]\n' "$argument" >&2
      exit 2
      ;;
  esac
done

umask 077
mkdir -p "$LE_CONFIG" "$LE_WORK" "$LE_LOGS"

temporary_credentials=""
temporary_files=()
cleanup() {
  [[ -z "$temporary_credentials" ]] || rm -f "$temporary_credentials"
  local file
  for file in ${temporary_files[@]+"${temporary_files[@]}"}; do
    rm -f "$file"
  done
}
trap cleanup EXIT

log() { printf '==> %s\n' "$*" >&2; }

json_field() {
  python -c 'import json,sys; value=json.loads(sys.argv[1])[sys.argv[2]]; print(str(value).lower() if isinstance(value, bool) else value)' "$1" "$2"
}

certificate_public_key_digest() {
  openssl x509 -in "$1" -pubkey -noout \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | openssl dgst -sha256
}

private_key_public_digest() {
  openssl pkey -in "$1" -pubout -outform DER 2>/dev/null \
    | openssl dgst -sha256
}

# Resolve Cloudflare credentials without ever printing the token value.
# Sets resolved_credentials in the parent shell (never call this inside a
# command substitution, or the cleanup trap could not see the temp file).
resolved_credentials=""
resolve_credentials() {
  if [[ -n "${CF_API_TOKEN:-}" ]]; then
    temporary_credentials="$(mktemp "${TMPDIR:-/tmp}/cloudflare-credentials.XXXXXX")"
    printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" > "$temporary_credentials"
    chmod 600 "$temporary_credentials"
    resolved_credentials="$temporary_credentials"
    return 0
  fi
  if [[ -s "$SECRETS_FILE" ]]; then
    resolved_credentials="$SECRETS_FILE"
    return 0
  fi
  return 1
}

# Full validation of the live Certbot directory. Prints the inspection JSON
# on success so the caller does not have to inspect the certificate twice.
validate_live_directory() {
  local cert="$LIVE_DIR/cert.pem"
  local chain="$LIVE_DIR/chain.pem"
  local fullchain="$LIVE_DIR/fullchain.pem"
  local private_key="$LIVE_DIR/privkey.pem"

  local file
  for file in "$cert" "$chain" "$fullchain" "$private_key"; do
    [[ -s "$file" ]] || {
      log "Live certificate file missing or empty: $file"
      return 1
    }
  done

  local inspection
  inspection=$("$SCRIPT_DIR/check-cert.sh" "$fullchain" "$DOMAIN") || return 1
  [[ "$(json_field "$inspection" parseable)" == "true" ]] || {
    log "Live certificate cannot be parsed"
    return 1
  }
  [[ "$(json_field "$inspection" hostname_valid)" == "true" ]] || {
    log "Live certificate SAN does not cover $DOMAIN"
    return 1
  }
  [[ "$(json_field "$inspection" currently_valid)" == "true" ]] || {
    log "Live certificate is not currently valid"
    return 1
  }

  local chain_count
  chain_count=$(grep -c 'BEGIN CERTIFICATE' "$fullchain" || true)
  (( chain_count >= 2 )) || {
    log "Live certificate does not include the issuer chain"
    return 1
  }
  openssl verify -CAfile "$chain" "$cert" >/dev/null 2>&1 || {
    log "Live certificate fails chain verification"
    return 1
  }

  openssl x509 -in "$cert" -noout -ext extendedKeyUsage 2>/dev/null \
    | grep -Eq 'TLS Web Server Authentication|serverAuth' || {
      log "Live certificate is not TLS server-authentication capable"
      return 1
    }

  [[ "$(certificate_public_key_digest "$cert")" == "$(private_key_public_digest "$private_key")" ]] || {
    log "Live private key does not match the certificate"
    return 1
  }

  printf '%s' "$inspection"
}

issue_certificate() {
  if ! resolve_credentials; then
    log "ERROR: Cloudflare credentials are required to issue or renew a certificate."
    log "Set the CF_API_TOKEN environment variable or create $SECRETS_FILE containing:"
    log "  dns_cloudflare_api_token = <Cloudflare API token with Zone:DNS:Edit for the zone>"
    return 1
  fi

  local certbot_args=(
    certonly
    --non-interactive
    --agree-tos
    --key-type rsa
    --rsa-key-size 2048
    --authenticator dns-cloudflare
    --dns-cloudflare-credentials "$resolved_credentials"
    --dns-cloudflare-propagation-seconds 30
    --config-dir "$LE_CONFIG"
    --work-dir "$LE_WORK"
    --logs-dir "$LE_LOGS"
    --cert-name "$DOMAIN"
    -d "$DOMAIN"
  )
  if [[ -n "${LETSENCRYPT_EMAIL:-}" ]]; then
    certbot_args+=(--email "$LETSENCRYPT_EMAIL")
  fi
  if [[ "$force_renew" == true ]]; then
    certbot_args+=(--force-renewal)
  fi

  certbot "${certbot_args[@]}"
}

generate_pfx() {
  mkdir -p "$(dirname "$PFX_FILE")"
  local temporary_pfx
  temporary_pfx="$(mktemp "$(dirname "$PFX_FILE")/.pfx.XXXXXX")"
  temporary_files+=("$temporary_pfx")

  openssl pkcs12 -export \
    -inkey "$LIVE_DIR/privkey.pem" \
    -in "$LIVE_DIR/fullchain.pem" \
    -out "$temporary_pfx" \
    -name "$DOMAIN" \
    -passout pass:

  "$SCRIPT_DIR/check-pfx.sh" "$temporary_pfx" "$DOMAIN"

  mv "$temporary_pfx" "$PFX_FILE"
  log "PFX written to $PFX_FILE (empty password, chain and key verified)."
}

update_public_certificate() {
  mkdir -p "$(dirname "$PUBLIC_CERT")"
  local temporary_public
  temporary_public="$(mktemp "$(dirname "$PUBLIC_CERT")/.certificate.XXXXXX")"
  temporary_files+=("$temporary_public")
  cp "$LIVE_DIR/fullchain.pem" "$temporary_public"
  mv "$temporary_public" "$PUBLIC_CERT"
  log "Public certificate chain updated: $PUBLIC_CERT"
}

write_status() {
  local renewal_iso="${1:-}"
  "$SCRIPT_DIR/generate-status.sh" "$PUBLIC_CERT" "$STATUS_JSON" "$DOMAIN" "$renewal_iso"
}

main() {
  log "ValoUtils certificate manager for $DOMAIN"
  log "Project root: $BASE_DIR"

  local inspection="" action="" have_valid_live=false failed=false
  local renewal_iso=""

  if [[ -s "$LIVE_DIR/fullchain.pem" ]] && inspection="$(validate_live_directory)"; then
    have_valid_live=true
  fi

  if [[ "$have_valid_live" == true ]]; then
    # The live certificate parses and is currently valid; renewal is still
    # due when it is inside the threshold window (or a renewal was forced).
    if [[ "$force_renew" == true ]] \
      || [[ "$(json_field "$inspection" renewal_required)" == "true" ]]; then
      action="issue"
    else
      action="keep"
    fi
  elif [[ -s "$LIVE_DIR/fullchain.pem" ]]; then
    # Certbot state exists but is unusable; reissuing heals it.
    log "Existing Certbot state is unusable; a fresh certificate will be issued."
    inspection=""
    action="issue"
  elif [[ -s "$PUBLIC_CERT" ]]; then
    # No local Certbot state (for example a fresh CI runner): the committed
    # public certificate is the persistent state and decides the action.
    inspection="$("$SCRIPT_DIR/check-cert.sh" "$PUBLIC_CERT" "$DOMAIN")"
    if [[ "$(json_field "$inspection" renewal_required)" == "true" ]]; then
      action="issue"
    else
      action="keep"
    fi
  else
    action="issue"
  fi

  if [[ "$force_renew" == true ]]; then
    action="issue"
  fi

  case "$action" in
    keep)
      log "Certificate is fine; renewal is not due (threshold: $RENEWAL_THRESHOLD_DAYS days)."
      ;;
    issue)
      if [[ -s "$LIVE_DIR/fullchain.pem" ]] || [[ -s "$PUBLIC_CERT" ]]; then
        log "Renewing the certificate via Let's Encrypt (Cloudflare DNS-01)."
      else
        log "No existing certificate found; issuing a new one via Let's Encrypt (Cloudflare DNS-01)."
      fi
      if issue_certificate; then
        if inspection="$(validate_live_directory)"; then
          have_valid_live=true
        else
          log "ERROR: the newly issued certificate failed validation; keeping previous public files."
          failed=true
        fi
      else
        log "ERROR: Let's Encrypt issuance failed; keeping previous public files."
        failed=true
      fi
      ;;
  esac

  if [[ "$have_valid_live" == true && "$failed" == false ]]; then
    if ! generate_pfx; then
      log "ERROR: PFX generation failed."
      failed=true
    fi
    update_public_certificate
    if [[ "$action" == "issue" && "$failed" == false ]]; then
      renewal_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi
  else
    log "No usable private key in this environment; skipping PFX generation."
  fi

  if ! write_status "$renewal_iso"; then
    log "ERROR: status generation failed."
    failed=true
  fi

  if [[ -s "$STATUS_JSON" ]]; then
    local status_json
    status_json="$(<"$STATUS_JSON")"
    log "Certificate status: $(json_field "$status_json" status) ($(json_field "$status_json" days_remaining) days remaining)"
  fi

  if [[ "$failed" == true ]]; then
    log "Finished with errors."
    exit 1
  fi
  log "Done. Public files: $PUBLIC_CERT, $STATUS_JSON"
}

main "$@"
