#!/bin/sh
# Safer entrypoint: support reading WALLET from file (WALLET_FILE) or env, mask wallet in logs, exec miner
set -eu

POOL_URL_DEFAULT="stratum+ssl://prl-sg.kryptex.network:8048"

# If WALLET not set, try reading from WALLET_FILE (e.g. mount /run/secrets/wallet)
if [ -z "${WALLET:-}" ] && [ -n "${WALLET_FILE:-}" ] && [ -f "${WALLET_FILE}" ]; then
  IFS= read -r WALLET < "${WALLET_FILE}"
  WALLET=$(printf "%s" "$WALLET" | tr -d '\r\n')
fi

if [ -z "${WALLET:-}" ]; then
  echo "ERROR: WALLET environment variable or WALLET_FILE is required." >&2
  echo "Provide WALLET via -e WALLET=<your_wallet> or mount a secrets file and set WALLET_FILE=/run/secrets/wallet (preferred)." >&2
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
