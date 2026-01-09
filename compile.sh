#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

base_libraries_dir="$script_dir/libraries"
list_json_path="$base_libraries_dir/list.json"
case "$(uname -s)" in
  Darwin) platform_dir="mac" ;;
  Linux) platform_dir="linux" ;;
  *)
    echo "Unsupported platform: $(uname -s)" >&2
    exit 1
    ;;
esac
libraries_dir="$base_libraries_dir/$platform_dir"

if [[ ! -f .gitmodules ]]; then
  echo "No .gitmodules found in $script_dir" >&2
  exit 1
fi

modules=$(git config --file .gitmodules --get-regexp path | awk '{print $2}')

if [[ -z "$modules" ]]; then
  echo "No module paths found in .gitmodules" >&2
  exit 1
fi

mkdir -p "$base_libraries_dir"
rm -rf "$libraries_dir"
mkdir -p "$libraries_dir"

module_entries=()

for module in $modules; do
  echo "Building $module..."
  if (cd "$module" && nix build --extra-experimental-features 'nix-command flakes' '.#lib'); then
    echo "Built $module"
    module_lib_dir="$script_dir/$module/result/lib"
    if [[ ! -d "$module_lib_dir" ]]; then
      echo "Expected library output directory not found for $module at $module_lib_dir" >&2
      exit 1
    fi

    module_files_json=$(python3 - "$module_lib_dir" <<'PY'
import json
import os
import sys

lib_dir = sys.argv[1]
entries = sorted(os.listdir(lib_dir))
print(json.dumps(entries))
PY
)
    module_files_json=${module_files_json//$'\n'/}
    
    # Extract metadata from metadata.json
    module_metadata_path="$script_dir/$module/metadata.json"
    module_metadata_json=$(python3 - "$module_metadata_path" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r") as f:
        metadata = json.load(f)
        result = {
            "type": metadata.get("type", ""),
            "name": metadata.get("name", ""),
            "description": metadata.get("description", ""),
            "dependencies": metadata.get("dependencies", []),
            "category": metadata.get("category", ""),
            "author": metadata.get("author", "")
        }
        print(json.dumps(result))
except (FileNotFoundError, json.JSONDecodeError, KeyError):
    print(json.dumps({
        "type": "",
        "name": "",
        "description": "",
        "dependencies": [],
        "category": "",
        "author": ""
    }))
PY
)
    module_metadata_json=${module_metadata_json//$'\n'/}
    module_entries+=("$module::$module_metadata_json::$module_files_json")

    # -RLf dereferences nix store symlinks and avoids preserving ownership to prevent permission issues when overwriting
    cp -RLf "$module_lib_dir"/. "$libraries_dir"/
    echo "Copied libraries for $module to $libraries_dir"
  else
    echo "Failed building $module (nix build '.#lib')" >&2
    exit 1
  fi
done

python3 - "$platform_dir" "$list_json_path" "${module_entries[@]}" <<'PY'
import json
import os
import sys

platform = sys.argv[1]
list_path = sys.argv[2]
entries = sys.argv[3:]

def load_existing(path):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except FileNotFoundError:
        return []
    except Exception:
        return []

data = load_existing(list_path)
index = {}
for item in data:
    if isinstance(item, dict) and "name" in item:
        index[item["name"]] = item

for raw in entries:
    if "::" not in raw:
        continue
    parts = raw.split("::", 2)
    if len(parts) == 2:
        # Old format without metadata (backward compatibility)
        name, files_json = parts
        metadata = {}
    elif len(parts) == 3:
        # New format with metadata
        name, metadata_json, files_json = parts
        try:
            metadata = json.loads(metadata_json)
        except json.JSONDecodeError:
            metadata = {}
    else:
        continue
    try:
        files = json.loads(files_json)
    except json.JSONDecodeError:
        continue
    item = index.get(name, {"name": name, "files": {}})
    files_map = item.get("files") or {}
    if not isinstance(files_map, dict):
        files_map = {}
    else:
        files_map = dict(files_map)  # copy so we don't mutate loaded data directly
    files_map[platform] = files
    item["files"] = files_map
    # Update metadata fields from metadata.json
    if "type" in metadata:
        item["type"] = metadata["type"]
    if "name" in metadata:
        item["moduleName"] = metadata["name"]
    if "description" in metadata:
        item["description"] = metadata["description"]
    if "dependencies" in metadata:
        item["dependencies"] = metadata["dependencies"]
    if "category" in metadata:
        item["category"] = metadata["category"]
    if "author" in metadata:
        item["author"] = metadata["author"]
    index[name] = item

result = [index[k] for k in sorted(index)]
os.makedirs(os.path.dirname(list_path), exist_ok=True)
with open(list_path, "w") as f:
    json.dump(result, f, indent=2)
PY

echo "All modules built successfully."
echo "Libraries aggregated under $libraries_dir."
echo "Package list written to $list_json_path."
