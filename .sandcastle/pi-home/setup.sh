#!/usr/bin/env bash
# Seed the isolated pi config used by the sandcastle workflows.
#
# Only settings.json and AGENTS.md are committed. Everything else is seeded
# from your real ~/.pi/agent because it is either a credential or a cache:
#
#   auth.json         symlinked, so credentials stay in exactly one place
#   models-store.json copied — the model catalog. A fresh config dir knows only
#                     amazon-bedrock, and `pi update --models` needs network
#                     that is not always reachable here.
#   models.json       copied — custom model entries (the :nitro deepseek).
#   npm/              installed by pi on first run, from settings.json packages.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${PI_SOURCE_DIR:-$HOME/.pi/agent}"

[ -d "$SRC" ] || { echo "No pi config at $SRC" >&2; exit 1; }

ln -sf "$SRC/auth.json" "$HERE/auth.json"
for f in models-store.json models.json; do
	[ -f "$SRC/$f" ] && cp "$SRC/$f" "$HERE/$f"
done

echo "Seeded $HERE from $SRC"
PI_CODING_AGENT_DIR="$HERE" pi --list-models >/dev/null
echo "Model catalog resolves. Providers:"
PI_CODING_AGENT_DIR="$HERE" pi --list-models | awk 'NR>1 {print $1}' | sort -u | sed 's/^/  /'
