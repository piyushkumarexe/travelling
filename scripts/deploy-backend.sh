#!/usr/bin/env bash
#
# Tourism — Cloud Functions backend deploy (one command).
#
# What it does:
#   1. Installs the functions dependencies (npm install)
#   2. Logs you in to Firebase (opens your browser)
#   3. Selects the "tourism-39425" project
#   4. Prompts for the 3 secret API keys (only if not already set)
#   5. Deploys functions + Firestore rules + Storage rules
#
# You need ONE Google account that owns (or can edit) the Firebase project
# "tourism-39425", and the project must be on the Blaze (pay-as-you-go) plan.
# See BACKEND_SETUP.md for the full step-by-step.
#
# Usage:
#   bash scripts/deploy-backend.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="tourism-39425"
SECRETS=(
  "GOOGLE_MAPS_API_KEY"
  "OPENWEATHER_API_KEY"
  "NVIDIA_API_KEY"
)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

say()  { printf "${GREEN}==>${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}!!${NC} %s\n" "$1"; }
info() { printf "${CYAN}   %s\n${NC}" "$1"; }

command -v node >/dev/null 2>&1 || { echo "ERROR: Node.js not found. Install it from https://nodejs.org"; exit 1; }
command -v npm  >/dev/null 2>&1 || { echo "ERROR: npm not found. Install it from https://nodejs.org"; exit 1; }

# firebase-tools runs via npx so you don't have to install anything globally.
FB="npx --yes firebase-tools"

say "Step 1/5 — Installing backend dependencies"
(cd functions && npm install --no-audit --no-fund)

say "Step 2/5 — Firebase login"
if ! $FB login:list 2>/dev/null | grep -q "@"; then
  info "A browser window will open. Log in with the Google account that owns 'tourism-39425'."
  $FB login
else
  info "Already logged in ✓"
fi

say "Step 3/5 — Selecting project $PROJECT"
$FB use "$PROJECT" --non-interactive >/dev/null 2>&1 || $FB use "$PROJECT"

say "Step 4/5 — API keys (set once, stored securely in Google Secret Manager)"
for secret in "${SECRETS[@]}"; do
  if $FB functions:secrets:access "$secret" --project "$PROJECT" >/dev/null 2>&1; then
    info "  $secret : already set ✓"
  else
    info "  $secret : not set — paste it when prompted."
    $FB functions:secrets:set "$secret" --project "$PROJECT"
  fi
done

say "Step 5/5 — Deploying functions + Firestore rules + Storage rules"
$FB deploy --project "$PROJECT"

say "Done! The backend is live."
info "Base URL: https://us-central1-$PROJECT.cloudfunctions.net"
info "The app now uses Google Places, Directions, Geocoding, OpenWeather and NVIDIA AI automatically."
warn "IMPORTANT: also make sure the Firestore DATABASE exists (see BACKEND_SETUP.md step 2),"
warn "otherwise the rate limiter and the app's data features will error."
