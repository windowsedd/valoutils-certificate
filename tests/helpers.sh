#!/usr/bin/env bash
set -euo pipefail

case "$(uname -s)" in
  MINGW*|MSYS*) export MSYS2_ARG_CONV_EXCL='/CN' ;;
esac

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="${3:-value}"

  if [[ "$expected" != "$actual" ]]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

assert_file_exists() {
  local path="$1"
  [[ -f "$path" ]] || fail "expected file to exist: $path"
}

json_get() {
  local json="$1"
  local key="$2"
  python -c 'import json,sys; value=json.loads(sys.argv[1])[sys.argv[2]]; print(str(value).lower() if isinstance(value, bool) else value)' "$json" "$key"
}

make_chain() {
  local output_dir="$1"
  local domain="$2"
  local days="$3"

  mkdir -p "$output_dir"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/O=Let's Encrypt/CN=ValoUtils Test CA" \
    -keyout "$output_dir/ca.key" \
    -out "$output_dir/ca.pem" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$domain" \
    -addext "subjectAltName=DNS:$domain" \
    -addext "extendedKeyUsage=serverAuth" \
    -keyout "$output_dir/privkey.pem" \
    -out "$output_dir/leaf.csr" >/dev/null 2>&1
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$domain" \
    > "$output_dir/extensions.cnf"
  openssl x509 -req -in "$output_dir/leaf.csr" \
    -CA "$output_dir/ca.pem" \
    -CAkey "$output_dir/ca.key" \
    -CAcreateserial \
    -days "$days" \
    -extfile "$output_dir/extensions.cnf" \
    -out "$output_dir/cert.pem" >/dev/null 2>&1
  cat "$output_dir/cert.pem" "$output_dir/ca.pem" > "$output_dir/fullchain.pem"
}
