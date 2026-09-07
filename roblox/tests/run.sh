#!/usr/bin/env bash
# Runs IpadMouseLock against a stubbed Roblox runtime.
#
#   curl -sSL -o luau.zip \
#     https://github.com/luau-lang/luau/releases/latest/download/luau-ubuntu.zip
#   unzip -q luau.zip -d luau-bin
#   LUAU=./luau-bin/luau roblox/tests/run.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
luau="${LUAU:-luau}"
combined="$(mktemp -t ipadmouselock-XXXXXX.lua)"
trap 'rm -f "$combined"' EXIT

# The luau CLI sandbox has no io/require, so everything runs as one chunk.
# The script under test is wrapped in do...end to keep its locals to itself.
{
	cat "$here/mock.lua"
	cat "$here/setup.lua"
	echo "do"
	cat "$here/../IpadMouseLock.client.lua"
	echo "end"
	cat "$here/tests.lua"
} > "$combined"

"$luau" "$combined"
