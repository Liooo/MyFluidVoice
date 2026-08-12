#!/bin/bash

# transcribe-cpp-swift 0.1.2 packages its macOS framework with directories
# where the conventional framework symlinks should be. Xcode consequently
# embeds an ambiguous bundle that fails strict code-signature verification.
# Canonicalize only that known layout in an already-built app.

set -euo pipefail

APP_PATH="${1:-}"

if [ -z "${APP_PATH}" ] || [ ! -d "${APP_PATH}" ] || [ -L "${APP_PATH}" ]; then
    echo "Expected a non-symlink .app directory." >&2
    exit 64
fi

case "${APP_PATH}" in
    /*.app) ;;
    *)
        echo "Expected an absolute .app path: ${APP_PATH}" >&2
        exit 64
        ;;
esac

FRAMEWORK_PATH="${APP_PATH}/Contents/Frameworks/CTranscribe.framework"
VERSIONS_PATH="${FRAMEWORK_PATH}/Versions"
VERSION_A_PATH="${VERSIONS_PATH}/A"
CURRENT_PATH="${VERSIONS_PATH}/Current"

for directory_path in \
    "${APP_PATH}/Contents" \
    "${APP_PATH}/Contents/Frameworks" \
    "${FRAMEWORK_PATH}" \
    "${VERSIONS_PATH}"; do
    if [ ! -d "${directory_path}" ] || [ -L "${directory_path}" ]; then
        echo "Refusing to traverse an unexpected directory: ${directory_path}" >&2
        exit 65
    fi
done

if [ ! -d "${FRAMEWORK_PATH}" ] || [ -L "${FRAMEWORK_PATH}" ] || \
    [ ! -d "${VERSION_A_PATH}" ] || [ -L "${VERSION_A_PATH}" ]; then
    echo "CTranscribe.framework does not have the expected versioned layout." >&2
    exit 65
fi

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw \
    "${VERSION_A_PATH}/Resources/Info.plist" 2>/dev/null || true)"
if [ "${BUNDLE_ID}" != "com.transcribe.CTranscribe" ]; then
    echo "Refusing to alter an unexpected framework bundle: ${BUNDLE_ID:-missing identifier}" >&2
    exit 65
fi

link_is_expected() {
    local path="$1"
    local destination="$2"
    [ -L "${path}" ] && [ "$(readlink "${path}")" = "${destination}" ]
}

if link_is_expected "${CURRENT_PATH}" A && \
    link_is_expected "${FRAMEWORK_PATH}/CTranscribe" Versions/Current/CTranscribe && \
    link_is_expected "${FRAMEWORK_PATH}/Resources" Versions/Current/Resources; then
    for optional_name in Headers Modules; do
        optional_path="${FRAMEWORK_PATH}/${optional_name}"
        versioned_path="${VERSION_A_PATH}/${optional_name}"
        if [ -d "${versioned_path}" ] && \
            link_is_expected "${optional_path}" "Versions/Current/${optional_name}"; then
            continue
        fi
        if [ ! -e "${versioned_path}" ] && [ ! -e "${optional_path}" ] && \
            [ ! -L "${optional_path}" ]; then
            continue
        fi
        if [ -e "${versioned_path}" ] || [ -e "${optional_path}" ] || \
            [ -L "${optional_path}" ]; then
            echo "Canonical framework has an unexpected ${optional_name} entry." >&2
            exit 65
        fi
    done
    exit 0
fi

for required_directory in "${CURRENT_PATH}" "${FRAMEWORK_PATH}/Resources"; do
    if [ ! -d "${required_directory}" ] || [ -L "${required_directory}" ]; then
        echo "Refusing to normalize an unexpected path: ${required_directory}" >&2
        exit 65
    fi
done

TOP_LEVEL_BINARY="${FRAMEWORK_PATH}/CTranscribe"
if [ ! -f "${TOP_LEVEL_BINARY}" ] || [ -L "${TOP_LEVEL_BINARY}" ] || \
    [ ! -f "${VERSION_A_PATH}/CTranscribe" ]; then
    echo "CTranscribe.framework executables do not have the expected duplicated layout." >&2
    exit 65
fi

for optional_name in Headers Modules; do
    optional_path="${FRAMEWORK_PATH}/${optional_name}"
    versioned_path="${VERSION_A_PATH}/${optional_name}"
    if [ -d "${optional_path}" ] && [ ! -L "${optional_path}" ] && \
        [ -d "${versioned_path}" ]; then
        continue
    fi
    if [ ! -e "${optional_path}" ] && [ ! -L "${optional_path}" ] && \
        [ ! -e "${versioned_path}" ]; then
        continue
    fi
    if [ -e "${optional_path}" ] || [ -L "${optional_path}" ] || \
        [ -e "${versioned_path}" ]; then
        echo "Refusing to normalize an unexpected ${optional_name} layout." >&2
        exit 65
    fi
done

for removal_target in \
    "${CURRENT_PATH}" \
    "${FRAMEWORK_PATH}/Resources" \
    "${FRAMEWORK_PATH}/Headers" \
    "${FRAMEWORK_PATH}/Modules"; do
    if [ -d "${removal_target}" ] && \
        find "${removal_target}" -type l -print -quit | grep -q .; then
        echo "Refusing to remove a directory containing symlinks: ${removal_target}" >&2
        exit 65
    fi
done

echo "Canonicalizing embedded CTranscribe.framework..."
rm -R -- "${CURRENT_PATH}"
rm -- "${TOP_LEVEL_BINARY}"
rm -R -- "${FRAMEWORK_PATH}/Resources"
ln -s A "${CURRENT_PATH}"
ln -s Versions/Current/CTranscribe "${TOP_LEVEL_BINARY}"
ln -s Versions/Current/Resources "${FRAMEWORK_PATH}/Resources"

for optional_name in Headers Modules; do
    optional_path="${FRAMEWORK_PATH}/${optional_name}"
    versioned_path="${VERSION_A_PATH}/${optional_name}"
    if [ -d "${optional_path}" ] && [ -d "${versioned_path}" ]; then
        rm -R -- "${optional_path}"
        ln -s "Versions/Current/${optional_name}" "${optional_path}"
    fi
done

if ! link_is_expected "${CURRENT_PATH}" A || \
    ! link_is_expected "${TOP_LEVEL_BINARY}" Versions/Current/CTranscribe || \
    ! link_is_expected "${FRAMEWORK_PATH}/Resources" Versions/Current/Resources; then
    echo "CTranscribe.framework normalization did not produce the expected layout." >&2
    exit 65
fi
