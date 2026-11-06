#!/bin/bash
set -e

APP_NAME="CustomWispr"
APP_BUNDLE="${APP_NAME}.app"
SOURCES_DIR="Sources"
RESOURCES_DIR="Resources"
EXECUTABLE="${APP_NAME}"

echo "==> Cleaning previous build..."
rm -rf "${APP_BUNDLE}"

echo "==> Creating app bundle structure..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "==> Compiling Swift sources (Apple Silicon / arm64)..."
swiftc \
    -o "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE}" \
    -target arm64-apple-macos13.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework Carbon \
    -framework CoreGraphics \
    -framework ServiceManagement \
    -swift-version 5 \
    "${SOURCES_DIR}/Config.swift" \
    "${SOURCES_DIR}/OverlayWindow.swift" \
    "${SOURCES_DIR}/AudioRecorder.swift" \
    "${SOURCES_DIR}/WhisperService.swift" \
    "${SOURCES_DIR}/AICleanupService.swift" \
    "${SOURCES_DIR}/TextInjector.swift" \
    "${SOURCES_DIR}/KeyMonitor.swift" \
    "${SOURCES_DIR}/SettingsManager.swift" \
    "${SOURCES_DIR}/HistoryManager.swift" \
    "${SOURCES_DIR}/HistorySuggester.swift" \
    "${SOURCES_DIR}/SettingsWindow.swift" \
    "${SOURCES_DIR}/FeedbackWindow.swift" \
    "${SOURCES_DIR}/WelcomeWindow.swift" \
    "${SOURCES_DIR}/UpdateChecker.swift" \
    "${SOURCES_DIR}/AppDelegate.swift" \
    "${SOURCES_DIR}/main.swift"

echo "==> Copying resources..."
cp "${RESOURCES_DIR}/Info.plist" "${APP_BUNDLE}/Contents/"
cp "${RESOURCES_DIR}/warmup.wav" "${APP_BUNDLE}/Contents/Resources/"

echo "==> Detecting signing identity..."
SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E "Developer ID Application|CustomWispr Dev" \
    | head -1 | awk -F'"' '{print $2}')

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "==> Code signing as: ${SIGNING_IDENTITY}"
    codesign --force --sign "$SIGNING_IDENTITY" \
        --entitlements "${RESOURCES_DIR}/entitlements.plist" \
        "${APP_BUNDLE}"
else
    echo "==> WARNING: No stable signing identity found — falling back to ad-hoc."
    echo "    TCC permissions will be invalidated on every rebuild."
    echo "    See: ~/.claude/plans/customwispr-stable-signing-tcc-persistence.md"
    codesign --force --sign - \
        --entitlements "${RESOURCES_DIR}/entitlements.plist" \
        "${APP_BUNDLE}"
fi

echo "==> Deploying to /Applications..."
pkill -x "${APP_NAME}" 2>/dev/null; sleep 0.5
rm -rf "/Applications/${APP_BUNDLE}"
cp -R "${APP_BUNDLE}" "/Applications/${APP_BUNDLE}"
echo "==> Launching..."
open "/Applications/${APP_BUNDLE}"

echo ""
echo "=== Build complete (Apple Silicon): ${APP_BUNDLE} ==="
echo ""
echo "To run: open ${APP_BUNDLE}"
echo ""
echo "First-time setup:"
echo "  1. System Settings > Keyboard > Press fn key to > Do Nothing"
echo "  2. Grant Accessibility permission when prompted"
echo "  3. Grant Microphone permission when prompted"
echo "  4. Create API key:"
echo "       echo \"OPENAI_API_KEY=your-key-here\" > ~/.custom-wispr.env"
echo "       chmod 600 ~/.custom-wispr.env"
echo ""
echo "TCC / Accessibility:"
echo "  With the stable 'CustomWispr Dev' cert, Accessibility survives rebuilds."
echo "  Do NOT run 'tccutil reset' — it destroys the TCC entry we want to keep."
echo "  Only if the build fell back to ad-hoc signing (see warning above) will"
echo "  a fresh permission prompt appear after deploying."
