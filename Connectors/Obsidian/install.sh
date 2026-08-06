#!/bin/bash

set -euo pipefail

plugin_id="brainsurfacer-live-context"
script_directory=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  echo "Usage: $(basename -- "$0") /path/to/Obsidian/Vault" >&2
}

fail() {
  echo "BrainSurfacer installer: $*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

vault_argument=$1
[[ -d "$vault_argument" ]] || fail "vault directory not found: $vault_argument"
vault_directory=$(CDPATH='' cd -- "$vault_argument" && pwd -P)
obsidian_directory="$vault_directory/.obsidian"
plugins_directory="$obsidian_directory/plugins"
destination="$plugins_directory/$plugin_id"

[[ -d "$obsidian_directory" ]] \
  || fail "not an Obsidian vault (missing $obsidian_directory)"
if [[ -e "$plugins_directory" && ! -d "$plugins_directory" ]]; then
  fail "plugin path exists but is not a directory: $plugins_directory"
fi
if [[ -e "$destination" && ! -d "$destination" ]]; then
  fail "installation path exists but is not a directory: $destination"
fi

command -v npm >/dev/null 2>&1 || fail "npm is required to build the plugin"
[[ -d "$script_directory/node_modules" ]] \
  || fail "build dependencies are missing; run 'npm install' in $script_directory"

echo "Building BrainSurfacer Live Context..."
(cd "$script_directory" && npm run build)
[[ -f "$script_directory/main.js" ]] || fail "build did not produce main.js"

if [[ ! -d "$plugins_directory" ]]; then
  echo "Creating Obsidian plugin directory: $plugins_directory"
  mkdir -p -- "$plugins_directory"
fi
mkdir -p -- "$destination"
install -m 0644 "$script_directory/main.js" "$destination/main.js"
install -m 0644 "$script_directory/manifest.json" "$destination/manifest.json"

echo "Installed BrainSurfacer Live Context in:"
echo "  $destination"
echo "Reload Obsidian, then enable it under Settings > Community plugins."
