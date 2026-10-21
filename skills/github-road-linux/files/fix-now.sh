#!/bin/bash
# fix-now.sh -- one-shot repair: re-select IPs and verify through the shim.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SO="$HERE/libpin.so"
PIN_FILE="${GITHUB_ROAD_PIN:-$HOME/.hermes/github-pin}"

[ -f "$SO" ] || { echo "libpin.so missing - run install.sh first"; exit 1; }

bash "$HERE/select-github-ip.sh"

echo "[verify] through the shim (direct, proxy ignored):"
resp="$(
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        LD_PRELOAD="$SO" GITHUB_ROAD_PIN="$PIN_FILE" \
        curl -s -o /dev/null -w '%{http_code} %{remote_ip}' \
        --noproxy '*' --connect-timeout 5 --max-time 8 https://github.com
)"
code="${resp%% *}"
ip="${resp#* }"
printf '  https://github.com -> HTTP %s (ip %s)\n' "${code:-000}" "$ip"
if [ "${code:-000}" != "200" ]; then
    echo "[!!] verification failed: expected HTTP 200" >&2
    exit 1
fi
