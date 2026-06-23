#!/usr/bin/env bash
# sync-skills.sh — Sync skills to AI client directories as symlinks.
#
# Ensures the same skills work across Claude, Cursor, Gemini, and Codex.
# Each client reads skills from its own directory; this script creates
# symlinks from the canonical skills/ location.
#
# Usage:
#   bash scripts/sync-skills.sh
#   make skills-sync
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS_DIR="$ROOT_DIR/skills"
CLIENTS=(.claude .codex .cursor .gemini)

if [ ! -d "$SKILLS_DIR" ]; then
  echo "ERROR: skills/ directory not found at $SKILLS_DIR"
  exit 1
fi

for client in "${CLIENTS[@]}"; do
  target="$ROOT_DIR/$client/skills"
  mkdir -p "$target"

  # Clean old symlinks (preserve non-symlink files like rh-qs-* from factory)
  for link in "$target"/*; do
    [ -L "$link" ] && rm -f "$link"
  done

  # Link each skill directory
  while IFS= read -r -d '' skill_md; do
    skill_dir=$(dirname "$skill_md")
    name=$(basename "$skill_dir")
    ln -sf "$skill_dir" "$target/$name"
    echo "  ✓ $client/skills/$name"
  done < <(find "$SKILLS_DIR" -name SKILL.md -print0)
done

echo "✅ Skills synced to ${CLIENTS[*]}"
