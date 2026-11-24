#!/bin/bash
# CbarDuo is Apple Silicon only. Sparkle ships as a universal binary package,
# so this build phase removes the x86_64 slices from the embedded framework
# and re-signs its nested code inside-out (the order Sparkle documents).
set -euo pipefail

FRAMEWORK="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/Sparkle.framework"
[ -d "$FRAMEWORK" ] || { echo "Sparkle.framework not embedded; nothing to strip"; exit 0; }

VERSION_DIR="$FRAMEWORK/Versions/B"
stripped=0
while IFS= read -r -d '' file; do
    file -b "$file" | grep -q "Mach-O" || continue
    archs=$(lipo -archs "$file")
    case " $archs " in
        *" x86_64 "*)
            if [ "$archs" = "x86_64" ]; then
                echo "error: $file has no arm64 slice" >&2
                exit 1
            fi
            lipo -remove x86_64 "$file" -output "$file"
            stripped=1
            ;;
    esac
done < <(find "$VERSION_DIR" -type f -print0)

[ "$stripped" = 1 ] || { echo "Sparkle already arm64 only"; exit 0; }

if [ "${CODE_SIGNING_ALLOWED:-YES}" != "YES" ] || [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    echo "warning: code signing disabled; Sparkle left unsigned after stripping x86_64"
    exit 0
fi

sign_args=(--force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime)
if [ "$EXPANDED_CODE_SIGN_IDENTITY" != "-" ]; then
    sign_args+=(--timestamp)
fi

codesign "${sign_args[@]}" "$VERSION_DIR/XPCServices/Installer.xpc"
codesign "${sign_args[@]}" --preserve-metadata=entitlements "$VERSION_DIR/XPCServices/Downloader.xpc"
codesign "${sign_args[@]}" "$VERSION_DIR/Autoupdate"
codesign "${sign_args[@]}" "$VERSION_DIR/Updater.app"
codesign "${sign_args[@]}" "$FRAMEWORK"
echo "Stripped x86_64 from Sparkle.framework and re-signed it"
