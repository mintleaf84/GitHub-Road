#!/bin/bash
# select-github-ip.sh -- Linux port of GitHub-Road's "verify + pick best IP" core.
#
# For each managed host:
#   1. seed candidates: current local DNS answer + DoH-resolved IPs from public
#      resolvers (the local DNS is often exactly the broken part on target
#      machines, so getent alone is untrusted) + the hardcoded fallback pool
#   2. probe every candidate IP (real HTTPS over TLS via curl --resolve) and ask
#      whether it actually *serves that host*, not whether it returns a status
#   3. rank the usable IPs, by (git-endpoint desc, passes desc, avg latency asc),
#      and write the TOP_K of them to the pin file
#   4. if none answered at all, KEEP the previous pins for that host (marked
#      stale) instead of dropping them -- on these networks DNS is the broken
#      part, so falling back to it would turn a slow link into a total outage.
# Several IPs per host are kept on purpose: libpin.so hands them to the client
# as a failover list, which is what makes this usable on an intermittently
# blocked link where any single IP may reset.
#
# Why "HTTP 200" is not an acceptable answer (measured, not theoretical):
# some GitHub Azure IPs are load-balancer health endpoints that reply to *every*
# path with 200 + text/plain "OK" (4 bytes) and a valid *.github.com certificate.
# Ranking on the status code alone pins one of those as the primary address, and
# then every real client breaks while `curl -I https://github.com` still looks
# green. Each host therefore declares what a genuine reply must look like, in
# HOST_PROBE below: "<path>:<accepted statuses>:<required content-type>".
#
# Why the git endpoint needs its own probe as well: git negotiates over
# …/<repo>.git/info/refs?service=…, which is a different code path from the web
# root, so an IP can serve real HTML at / and still not serve git. The failure
# happens at the protocol layer *after* a successful TLS connection, so the
# addrinfo failover in libpin.so cannot recover from it -- the first pinned IP is
# the one git talks to. Git hosts are therefore ranked on the git endpoint, and
# an IP that fails it is demoted behind any IP that passes, however fast it is.
# Without that check git fails with
#   fatal: '<url>' does not appear to be a git repository
# while curl and the REST API work perfectly.
#
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
#   GITHUB_ROAD_MIN_BODY         bytes a reply must exceed to count as real (default 64)
#   GITHUB_ROAD_GIT_PROBES       git endpoint probes per candidate on git hosts (default 2)
#   GITHUB_ROAD_GIT_HOSTS        hosts that serve git protocol (default github.com)
#   GITHUB_ROAD_GIT_PROBE_REPO   public repo used for the git endpoint probe (default git/git)
#   GITHUB_ROAD_TOP_K            IPs written per host (default 3)
#   GITHUB_ROAD_MAX_CANDIDATES   candidate IPs probed per host (default 16)
set -u

PIN_FILE="${GITHUB_ROAD_PIN:-$HOME/.hermes/github-pin}"
LOG="${GITHUB_ROAD_LOG:-$HOME/.hermes/github-road.log}"
CONNECT_TIMEOUT="${GITHUB_ROAD_CONNECT_TIMEOUT:-5}"
MAX_TIME="${GITHUB_ROAD_MAX_TIME:-10}"
PROBES="${GITHUB_ROAD_PROBES:-5}"
GIT_PROBES="${GITHUB_ROAD_GIT_PROBES:-2}"
GIT_HOSTS="${GITHUB_ROAD_GIT_HOSTS:-github.com}"
GIT_REPO="${GITHUB_ROAD_GIT_PROBE_REPO:-git/git}"
TOP_K="${GITHUB_ROAD_TOP_K:-3}"
MAX_CAND="${GITHUB_ROAD_MAX_CANDIDATES:-16}"
HOSTS="${GITHUB_ROAD_HOSTS:-github.com api.github.com raw.githubusercontent.com objects.githubusercontent.com codeload.github.com gist.github.com}"
QUIET="${GITHUB_ROAD_QUIET:-0}"

# Fallback pools (GitHub Azure-Asia + US, Fastly for raw/objects/gist).
# Primary candidates now come from DoH seeding below; these are the safety net
# for when every DoH endpoint is also unreachable. To refresh manually:
# resolve the host via any working resolver and curl --resolve each answer.
# 20.205.243.165 is kept here even though it no longer answers github.com: it is
# one of the few that really serves codeload archives.
GITHUB_CANDIDATES="140.82.112.4 20.205.243.169 140.82.114.4 20.205.243.168 140.82.121.4 20.205.243.166 20.205.243.170 20.27.177.113 20.27.177.114 20.27.177.115 20.27.177.116 140.82.112.3 140.82.113.3 140.82.113.4 140.82.114.3 140.82.116.3 140.82.121.3 20.205.243.165"
API_CANDIDATES="140.82.112.6 140.82.113.6 140.82.114.6 140.82.116.6 140.82.121.6 20.205.243.168 20.205.243.169"
FASTLY_CANDIDATES="185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133"

# --- what a genuine reply looks like, per host --------------------------------
# "<probe path>:<accepted statuses, comma separated>:<required content-type>"
# Unlisted hosts default to "/:200:" plus the MIN_BODY floor, which alone already
# rejects the 4-byte "OK" health endpoints.
#   github.com   web root is HTML; a text/plain reply is a stub, not GitHub
#   api.github.com   the REST root is JSON
#   codeload.github.com / gist.github.com / raw.githubusercontent.com
#     the root tells you nothing: an IP that downloads real archives answers "/"
#     with an empty 301, while one that 400s on every real request answers with
#     GitHub's HTML error page. So each of these is probed on the exact thing it
#     exists to serve, using small stable public paths.
# Redirects are deliberately not accepted: a redirect body is empty, which the
# MIN_BODY floor would also reject, and only a real 200 proves the service.
declare -A HOST_PROBE=(
    [github.com]='/:200:text/html'
    [api.github.com]='/:200:application/json'
    [codeload.github.com]='/octocat/Hello-World/tar.gz/refs/heads/master:200:application/x-gzip'
    [raw.githubusercontent.com]='/git/git/master/README.md:200:text/plain'
    [gist.github.com]='/:200:text/html'
)
MIN_BODY="${GITHUB_ROAD_MIN_BODY:-64}"

# objects.githubusercontent.com only ever issues signed URLs, so there is nothing
# stable to probe. It is the same Fastly anycast edge as raw, so it reuses the
# IPs that passed raw's file probe instead of burning its own candidate budget.
# The aliased host must appear before its alias in HOSTS.
declare -A HOST_ALIAS=(
    [objects.githubusercontent.com]='raw.githubusercontent.com'
)

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

# "<path>:<accepted statuses>:<content-type prefix>" for a host, or the default.
probe_spec() { # $1 = host -> sets SPEC_PATH SPEC_STATUS SPEC_CTYPE
    local p s c
    IFS=':' read -r p s c <<<"${HOST_PROBE[$1]:-/:200:}"
    SPEC_PATH="$p"
    SPEC_STATUS="${s:-200}"
    SPEC_CTYPE="$c"
}

# Does this reply come from the service we are trying to reach?
answer_ok() { # $1 = host, $2 = code, $3 = content_type, $4 = size -> 0 if genuine
    probe_spec "$1"
    case ",$SPEC_STATUS," in *",$2,"*) ;; *) return 1 ;; esac
    if [ -n "$SPEC_CTYPE" ]; then
        case "$3" in "$SPEC_CTYPE"*) ;; *) return 1 ;; esac
    fi
    [ "${4:-0}" -ge "$MIN_BODY" ]
}

# Print "HTTPCODE|CONTENT_TYPE|SIZE|TIME_TOTAL" for a host via one IP
# (direct, proxy ignored).
probe() {
    local host="$1" ip="$2"
    probe_spec "$host"
    curl -s -o /dev/null --noproxy '*' \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        --resolve "${host}:443:${ip}" "https://${host}${SPEC_PATH}" \
        -w '%{http_code}|%{content_type}|%{size_download}|%{time_total}' 2>/dev/null
}

is_git_host() {
    case " $GIT_HOSTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Does this IP really serve the git protocol? A genuine reply starts with the
# pkt-line service advertisement ("001e# service=git-upload-pack\n") and the
# application/x-git-upload-pack-advertisement content type; an IP that does not
# serve git answers with something else entirely (a stub "OK", an error page).
# The length prefix is matched as four hex digits so a format tweak upstream
# cannot silently mark every IP as broken.
#
# upload-pack (fetch) is the gate; do NOT add an anonymous receive-pack (push)
# check: GitHub answers that with 401 "No anonymous write access" on every
# healthy edge, so it would mark all candidates broken and pin nothing. A
# working upload-pack implies a working receive-pack on the same edge.
probe_git() { # $1 = host, $2 = ip -> 0 if the git endpoint answers correctly
    local body
    body="$(curl -s --noproxy '*' \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        --resolve "${1}:443:${2}" \
        "https://${1}/${GIT_REPO}.git/info/refs?service=git-upload-pack" \
        2>/dev/null | head -c 64)"
    printf '%s' "$body" | grep -qE '^00[0-9a-f]{2}# service=git-upload-pack'
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
    [ -n "${HOST_ALIAS[$host]:-}" ] && continue   # inherits another host's IPs
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

# Probe all candidates in parallel. Each writes "<host> <ip> <ok> <avg> <gitok>".
while read -r host ip; do
    [ -n "$host" ] || continue
    (
        ok=0; sum=0
        for ((r = 0; r < PROBES; r++)); do
            IFS='|' read -r code ctype size t < <(probe "$host" "$ip")
            [ -n "${code:-}" ] || code=000
            if answer_ok "$host" "$code" "$ctype" "${size:-0}"; then
                ok=$((ok + 1))
                sum=$(awk "BEGIN{print $sum + ${t:-0}}")
            fi
        done
        if [ "$ok" -gt 0 ]; then
            avg=$(awk "BEGIN{printf \"%.3f\", $sum / $ok}")
        else
            avg="0.000"
        fi
        # Only worth asking the git endpoint when the IP is reachable at all;
        # an unreachable one is dropped by the ranking either way.
        gitok=0
        if [ "$ok" -gt 0 ] && is_git_host "$host"; then
            for ((r = 0; r < GIT_PROBES; r++)); do
                probe_git "$host" "$ip" && gitok=$((gitok + 1))
            done
        fi
        echo "$host $ip $ok $avg $gitok"
    ) >>"$RESULTS" &
done <<<"$PAIRS"
wait

# Report and write the top-K IPs per host.
declare -A PICKED=()
for host in $HOSTS; do
    if is_git_host "$host"; then need_git=1; else need_git=0; fi

    # Hosts that cannot be probed on their own inherit a validated edge.
    alias_for="${HOST_ALIAS[$host]:-}"
    if [ -n "$alias_for" ]; then
        if [ -n "${PICKED[$alias_for]:-}" ]; then
            for ip in ${PICKED[$alias_for]}; do printf '%s %s\n' "$host" "$ip" >>"$PIN_TMP"; done
            PICKED[$host]="${PICKED[$alias_for]}"
            say "[OK] $host -> reusing the ${alias_for} edge: ${PICKED[$alias_for]}"
            log "pick $host -> ${PICKED[$alias_for]}(aliased from $alias_for)"
        else
            say "[!!] $host: no usable $alias_for IP this run - no pin (fallback to DNS)"
            log "fail $host: nothing to alias from $alias_for, DNS fallback"
        fi
        continue
    fi

    while read -r h ip ok avg gitok; do
        [ "$h" = "$host" ] || continue
        if [ "$need_git" = 1 ]; then
            say "      $host $ip -> served x${ok}/${PROBES} (avg ${avg}s) git x${gitok}/${GIT_PROBES}"
        else
            say "      $host $ip -> served x${ok}/${PROBES} (avg ${avg}s)"
        fi
    done <"$RESULTS"

    # ranked columns: <key1> <ok> <avg> <ip>. On a git host key1 is the
    # git-endpoint score, so an IP that only looks healthy on the web root can
    # never outrank one git actually works with, however fast it is.
    ranked="$(awk -v h="$host" -v git="$need_git" '$1 == h && $3 >= 1 {
            print (git ? $5 : $3), $3, $4, $2
        }' "$RESULTS" | sort -k1,1nr -k2,2nr -k3,3n)"
    if [ -z "$ranked" ]; then
        if [ -n "${OLD_PINS[$host]:-}" ]; then
            printf '# stale since %s: no reachable IP in last selection, keeping previous pins\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" >>"$PIN_TMP"
            for old_ip in ${OLD_PINS[$host]}; do
                printf '%s %s\n' "$host" "$old_ip" >>"$PIN_TMP"
            done
            PICKED[$host]="${OLD_PINS[$host]}"
            say "[!!] $host: no reachable IP - keeping last-known-good pins (STALE)"
            log "stale $host: no reachable IP; kept previous pins: ${OLD_PINS[$host]}"
        else
            say "[!!] $host: no IP answered - no pin (fallback to DNS)"
            log "fail $host: no reachable IP, no previous pins, DNS fallback"
        fi
        continue
    fi

    printf '%s\n' "$ranked" | head -n "$TOP_K" | while read -r k1 ok avg ip; do
        [ -n "$ip" ] && printf '%s %s\n' "$host" "$ip" >>"$PIN_TMP"
    done
    kept="$(printf '%s\n' "$ranked" | head -n "$TOP_K" | wc -l)"
    read -r k1 pok pt pip <<<"$(printf '%s\n' "$ranked" | head -n 1)"
    PICKED[$host]="$(printf '%s\n' "$ranked" | head -n "$TOP_K" | awk '{print $4}' | tr '\n' ' ')"
    say "[OK] $host -> $pip (+$((kept - 1)) failover) [best ${pok}/${PROBES}, avg ${pt}s]"
    log "pick $host -> ${PICKED[$host]}(best ${pok}/${PROBES})"

    if [ "$need_git" = 1 ]; then
        git_good="$(awk -v h="$host" '$1 == h && $3 >= 1 && $5 >= 1' "$RESULTS" | wc -l)"
        git_bad="$(awk -v h="$host" '$1 == h && $3 >= 1 && $5 == 0' "$RESULTS" | wc -l)"
        if [ "$git_good" = 0 ]; then
            say "[!!] $host: none of the ${git_bad} reachable IP(s) serves the git protocol"
            say "     pinned for curl/API only; git clone/push will still fail - needs a proxy"
            log "warn $host: no IP serves the git protocol (HTTP-only pins), git will fail"
        elif [ "$git_bad" != 0 ]; then
            say "      $host: $git_bad reachable IP(s) demoted - they answer the web root but not git"
            log "note $host: demoted $git_bad non-git IP(s), $git_good usable"
        fi
    fi
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
