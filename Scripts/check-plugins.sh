#!/usr/bin/env bash
# Pin the compiler and verify the actual shipped JavaScript, not only TS types.
# Use --write after editing a bundled plugin's TypeScript source.
set -euo pipefail
cd "$(dirname "$0")/.."
mode=${1:---check}
[[ "$mode" == --check || "$mode" == --write ]] || { echo 'Use --check or --write' >&2; exit 2; }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
diff -u Plugins/noteclarity.d.ts BundledPlugins/noteclarity.d.ts
for source in BundledPlugins/*/src/main.ts; do
    plugin_dir=${source%/src/main.ts}
    output="$scratch/${plugin_dir##*/}.js"
    npx -y -p typescript@5.5.4 tsc --target ES2019 --lib es2019,dom --alwaysStrict \
        --outFile "$output" "$source"
    if [[ "$mode" == --write ]]; then
        cp "$output" "$plugin_dir/main.js"
    else
        diff -u "$plugin_dir/main.js" "$output"
    fi
done
