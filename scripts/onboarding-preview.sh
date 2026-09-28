#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILT_APP="${PROJECT_DIR}/DerivedData/Build/Products/Debug/MyFluidVoice Debug.app"
PREVIEW_APP="/Applications/MyFluidVoice Onboarding Preview.app"
PREVIEW_HOME="${HOME}/Library/Application Support/MyFluidVoice Onboarding Preview/Home"
PREVIEW_BUNDLE_ID="com.Liooo.MyFluidVoice.OnboardingPreview"
ACTION="${1:-build}"

stop_preview() {
    osascript -e "tell application id \"${PREVIEW_BUNDLE_ID}\" to quit" 2>/dev/null || true
}

reset_preview() {
    stop_preview
    if [ -d "${PREVIEW_HOME}" ]; then
        rm -rf "${PREVIEW_HOME}"
    fi
    echo "Reset preview data: ${PREVIEW_HOME}"
}

launch_preview() {
    mkdir -p "${PREVIEW_HOME}/Library/Application Support" \
        "${PREVIEW_HOME}/Library/Caches" \
        "${PREVIEW_HOME}/Library/Logs" \
        "${PREVIEW_HOME}/Library/Preferences"
    open -n \
        --env "CFFIXED_USER_HOME=${PREVIEW_HOME}" \
        --env "MYFLUIDVOICE_ONBOARDING_PREVIEW=1" \
        "${PREVIEW_APP}"
}

build_preview() {
    "${PROJECT_DIR}/build.sh"

    local signing_identity
    signing_identity="$(codesign -d --verbose=4 "${BUILT_APP}" 2>&1 \
        | sed -n 's/^Authority=\(Apple Development:.*\)/\1/p' \
        | head -n 1)"
    if [ -z "${signing_identity}" ]; then
        echo "Could not determine signing identity for ${BUILT_APP}." >&2
        exit 1
    fi

    stop_preview
    ditto "${BUILT_APP}" "${PREVIEW_APP}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${PREVIEW_BUNDLE_ID}" "${PREVIEW_APP}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName MyFluidVoice Onboarding Preview" "${PREVIEW_APP}/Contents/Info.plist"
    if ! /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName MyFluidVoice Onboarding Preview" \
        "${PREVIEW_APP}/Contents/Info.plist" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string MyFluidVoice Onboarding Preview" \
            "${PREVIEW_APP}/Contents/Info.plist"
    fi
    codesign --force --deep \
        --sign "${signing_identity}" \
        --preserve-metadata=entitlements,flags \
        --timestamp=none \
        "${PREVIEW_APP}"
    codesign --verify --deep --strict --verbose=2 "${PREVIEW_APP}"
    echo "Built preview app: ${PREVIEW_APP}"
}

case "${ACTION}" in
    build)
        build_preview
        ;;
    launch)
        launch_preview
        ;;
    reset)
        reset_preview
        ;;
    fresh)
        reset_preview
        launch_preview
        ;;
    *)
        echo "Usage: $0 {build|launch|reset|fresh}" >&2
        exit 1
        ;;
esac
