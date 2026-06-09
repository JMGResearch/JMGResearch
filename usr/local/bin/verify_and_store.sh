#!/usr/bin/env bash
set -euo pipefail
# /usr/local/bin/verify_and_store.sh
# Monitors INCOMING_DIR and accepts only artifacts that are on removable USB and signed by allowed fingerprints.

INCOMING_DIR="${INCOMING_DIR:-/mnt/wdwork/incoming}"
FINAL_DIR="${FINAL_DIR:-/opt/storage/archives}"
QUARANTINE_DIR="${QUARANTINE_DIR:-/opt/storage/quarantine}"
STORAGE_CERT="${STORAGE_CERT:-/opt/reset-rollout/certs/storage-cert.pem}"
STORAGE_KEY="${STORAGE_KEY:-/opt/reset-rollout/certs/storage-key.pem}"
CA_PEM="${CA_PEM:-/opt/reset-rollout/certs/ca.pem}"
TMPDIR="${TMPDIR:-/tmp}"
# Allowlist file (one fingerprint per line, uppercase, no colons)
ALLOWED_FILE="${ALLOWED_FILE:-/etc/reset-rollout/allowed_signers.txt}"

mkdir -p "$FINAL_DIR" "$QUARANTINE_DIR" "$INCOMING_DIR"
chmod 700 "$FINAL_DIR" "$QUARANTINE_DIR"

read_allowed_fps() {
  if [[ -f "$ALLOWED_FILE" ]]; then
    awk '{gsub(/[[:space:]]/,"","); print toupper($0)}' "$ALLOWED_FILE" | sed '/^$/d' | tr '\n' ' '
  else
    echo ""
  fi
}

ALLOWED_SIGNER_FPS_RAW="$(read_allowed_fps)"
IFS=' ' read -r -a ALLOWED_FPS_ARR <<< "$ALLOWED_SIGNER_FPS_RAW"

# Check INCOMING_DIR is on removable block device
incoming_on_removable_device() {
  local mount_src
  mount_src="$(findmnt -n -o SOURCE --target "$INCOMING_DIR" 2>/dev/null || true)"
  [[ -z "$mount_src" || "${mount_src:0:5}" != "/dev/" ]] && return 1

  local base
  base="$(basename "$mount_src")"
  # parent dev handling for nvme/patterns and sdxN
  local parent
  parent="$(echo "$base" | sed -E 's/(nvme[0-9]n[0-9]+)p?.*/\1/; t; s/([a-z]+)[0-9].*/\1/')"
  if [[ -z "$parent" ]]; then
    return 1
  fi
  if [[ ! -r "/sys/block/$parent/removable" ]]; then
    return 1
  fi
  local removable
  removable="$(cat /sys/block/$parent/removable 2>/dev/null || echo 0)"
  [[ "$removable" == "1" ]] && return 0 || return 1
}

meta_signer_allowed() {
  local meta="$1"
  [[ -f "$meta" ]] || return 1
  local meta_fp
  meta_fp="$(awk -F: '/^signer_fp:/ {gsub(/[[:space:]]*/,"",$2); print toupper($2); exit}' "$meta" || true)"
  [[ -z "$meta_fp" ]] && return 1
  for allowed in "${ALLOWED_FPS_ARR[@]}"; do
    allowed="$(echo "$allowed" | tr '[:lower:]' '[:upper:]')"
    [[ "$meta_fp" == "$allowed" ]] && return 0
  done
  return 1
}

process_file() {
  local enc="$1"
  local meta="${enc}.meta"
  local basename_enc
  basename_enc="$(basename "$enc")"

  if ! incoming_on_removable_device; then
    echo "$(date -u) REJECT: $basename_enc — incoming not on removable device" >> "$QUARANTINE_DIR/verify.log"
    mv "$enc" "$QUARANTINE_DIR/" 2>/dev/null || rm -f "$enc"
    [[ -f "$meta" ]] && { mv "$meta" "$QUARANTINE_DIR/" 2>/dev/null || rm -f "$meta"; }
    return
  fi

  if ! meta_signer_allowed "$meta"; then
    echo "$(date -u) REJECT: $basename_enc — signer not allowed or missing meta" >> "$QUARANTINE_DIR/verify.log"
    mv "$enc" "$QUARANTINE_DIR/" 2>/dev/null || rm -f "$enc"
    [[ -f "$meta" ]] && { mv "$meta" "$QUARANTINE_DIR/" 2>/dev/null || rm -f "$meta"; }
    return
  fi

  local tmp_signed tmp_out
  tmp_signed="$(mktemp "${TMPDIR}/signed.XXXXXX")"
  tmp_out="$(mktemp "${TMPDIR}/out.XXXXXX")"

  if ! openssl cms -decrypt -in "$enc" -recip "$STORAGE_CERT" -inkey "$STORAGE_KEY" -out "$tmp_signed" 2>/dev/null; then
    echo "$(date -u) FAIL: decrypt failed for $basename_enc" >> "$QUARANTINE_DIR/verify.log"
    rm -f "$tmp_signed" "$tmp_out"
    mv "$enc" "$QUARANTINE_DIR/" 2>/dev/null || rm -f "$enc"
    [[ -f "$meta" ]] && { mv "$meta" "$QUARANTINE_DIR/" 2>/dev/null || rm -f "$meta"; }
    return
  fi

  if ! openssl cms -verify -in "$tmp_signed" -CAfile "$CA_PEM" -out "$tmp_out" -inform DER >/dev/null 2>&1; then
    echo "$(date -u) FAIL: signature verify failed for $basename_enc" >> "$QUARANTINE_DIR/verify.log"
    rm -f "$tmp_signed" "$tmp_out"
    mv "$enc" "$QUARANTINE_DIR/" 2>/dev/null || rm -f "$enc"
    [[ -f "$meta" ]] && { mv "$meta" "$QUARANTINE_DIR/" 2>/dev/null || rm -f "$meta"; }
    return
  fi

  local dst_rel final_path
  if [[ -f "$meta" ]]; then
    dst_rel="$(awk -F: '/^dst:/ {gsub(/^ +| +$/,"",$2); print $2; exit}' "$meta" || true)"
  fi
  if [[ -n "$dst_rel" ]]; then
    final_path="$FINAL_DIR/$dst_rel"
    mkdir -p "$(dirname "$final_path")"
  else
    final_path="$FINAL_DIR/${basename_enc%.p7m}"
  fi

  mv -f "$tmp_out" "$final_path"
  chmod 600 "$final_path"
  chown --no-dereference storage_agent:storage_agent "$final_path" 2>/dev/null || true
  echo "$(date -u) ACCEPT: $basename_enc -> $final_path" >> "$FINAL_DIR/ingest.log"

  rm -f "$tmp_signed" 2>/dev/null || true
  rm -f "$enc" "$meta" 2>/dev/null || true
}

# Initial scan
for f in "$INCOMING_DIR"/*.p7m; do
  [[ -f "$f" ]] || continue
  process_file "$f"

done

# Monitor
if command -v inotifywait >/dev/null 2>&1; then
  inotifywait -m -e close_write,move --format '%w%f' "$INCOMING_DIR" 2>/dev/null | while read -r file; do
    case "$file" in
      *.p7m) process_file "$file" ;;
    esac
  done
else
  while true; do
    for f in "$INCOMING_DIR"/*.p7m; do
      [[ -f "$f" ]] || continue
      process_file "$f"
    done
    sleep 5
  done
fi
