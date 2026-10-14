#!/usr/bin/env bash
# Thin wrapper: docker compose with the production files and .env.
#   scripts/compose.sh ps
#   scripts/compose.sh logs -f --tail=100 builder worker
#   scripts/compose.sh exec postgres psql -U hitechcloudomnichannel
set -euo pipefail

# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

require_env_file
compose "$@"
