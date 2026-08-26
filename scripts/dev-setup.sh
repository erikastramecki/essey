#!/usr/bin/env bash
# Run once after clone. Without this the secret-blocking pre-commit hook never runs —
# a fresh clone (CI, new machine) has no gate at all (sweep finding F2, 2026-08-26).
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
echo "hooks wired: $(git config core.hooksPath)"
