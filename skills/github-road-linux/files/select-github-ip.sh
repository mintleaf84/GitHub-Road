#!/bin/bash
# select-github-ip.sh -- Linux port of GitHub-Road's "verify + pick best IP" core.
#
# For each managed host:
#   1. seed candidates: current local DNS answer + DoH-resolved IPs from public
#      resolvers (the local DNS is often exactly the broken part on target
#      machines, so getent alone is untrusted) + the hardcoded fallback pool
#   2. probe every candidate IP (real HTTPS over TLS via curl --resolve)
#   3. rank the IPs that answered HTTP 200 at least once, by (passes desc, avg
#      latency asc), and write the TOP_K of them to the pin file
#   4. if none answered at all, KEEP the previous pins for that host (marked
#      stale) instead of dropping them -- on these networks DNS is the broken
#      part, so falling back to it would turn a slow link into a total outage.
# Several IPs per host are kept on purpose: libpin.so hands them to the client
# as a failover list, which is what makes this usable on an intermittently
# blocked link where any single IP may reset.
# Candidate probes run in parallel with fail-fast, so a 30-minute cron run
# finishes in seconds even when most IPs are dead.
#
# The winning IPs are written to the pin file read by libpin.so, so no root and
# no /etc/hosts edit is required.
#
# Env overrides:
#   GITHUB_ROAD_PIN              pin file path   (default ~/.hermes/github-pin)
#   GITHUB_ROAD_LOG              log path        (default ~/.hermes/github-road.log)
#   GITHUB_ROAD_HOSTS            hosts to manage (see HOSTS below)
#   GITHUB_ROAD_CONNECT_TIMEOUT  curl connect timeout seconds (default 5)
#   GITHUB_ROAD_MAX_TIME         curl max time seconds        (default 10)
#   GITHUB_ROAD_PROBES           probes per candidate (default 5)
#   GITHUB_ROAD_TOP_K            IPs written per host (default 3)
#   GITHUB_ROAD_MAX_CANDIDATES   candidate IPs probed per host (default 16)
set -u

PIN_FILE="${GITHUB_ROAD_PIN:-$HOME/.hermes/github-pin}"
LOG="${GITHUB_ROAD_LOG:-$HOME/.hermes/github-road.log}"
CONNECT_TIMEOUT="${GITHUB_ROAD_CONNECT_TIMEOUT:-5}"
MAX_TIME="${GITHUB_ROAD_MAX_TIME:-10}"
PROBES="${GITHUB_ROAD_PROBES:-5}"
TOP_K="${GITHUB_ROAD_TOP_K:-3}"
MAX_CAND="${GITHUB_ROAD_MAX_CANDIDATES:-16}"
HOSTS="${GITHUB_ROAD_HOSTS:-github.com api.github.com raw.githubusercontent.com objects.githubusercontent.com codeload.github.com gist.github.com}"
QUIET="${GITHUB_ROAD_QUIET:-0}"

# Fallback pools (GitHub Azure-Asia + US, Fastly for raw/objects/gist).
# Primary candidates now come from DoH seeding below; these are the safety net
# for when every DoH endpoint is also unreachable. To refresh manually:
# resolve the host via any working resolver and curl --resolve each answer.
GITHUB_CANDIDATES="140.82.112.4 20.205.243.169 140.82.114.4 20.205.243.168 140.82.121.4 20.205.243.166 20.205.243.170 20.27.177.113 20.27.177.114 20.27.177.115 20.27.177.116 140.82.112.3 140.82.113.3 140.82.113.4 140.82.114.3 140.82.116.3 140.82.121.3"
API_CANDIDATES="140.82.112.6 140.82.113.6 140.82.114.6 140.82.116.6 140.82.121.6 20.205.243.168 20.205.243.169"
FASTLY_CANDIDATES="185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133"

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
log() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
}
candidates_for() {
    case "$1" in
        raw.githubusercontent.com|objects.githubusercontent.com|gist.github.com)
            printf '%s\n' "$FASTLY_CANDIDATES" ;;
        api.github.com)
            printf '%s\n' "$API_CANDIDATES" ;;
        *)
            printf '%s\n' "$GITHUB_CANDIDATES" ;;
    esac
}

# Print "HTTPCODE TIME_TOTAL" for host via a specific IP (direct, proxy ignored).
probe() {
    local host="$1" ip="$2"
    curl -s -o /dev/null --noproxy '*' \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        --resolve "${host}:443:${ip}" "https://${host}" \
        -w '%{http_code} %{time_total}' 2>/dev/null
}

# --- DoH candidate seeding ----------------------------------------------------
# Ask public DNS-over-HTTPS resolvers for the current IPs of a host. curl pins
# each resolver to a known IP via --resolve (so a poisoned local DNS cannot
# redirect the DoH query itself) while keeping TLS certificate validation.
DOH_PROVIDERS="dns.alidns.com:223.5.5.5 cloudflare-dns.com:1.1.1.1 doh.pub:1.12.12.12"

dns_seed() { # $1 = host -> one IPv4 per line (may be empty)
    local p name ip
    for p in $DOH_PROVIDERS; do
        name="${p%%:*}"
        ip="${p##*:}"
        curl -s --noproxy '*' --resolve "$name:443:$ip" \
             --connect-timeout 2 --max-time 4 \
             -H 'accept: application/dns-json' \
             "https://$name/resolve?name=$1&type=A" 2>/dev/null \
            | grep -oE '"data"[[:space:]]*:[[:space:]]*"[0-9.]+"' \
            | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}'
    done
}

log "select-github-ip start (pid $$)"
say "[-] selecting GitHub IPs (hosts: $HOSTS, probes/IP: $PROBES, top-K: $TOP_K)"

# Last-known-good pins from the previous run: kept when a host has no reachable
# IP this time (marked stale in the pin file) instead of falling back to DNS.
declare -A OLD_PINS=()
if [ -f "$PIN_FILE" ]; then
    while read -r old_host old_ip _; do
        case "$old_host" in ''|\#*) continue ;; esac
        OLD_PINS[$old_host]="${OLD_PINS[$old_host]:-}$old_ip "
    done <"$PIN_FILE"
fi

# Build the (host ip) work list: local DNS answer, then DoH seeds, then the
# fallback pool; dedupe per host and cap the probe budget.
PAIRS=""
for host in $HOSTS; do
    dns_ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')"
    seen=" "
    n=0
    for ip in $dns_ip $(dns_seed "$host") $(candidates_for "$host"); do
        [ -n "$ip" ] || continue
        case "$seen" in *" $ip "*) continue ;; esac
        seen="$seen$ip "
        PAIRS="${PAIRS}${host} ${ip}"$'\n'
        n=$((n + 1))
        [ "$n" -ge "$MAX_CAND" ] && break
    done
done

RESULTS="$(mktemp "${TMPDIR:-/tmp}/gh-road.XXXXXX")"
PIN_DIR="$(dirname "$PIN_FILE")"
mkdir -p "$PIN_DIR" 2>/dev/null || { say "[!!] cannot create pin directory: $PIN_DIR"; exit 1; }
PIN_TMP="$(mktemp "$PIN_DIR/.gh-pin.XXXXXX")" || { say "[!!] cannot create temp file in $PIN_DIR"; exit 1; }
trap 'rm -f "$RESULTS" "$PIN_TMP" "${PIN_TMP}.final"' EXIT

# Probe all candidates in parallel. Each writes "<host> <ip> <ok> <avg>".
while read -r host ip; do
    [ -n "$host" ] || continue
    (
        ok=0; sum=0
        for ((r = 0; r < PROBES; r++)); do
            read -r code t < <(probe "$host" "$ip")
            [ -n "${code:-}" ] || code=000
            if [ "$code" = "200" ]; then
                ok=$((ok + 1))
                sum=$(awk "BEGIN{print $sum + $t}")
            fi
        done
        if [ "$ok" -gt 0 ]; then
            avg=$(awk "BEGIN{printf \"%.3f\", $sum / $ok}")
        else
            avg="0.000"
        fi
        echo "$host $ip $ok $avg"
    ) >>"$RESULTS" &
done <<<"$PAIRS"
wait

# Report and write the top-K IPs per host.
for host in $HOSTS; do
    while read -r h ip ok avg; do
        [ "$h" = "$host" ] || continue
        say "      $host $ip -> HTTP200 x${ok}/${PROBES} (avg ${avg}s)"
    done <"$RESULTS"

    ranked="$(awk -v h="$host" '$1 == h && $3 >= 1 { print $3, $4, $2 }' "$RESULTS" | sort -k1,1nr -k2,2n)"
    if [ -z "$ranked" ]; then
        if [ -n "${OLD_PINS[$host]:-}" ]; then
            printf '# stale since %s: no reachable IP in last selection, keeping previous pins\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" >>"$PIN_TMP"
            for old_ip in ${OLD_PINS[$host]}; do
                printf '%s %s\n' "$host" "$old_ip" >>"$PIN_TMP"
            done
            say "[!!] $host: no reachable IP - keeping last-known-good pins (STALE)"
            log "stale $host: no reachable IP; kept previous pins: ${OLD_PINS[$host]}"
        else
            say "[!!] $host: no IP answered - no pin (fallback to DNS)"
            log "fail $host: no reachable IP, no previous pins, DNS fallback"
        fi
        continue
    fi

    printf '%s\n' "$ranked" | head -n "$TOP_K" | while read -r ok avg ip; do
        [ -n "$ip" ] && printf '%s %s\n' "$host" "$ip" >>"$PIN_TMP"
    done
    kept="$(printf '%s\n' "$ranked" | head -n "$TOP_K" | wc -l)"
    primary="$(printf '%s\n' "$ranked" | head -n 1)"
    pok="$(printf '%s\n' "$primary" | awk '{print $1}')"
    pt="$(printf '%s\n' "$primary" | awk '{print $2}')"
    pip="$(printf '%s\n' "$primary" | awk '{print $3}')"
    say "[OK] $host -> $pip (+$((kept - 1)) failover) [best ${pok}/${PROBES}, avg ${pt}s]"
    log "pick $host -> $(printf '%s\n' "$ranked" | head -n "$TOP_K" | awk '{print $3}' | tr '\n' ' ')(best ${pok}/${PROBES})"
done

{
    printf '# managed by github-road-linux; regenerated by select-github-ip.sh\n'
    printf '# format: <hostname> <ip>   -- consumed by libpin.so (LD_PRELOAD, in order)\n'
    cat "$PIN_TMP"
} >"${PIN_TMP}.final"
if ! mv -f "${PIN_TMP}.final" "$PIN_FILE"; then
    say "[!!] failed to update pin file: $PIN_FILE"
    log "error: failed to replace pin file $PIN_FILE"
    exit 1
fi
say "[-] pin file updated: $PIN_FILE"
log "wrote pin file $PIN_FILE ($(grep -vc '^#' "$PIN_FILE" 2>/dev/null || echo 0) entries)"
