#!/bin/bash
# uninstall.sh -- remove the GitHub-Road Linux hooks (bashrc + crontab).
# Keeps libpin.so and the pin file; delete $HOME/.hermes/github-pin to fully revert.
set -u

MARK="github-road-linux"
BASHRC="$HOME/.bashrc"
if [ -L "$BASHRC" ]; then
    # sed -i would replace the symlink itself; edit the file it points to instead.
    BASHRC_TARGET="$(readlink -f "$BASHRC" 2>/dev/null || true)"
    [ -n "$BASHRC_TARGET" ] || { echo "[uninstall] cannot resolve symlink: $BASHRC"; exit 1; }
else
    BASHRC_TARGET="$BASHRC"
fi

if grep -q ">>> ${MARK} >>>" "$BASHRC" 2>/dev/null; then
    sed -i "/# >>> ${MARK} >>>/,/# <<< ${MARK} <<</d" "$BASHRC_TARGET"
    echo "[uninstall] removed bashrc hook"
else
    echo "[uninstall] no bashrc hook found"
fi

CUR="$(crontab -l 2>/dev/null || true)"
if printf '%s\n' "$CUR" | grep -q ">>> ${MARK} >>>"; then
    printf '%s\n' "$CUR" | sed "/# >>> ${MARK} >>>/,/# <<< ${MARK} <<</d" | grep -v '^[[:space:]]*$' | crontab -
    echo "[uninstall] removed crontab auto-heal"
else
    echo "[uninstall] no crontab entry found"
fi

echo "[uninstall] done. (pin file, learned pool and libpin.so kept;"
echo "            delete \$HOME/.hermes/github-pin and \$HOME/.hermes/github-candidates to fully revert)"
