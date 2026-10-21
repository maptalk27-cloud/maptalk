#!/bin/sh
set -eu

# Deterministic local analysis only: this never uploads or attaches a policy.
# .mjs needs the explicit JavaScript language override in Autopilot 0.3.0.
# Review the generated baseline before use; it includes optional S3/KMS
# permissions for features this deployment does not enable.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
export DISABLE_IAM_POLICY_AUTOPILOT_TELEMETRY=true

exec uvx iam-policy-autopilot@latest generate-policies \
  "$ROOT/src/s3-backup.mjs" \
  --language javascript \
  --region us-east-2 \
  --account 579072312038 \
  --service-hints s3 \
  --pretty \
  --explain '*'
