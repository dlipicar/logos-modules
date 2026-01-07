#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

if [[ ! -f .gitmodules ]]; then
  echo "No .gitmodules found in $script_dir" >&2
  exit 1
fi

modules=$(git config --file .gitmodules --get-regexp path | awk '{print $2}')

if [[ -z "$modules" ]]; then
  echo "No module paths found in .gitmodules" >&2
  exit 1
fi

for module in $modules; do
  echo "Building $module..."
  if (cd "$module" && nix build --extra-experimental-features 'nix-command flakes' '.#lib'); then
    echo "Built $module"
  else
    echo "Failed building $module (nix build '.#lib')" >&2
    exit 1
  fi
done

echo "All modules built successfully."
