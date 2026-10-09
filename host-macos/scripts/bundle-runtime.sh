#!/bin/bash
# Called only by build-app.sh for an explicitly requested self-contained build.
set -euo pipefail
APP="${1:?app bundle path required}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NODE="${PI_OS_BUNDLED_NODE_PATH:?Set PI_OS_BUNDLED_NODE_PATH to a standalone official Node 22.19+ binary}"
IDENTITY="${PI_OS_SIGN_IDENTITY:?A stable signing identity is required for bundled builds}"
if [[ "$IDENTITY" == "-" || "$NODE" != /* || ! -x "$NODE" ]]; then
  echo "Bundling requires a certificate and an absolute standalone Node executable." >&2; exit 1
fi
# Homebrew Node commonly depends on libraries outside the .app; copying it is not bundling.
if otool -L "$NODE" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' >/dev/null; then
  echo "Node has non-system dynamic dependencies. Use the official standalone Node distribution." >&2; exit 1
fi
VERSION="$("$NODE" --version)"
# pi 1.0 declares engines node >=22.19.0.
IFS=. read -r MAJOR MINOR _ <<< "${VERSION#v}"
if [[ ! "$MAJOR" =~ ^[0-9]+$ || ! "$MINOR" =~ ^[0-9]+$ ]] || (( MAJOR < 22 || (MAJOR == 22 && MINOR < 19) )); then
  echo "Node 22.19+ is required." >&2; exit 1
fi
LICENSE="${PI_OS_NODE_LICENSE_PATH:-$(dirname "$(dirname "$NODE")")/LICENSE}"
if [[ ! -f "$LICENSE" ]]; then echo "Provide the standalone distribution's LICENSE via PI_OS_NODE_LICENSE_PATH." >&2; exit 1; fi
RES="$APP/Contents/Resources"
mkdir -p "$RES/runtime/bin" "$RES/node-harness" "$RES/ThirdParty"
cp "$LICENSE" "$RES/ThirdParty/Node-LICENSE.txt"
cp "$ROOT/LICENSE" "$RES/License.txt"
cp "$NODE" "$RES/runtime/bin/node"
cp "$ROOT/node-harness/package.json" "$ROOT/node-harness/package-lock.json" "$RES/node-harness/"
ditto "$ROOT/node-harness/dist" "$RES/node-harness/dist"
# Locked production dependencies; never copy credentials, settings, captures or the agent cwd.
npm --prefix "$RES/node-harness" ci --omit=dev --ignore-scripts
# pi-coding-agent 1.0 depends on @earendil-works/chord -> esbuild: 26 platform packages (~285 MB)
# including unsigned Mach-O executables. Nothing in the pi SDK runtime or pi-os imports chord or
# esbuild (only chord's own bundler entry does), so they are not shipped.
rm -rf "$RES/node-harness/node_modules/@earendil-works/pi-coding-agent/node_modules/@esbuild" \
       "$RES/node-harness/node_modules/@earendil-works/pi-coding-agent/node_modules/esbuild"
# Sign every remaining Mach-O (native addons, dylibs and any executable); executables get the
# hardened runtime that notarization requires.
while IFS= read -r -d '' binary; do
  case "$(file -b "$binary")" in
    *Mach-O*executable*) codesign --force --options runtime --sign "$IDENTITY" "$binary" ;;
    *Mach-O*) codesign --force --sign "$IDENTITY" "$binary" ;;
  esac
done < <(find "$RES/node-harness/node_modules" -type f \( -name '*.node' -o -name '*.dylib' -o -perm -u+x \) -print0)
codesign --force --options runtime --entitlements "$ROOT/host-macos/Resources/Node.entitlements" --sign "$IDENTITY" "$RES/runtime/bin/node"
codesign --verify --strict "$RES/runtime/bin/node"
# Exercise the signed runtime and production dependency graph, without loading a user's
# resources, discovering providers, or contacting any model service.
(
  cd "$RES/node-harness"
  PI_OFFLINE=1 PI_OS_AGENT=0 "$RES/runtime/bin/node" --import "$ROOT/node-harness/test/no-live-models.mjs" --input-type=module -e \
    'import { createAgentSession } from "@earendil-works/pi-coding-agent"; if (typeof createAgentSession !== "function") process.exit(1); console.log("Signed bundled SDK import: OK (no model call)");'
)
echo "Bundled $VERSION with a locked harness snapshot. Notarization is a separate release gate."
