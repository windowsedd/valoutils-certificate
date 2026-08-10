#!/usr/bin/env bash
set -euo pipefail

bash tests/check-cert.test.sh
bash tests/check-pfx.test.sh
bash tests/generate-status.test.sh
bash tests/renew-cert.test.sh
node --test tests/readme.test.js tests/site.test.js tests/workflow.test.js
