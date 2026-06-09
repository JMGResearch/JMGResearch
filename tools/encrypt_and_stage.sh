#!/usr/bin/env bash
set -euo pipefail
# tools/encrypt_and_stage.sh
# Sign then encrypt a staged file for the storage device. Produces <staged>.p7m and .meta

FOR_CERT="${FOR_CERT:-/opt/reset-rollout/certs/forensic-cert.pem}"
FOR_KEY="${FOR_KEY:-/opt/reset-rollout/certs/forensic-key.pem}"
STORE_CERT="${STORE_CERT:-/opt/reset-rollout/certs/storage-cert.pem}"
CA_PEM="${CA_PEM:-/opt/reset-rollout/certs/ca.pem}"
TMPDIR="${TMPDIR:-/tmp}"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <staged-file> <dst-relative-path-on-storage>" >&2
  exit 2
fi

staged="$1"
dst_rel="$2"

if [[ ! -f "$staged" ]]; then echo "ERR: staged file not found: $staged" >&2; exit 3; fi
for f in "$FOR_CERT" "$FOR_KEY" "$STORE_CERT" "$CA_PEM"; do
  [[ -f "$f" ]] || { echo "ERR: Missing $f" >&2; exit 4; }
 done

out_encrypted="${staged}.p7m"
meta="${out_encrypted}.meta"
tmp_signed="$(mktemp "${TMPDIR}/signed.XXXXXX")"

# signer fingerprint (SHA256, no colons)
signer_fp="$(openssl x509 -noout -fingerprint -sha256 -in "$FOR_CERT" | cut -d'=' -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]')"

# Sign (DER)
openssl cms -sign -in "$staged" -signer "$FOR_CERT" -inkey "$FOR_KEY" -certfile "$CA_PEM" -outform DER -nodetach -out "$tmp_signed"
# Encrypt signed blob for storage cert (AES-256)
openssl cms -encrypt -in "$tmp_signed" -out "$out_encrypted" -recip "$STORE_CERT" -aes256

# cleanup
shred -u "$tmp_signed" 2>/dev/null || rm -f "$tmp_signed"

# Write metadata
{
  echo "dst:$dst_rel"
  echo "signer_fp:$signer_fp"
  echo "signed_by:$(basename "$FOR_CERT")"
  echo "time:$(date -u --rfc-3339=seconds)"
  sha256sum "$out_encrypted" | awk '{print "sha256:"$1}'
} > "$meta"

echo "$out_encrypted"
exit 0
