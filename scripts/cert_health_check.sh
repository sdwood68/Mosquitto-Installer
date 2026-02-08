#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  echo "Usage: $0 <domain>"
  exit 1
fi

LIVE="/etc/letsencrypt/live/$DOMAIN"
FULLCHAIN="$LIVE/fullchain.pem"

if [[ ! -f "$FULLCHAIN" ]]; then
  echo "Missing: $FULLCHAIN"
  exit 2
fi

echo "Certificate: $FULLCHAIN"
openssl x509 -in "$FULLCHAIN" -noout -subject -issuer -dates
echo
echo "Days remaining:"
enddate="$(openssl x509 -in "$FULLCHAIN" -noout -enddate | cut -d= -f2)"
python3 - <<PY
import datetime
from email.utils import parsedate_to_datetime
end = parsedate_to_datetime("$enddate")
now = datetime.datetime.now(datetime.timezone.utc)
print((end - now).days)
PY
