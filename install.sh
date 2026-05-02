#!/usr/bin/env bash
#
# cloudflare-cn-kit (cfcn) installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tianmind-studio/cloudflare-cn-kit/main/install.sh | bash
#
# Env:
#   CFCN_PREFIX   Install prefix. Default: $HOME/.local
#   CFCN_REF      Git ref. Default: main
#   CFCN_REPO     GitHub repo slug. Default: tianmind-studio/cloudflare-cn-kit

set -euo pipefail

CFCN_PREFIX="${CFCN_PREFIX:-$HOME/.local}"
CFCN_REF="${CFCN_REF:-main}"
REPO="${CFCN_REPO:-tianmind-studio/cloudflare-cn-kit}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "==> downloading cfcn@$CFCN_REF"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$CFCN_REF" \
  | tar -xz -C "$TMPDIR"

SRC="$TMPDIR/$(basename "$REPO")-$CFCN_REF"
DEST="$CFCN_PREFIX/share/cloudflare-cn-kit"
BIN="$CFCN_PREFIX/bin/cfcn"

mkdir -p "$CFCN_PREFIX/bin" "$CFCN_PREFIX/share"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
ln -sf "$DEST/bin/cfcn" "$BIN"
chmod +x "$DEST/bin/cfcn"

echo ""
echo "==> installed: $BIN"
if ! echo ":$PATH:" | grep -q ":$CFCN_PREFIX/bin:"; then
  cat <<EOF

Your PATH does not include $CFCN_PREFIX/bin yet. Add this to your shell rc:

  export PATH="$CFCN_PREFIX/bin:\$PATH"

Then:
  export CFCN_TOKEN="cf_xxx..."   # a scoped token
  cfcn doctor
EOF
else
  cat <<EOF

Next:
  export CFCN_TOKEN="cf_xxx..."   # a scoped token
  cfcn doctor
EOF
fi
