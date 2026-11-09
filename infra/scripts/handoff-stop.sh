#!/bin/bash
# Stops the private handoff server and deletes the staged copies (the staged package contains the Windows SP private key and transport certificate).
# The originals under /srv/idpdemo and /var/tmp/idpdemo-upload are kept so the Windows stage can be retried.
set -euo pipefail
systemctl stop idpdemo-handoff 2>/dev/null || true
systemctl reset-failed idpdemo-handoff 2>/dev/null || true
rm -rf /srv/idpdemo/handoff
if systemctl is-active --quiet idpdemo-handoff; then echo 'DEMO_STAGE_FAILED: handoff server still running' >&2; exit 1; fi
echo 'DEMO_STAGE_OK: handoff server stopped and staged package deleted.'
