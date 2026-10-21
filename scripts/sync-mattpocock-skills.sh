#!/usr/bin/env bash
# Copies the stable skills (the ones shipped in the Claude Code plugin) from
# https://github.com/mattpocock/skills into .claude/skills/, flattened by name.
# Usage: scripts/sync-mattpocock-skills.sh [git-ref]
set -euo pipefail

ref="${1:-main}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$repo_root/.claude/skills"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git clone --quiet https://github.com/mattpocock/skills.git "$tmp/skills"
git -C "$tmp/skills" checkout --quiet "$ref"
commit="$(git -C "$tmp/skills" rev-parse HEAD)"

mkdir -p "$dest"
python3 -I -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["skills"]))' \
  "$tmp/skills/.claude-plugin/plugin.json" | while read -r path; do
  name="$(basename "$path")"
  rm -rf "$dest/$name"
  cp -R "$tmp/skills/$path" "$dest/$name"
  echo "$name"
done

cp "$tmp/skills/LICENSE" "$dest/LICENSE.mattpocock"
echo "$commit" > "$dest/.mattpocock-skills-commit"
echo "Synced mattpocock/skills@$commit"
