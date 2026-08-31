#!/bin/bash
# Daily cron wrapper: backfill github_stars for skills.
# Appends logs to logs/backfill-stars.log under the project root.
#
# Install (runs every day at 03:00):
#   crontab -e
#   0 3 * * * <absolute-repo-path>/pipeline/scripts/cron/daily-backfill-stars.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="$PIPELINE_DIR/logs"
LOG_FILE="$LOG_DIR/backfill-stars.log"

mkdir -p "$LOG_DIR"

# cron has a minimal PATH — expose node/npm installed via Homebrew / /usr/local
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

cd "$PIPELINE_DIR"

{
  echo ""
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="

  # This scheduled route explicitly depends on the local proxy. A skipped run
  # is a failure so cron monitoring can surface stale data.
  if curl -x http://127.0.0.1:7890 -s -o /dev/null -m 3 https://api.github.com/; then
    echo "proxy 7890 reachable → using proxy"
    export https_proxy="http://127.0.0.1:7890"
    export http_proxy="http://127.0.0.1:7890"
  else
    echo "proxy 7890 unreachable → failing run"
    exit 1
  fi

  npm run backfill:stars
} >> "$LOG_FILE" 2>&1
