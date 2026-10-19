#!/bin/sh
# Safer entrypoint: support reading WALLET from file (WALLET_FILE) or env, mask wallet in logs, exec miner
# Supports reading wallet from raw link (WALLET_URL / RAW_WALLET_URL) for SageMaker or other environments
# where AWS Secrets Manager is not available or not readable as wallet text.
set -eu

POOL_URL_DEFAULT="stratum+ssl://prl-sg.kryptex.network:8048"

# If WALLET not set, try reading from WALLET_FILE (e.g. mount /run/secrets/wallet)
if [ -z "${WALLET:-}" ] && [ -n "${WALLET_FILE:-}" ] && [ -f "${WALLET_FILE}" ]; then
  IFS= read -r WALLET < "${WALLET_FILE}"
  WALLET=$(printf "%s" "$WALLET" | tr -d '\r\n')
fi

# If WALLET is still empty, fetch a wallet from a raw text URL and treat it as a file.
# Example:
#   WALLET_URL=https://raw.githubusercontent.com/owner/repo/main/wallet.txt
#   RAW_WALLET_URL=https://raw.githubusercontent.com/owner/repo/main/wallet.txt
if [ -z "${WALLET:-}" ] && [ -z "${WALLET_FILE:-}" ]; then
  RAW_URL="${WALLET_URL:-${RAW_WALLET_URL:-}}"
  if [ -n "$RAW_URL" ]; then
    TMP_WALLET_PATH="/tmp/raw_wallet.txt"
    if command -v curl >/dev/null 2>&1; then
      if curl -fsSL --retry 3 "$RAW_URL" -o "$TMP_WALLET_PATH" 2>/dev/null; then
        if [ -s "$TMP_WALLET_PATH" ]; then
          WALLET_FILE="$TMP_WALLET_PATH"
          IFS= read -r WALLET < "$WALLET_FILE"
          WALLET=$(printf "%s" "$WALLET" | tr -d '\r\n')
        fi
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -qO "$TMP_WALLET_PATH" "$RAW_URL" 2>/dev/null; then
        if [ -s "$TMP_WALLET_PATH" ]; then
          WALLET_FILE="$TMP_WALLET_PATH"
          IFS= read -r WALLET < "$WALLET_FILE"
          WALLET=$(printf "%s" "$WALLET" | tr -d '\r\n')
        fi
      fi
    else
      echo "WARN: neither curl nor wget is available to fetch wallet from raw URL" >&2
    fi
  fi
fi

# If still not set, try AWS Secrets Manager (if aws CLI is available)
# Environment variables supported:
#  AWS_SECRET_NAME (default: palimpangin/wallet)
#  AWS_REGION (default: us-east-2)
if [ -z "${WALLET:-}" ]; then
  if command -v aws >/dev/null 2>&1; then
    AWS_SECRET_NAME="${AWS_SECRET_NAME:-palimpangin/wallet}"
    AWS_REGION="${AWS_REGION:-us-east-2}"
    if [ -n "$AWS_SECRET_NAME" ]; then
      # Attempt to fetch secret value. This requires the container to have AWS credentials/role with
      # permissions: secretsmanager:GetSecretValue on the specified secret.
      if secret=$(aws secretsmanager get-secret-value --secret-id "$AWS_SECRET_NAME" --query SecretString --output text --region "$AWS_REGION" 2>/dev/null); then
        WALLET="$secret"
        # trim newlines/carriage returns
        WALLET=$(printf "%s" "$WALLET" | tr -d '\r\n')
      else
        echo "WARN: failed to fetch secret $AWS_SECRET_NAME from AWS Secrets Manager" >&2
      fi
    fi
  fi
fi

if [ -z "${WALLET:-}" ]; then
  echo "ERROR: WALLET environment variable or WALLET_FILE is required." >&2
  echo "Provide WALLET via -e WALLET=<your_wallet> or mount a secrets file and set WALLET_FILE=/run/secrets/wallet (preferred)." >&2
  echo "Or provide a raw file using WALLET_URL=https://.../wallet.txt or RAW_WALLET_URL=https://.../wallet.txt" >&2
  echo "Or set AWS credentials/role and set AWS_SECRET_NAME to the secret in AWS Secrets Manager." >&2
  exit 1
fi

POOL_URL="${POOL_URL:-$POOL_URL_DEFAULT}"

# find binary without using ls (handles no match safely)
KRIG_BIN=""
for f in /opt/krig/krig-miner*; do
  [ -e "$f" ] || continue
  if [ -x "$f" ]; then
    KRIG_BIN="$f"
    break
  fi
done

if [ -z "$KRIG_BIN" ]; then
  echo "ERROR: krig-miner binary not found or not executable in /opt/krig" >&2
  exit 2
fi

# mask wallet for logs (show prefix/suffix only)
mask_wallet() {
  w="$1"
  len=$(printf "%s" "$w" | wc -c)
  if [ "$len" -le 12 ]; then
    printf "******"
  else
    prefix=$(printf "%s" "$w" | cut -c1-6)
    suffix=$(printf "%s" "$w" | rev | cut -c1-4 | rev)
    printf "%s...%s" "$prefix" "$suffix"
  fi
}

MASKED_WALLET=$(mask_wallet "$WALLET")

echo "Starting krig-miner with:"
echo "  WALLET=${MASKED_WALLET}"
echo "  POOL_URL=${POOL_URL}"
echo "  Binary=${KRIG_BIN}"

# Exec miner directly so signals are handled correctly
exec "${KRIG_BIN}" --url "${POOL_URL}" --user "${WALLET}" "$@"
