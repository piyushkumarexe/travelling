#!/usr/bin/env bash
#
# Tourism — deploy ONLY the security rules + indexes (fast, no functions).
#
# This is the fix for:
#   [cloud_firestore/permission-denied] on the Notifications screen
#   (the deployed rules predate users/{uid}/notifications).
#
# What it does:
#   1. Logs you in to Firebase (opens your browser) — once
#   2. Deploys firestore.rules, storage.rules and firestore indexes
#      to the "tourism-39425" project
#
# Usage:
#   bash scripts/deploy-rules.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="tourism-39425"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

say()  { printf "${GREEN}==>${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}!!>${NC} %s\n" "$1"; }

# firebase-tools runs via npx so nothing global needs to be installed.
FB="npx --yes firebase-tools"

say "Firebase login (opens the browser once, then is cached)"
if ! $FB login:list 2>/dev/null | grep -q "@"; then
  $FB login
fi

say "Deploying Firestore rules + indexes and Storage rules to '$PROJECT'"
$FB deploy --only firestore:rules,firestore:indexes,storage --project "$PROJECT"

say "Done. Open the app → Notifications — data loads now (no reinstall needed)."
warn "If it still fails: Firebase console → Firestore → Rules should match firestore.rules in this repo."
