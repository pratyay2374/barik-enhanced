#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Build & deploy BarikEnhanced to /Applications
#
# Usage:
#   ./scripts/deploy.sh              # Release build (default)
#   ./scripts/deploy.sh --debug      # Debug build
#   ./scripts/deploy.sh --no-launch  # Don't relaunch after install
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_FILE="$PROJECT_ROOT/BarikEnhanced.xcodeproj"
SCHEME="BarikEnhanced"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData"
APP_NAME="BarikEnhanced.app"
INSTALL_DIR="/Applications"
BUILT_APP="$DERIVED_DATA/Build/Products"

# ── Defaults ──────────────────────────────────────────────────────────────────
CONFIGURATION="Release"
LAUNCH_AFTER=true

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

step()    { echo -e "\n${CYAN}${BOLD}▶ $*${RESET}"; }
ok()      { echo -e "  ${GREEN}✔ $*${RESET}"; }
warn()    { echo -e "  ${YELLOW}⚠ $*${RESET}"; }
fail()    { echo -e "\n${RED}${BOLD}✖ FAILED: $*${RESET}\n"; exit 1; }
divider() { echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ── Argument parsing ──────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --debug)     CONFIGURATION="Debug" ;;
    --no-launch) LAUNCH_AFTER=false ;;
    --help|-h)
      echo "Usage: $0 [] [--debug] [--no-launch]"
      echo "  [default]    Build in Release configuration"
      echo "  --debug      Build in Debug configuration"
      echo "  --no-launch  Do not relaunch the app after install"
      exit 0
      ;;
    *) warn "Unknown argument: $arg (ignored)" ;;
  esac
done

BUILT_APP_PATH="$BUILT_APP/$CONFIGURATION/$APP_NAME"

# ── Banner ────────────────────────────────────────────────────────────────────
divider
echo -e "${BOLD}  BarikEnhanced — Build & Deploy${RESET}"
echo -e "  Configuration : ${CYAN}$CONFIGURATION${RESET}"
echo -e "  Install path  : ${CYAN}$INSTALL_DIR/$APP_NAME${RESET}"
echo -e "  Relaunch      : ${CYAN}$LAUNCH_AFTER${RESET}"
divider

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Build
# ─────────────────────────────────────────────────────────────────────────────
step "Step 1/3 — Building ($CONFIGURATION)"

BUILD_LOG="$PROJECT_ROOT/build/deploy_build.log"
mkdir -p "$PROJECT_ROOT/build"

xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  2>&1 | tee "$BUILD_LOG" | grep -E \
    "^(error:|warning:|note:|.*BUILD (SUCCEEDED|FAILED)|.*\.swift:)" \
  || true   # grep exits 1 when no match — don't abort the pipe

# Check the actual xcodebuild exit code from the log (tee keeps original exit)
if grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
  ok "Build succeeded → $BUILT_APP_PATH"
elif grep -q "BUILD FAILED" "$BUILD_LOG"; then
  echo -e "\n${RED}── Build errors ──────────────────────────────────────────────${RESET}"
  grep "^error:" "$BUILD_LOG" | head -20 || true
  echo -e "${RED}Full log: $BUILD_LOG${RESET}"
  fail "Build failed. Fix the errors above and try again."
else
  fail "Unexpected xcodebuild output. See $BUILD_LOG for details."
fi

# Safety check — make sure the .app actually exists
if [[ ! -d "$BUILT_APP_PATH" ]]; then
  fail "Build reported success but $BUILT_APP_PATH not found."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Kill running instance
# ─────────────────────────────────────────────────────────────────────────────
step "Step 2/3 — Stopping running app"

APP_BINARY="${APP_NAME%.app}"   # "BarikEnhanced"

if pgrep -x "$APP_BINARY" > /dev/null 2>&1; then
  pkill -x "$APP_BINARY" && sleep 1
  if pgrep -x "$APP_BINARY" > /dev/null 2>&1; then
    warn "App did not quit gracefully — force-killing..."
    pkill -9 -x "$APP_BINARY" 2>/dev/null || true
    sleep 1
  fi
  ok "App stopped"
else
  ok "App was not running (nothing to kill)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Install to /Applications
# ─────────────────────────────────────────────────────────────────────────────
step "Step 3/3 — Installing to $INSTALL_DIR"

DEST="$INSTALL_DIR/$APP_NAME"

# Remove old version
if [[ -d "$DEST" ]]; then
  rm -rf "$DEST" || fail "Could not remove old $DEST (permission issue?)"
  ok "Removed old version"
fi

# Copy new build
cp -R "$BUILT_APP_PATH" "$DEST" || fail "Could not copy app to $INSTALL_DIR"
ok "Installed → $DEST"

# ─────────────────────────────────────────────────────────────────────────────
# Relaunch
# ─────────────────────────────────────────────────────────────────────────────
if $LAUNCH_AFTER; then
  echo ""
  step "Launching $APP_NAME"
  open "$DEST" || fail "Could not launch $DEST"
  ok "App launched"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
divider
echo -e "${GREEN}${BOLD}  ✔ Deploy complete!${RESET}"
divider
echo ""
