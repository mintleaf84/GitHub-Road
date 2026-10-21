/*
 * libpin.c -- LD_PRELOAD getaddrinfo()/gethostbyname*() shim
 *             (non-root alternative to /etc/hosts)
 *
 * Linux port of the "GitHub-Road" hosts-pinning idea. On a machine where the
 * user has no root (cannot edit /etc/hosts), we still need to force specific
 * hostnames (e.g. github.com) to chosen IPs. This shim interposes the libc
 * resolver entry points and, for any hostname listed in the pin file, returns
 * the pinned IP(s) *instead of* the DNS answer.
 *
 * Both resolver families are interposed because real programs split across
 * them: curl/git/libcurl use getaddrinfo(), while older tools and utilities
 * like `getent hosts` go through gethostbyname()/gethostbyname2() (plus their
 * _r reentrant variants used by threaded programs).
 *
 * Multiple IPs per host are supported for getaddrinfo(): they are returned as
 * one linked list, so the client (curl / git / anything using libcurl or
 * getaddrinfo) automatically fails over to the next IP when one is reset or
 * blackholed -- essential on flaky, intermittently-blocked links. The legacy
 * gethostbyname family can only express a single address per call, so those
 * entry points return the first (highest-priority) pinned IP.
 *
 * Not covered (documented in SKILL.md): statically linked programs that do
 * their own DNS (Go with the pure-Go resolver, dig/nslookup, etc.) never call
 * libc, and tools resolving via res_query() bypass these entry points too.
 *
 * The pin file is read at call time, so IP changes from the auto-heal cron job
 * take effect immediately, with no recompile.
 *
 * Pin file format (whitespace separated, '#' comments allowed; order matters,
 * first line per host is tried first):
 *     github.com      140.82.112.4
 *     github.com      20.205.243.169
 *     api.github.com  20.205.243.168
 *
 * Pin file location (override with env GITHUB_ROAD_PIN):
 *     $HOME/.hermes/github-pin
 *
 * Build:
 *     gcc -shared -fPIC -O2 -o libpin.so libpin.c -ldl
 *
 * Use:
 *     LD_PRELOAD=/path/to/libpin.so git push ...
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef GITHUB_ROAD_PIN_REL
#define GITHUB_ROAD_PIN_REL ".hermes/github-pin"
#endif
#define MAX_PINS 32

typedef int (*getaddrinfo_fn)(const char *, const char *,
                              const struct addrinfo *, struct addrinfo **);
typedef struct hostent *(*ghbn_fn)(const char *);
typedef struct hostent *(*ghbn2_fn)(const char *, int);
typedef int (*ghbn_r_fn)(const char *, struct hostent *, char *, size_t,
                         struct hostent **, int *);
typedef int (*ghbn2_r_fn)(const char *, int, struct hostent *, char *, size_t,
                          struct hostent **, int *);

static getaddrinfo_fn real_ga(void) {
    static getaddrinfo_fn real = NULL;
    if (!real)
        real = (getaddrinfo_fn)dlsym(RTLD_NEXT, "getaddrinfo");
    return real;
}
static ghbn_fn real_ghbn(void) {
    static ghbn_fn real = NULL;
    if (!real)
        real = (ghbn_fn)dlsym(RTLD_NEXT, "gethostbyname");
    return real;
}
static ghbn2_fn real_ghbn2(void) {
    static ghbn2_fn real = NULL;
    if (!real)
        real = (ghbn2_fn)dlsym(RTLD_NEXT, "gethostbyname2");
    return real;
}
static ghbn_r_fn real_ghbn_r(void) {
    static ghbn_r_fn real = NULL;
    if (!real)
        real = (ghbn_r_fn)dlsym(RTLD_NEXT, "gethostbyname_r");
    return real;
}
static ghbn2_r_fn real_ghbn2_r(void) {
    static ghbn2_r_fn real = NULL;
    if (!real)
        real = (ghbn2_r_fn)dlsym(RTLD_NEXT, "gethostbyname2_r");
    return real;
}

/* Collect every pinned IPv4 for host, in file order. Returns the count. */
static int collect_pins(const char *host, char out[][64], int max) {
    const char *env = getenv("GITHUB_ROAD_PIN");
    char path[4096];

    if (env && *env) {
        snprintf(path, sizeof(path), "%s", env);
    } else {
        const char *home = getenv("HOME");
        if (!home || !*home)
            return 0;
        snprintf(path, sizeof(path), "%s/%s", home, GITHUB_ROAD_PIN_REL);
    }

    FILE *f = fopen(path, "r");
    if (!f)
        return 0;

    int n = 0;
    char line[1024];
    while (n < max && fgets(line, sizeof(line), f)) {
        char h[256], ip[64];
        char *p = line;
        while (*p == ' ' || *p == '\t')
            p++;
        if (*p == '#' || *p == '\n' || *p == '\0')
            continue;
        if (sscanf(p, "%255s %63s", h, ip) == 2 &&
            strcasecmp(h, host) == 0 &&
            inet_pton(AF_INET, ip, &(struct in_addr){0}) == 1)
            snprintf(out[n++], 64, "%s", ip);
    }
    fclose(f);
    return n;
}

/* --- getaddrinfo family ---------------------------------------------------- */

int getaddrinfo(const char *node, const char *service,
                const struct addrinfo *hints, struct addrinfo **res) {
    getaddrinfo_fn real = real_ga();
    if (!real)
        return EAI_SYSTEM;

    if (node && *node) {
        char pins[MAX_PINS][64];
        int n = collect_pins(node, pins, MAX_PINS);
        if (n > 0) {
            struct addrinfo *head = NULL, *tail = NULL;
            int i;
            for (i = 0; i < n; i++) {
                struct addrinfo *ai = NULL;
                if (real(pins[i], service, hints, &ai) != 0 || !ai)
                    continue;
                if (!head)
                    head = ai;
                else
                    tail->ai_next = ai;
                tail = ai;
                while (tail->ai_next)
                    tail = tail->ai_next;
            }
            if (head) {
                *res = head;
                return 0;
            }
        }
    }
    return real(node, service, hints, res);
}

/* --- gethostbyname family -------------------------------------------------- */
/* The legacy API can only return one address per call, so these return the
 * first (highest-priority) pinned IP. */

static struct hostent  g_he;
static char           *g_he_aliases[1];
static char           *g_he_addrs[2];
static struct in_addr  g_he_addr;
static char            g_he_name[256];

static struct hostent *hostent_from_first_pin(const char *node) {
    char pins[1][64];
    if (collect_pins(node, pins, 1) < 1 ||
        inet_pton(AF_INET, pins[0], &g_he_addr) != 1)
        return NULL;
    snprintf(g_he_name, sizeof(g_he_name), "%s", node);
    g_he_aliases[0] = NULL;
    g_he_addrs[0] = (char *)&g_he_addr;
    g_he_addrs[1] = NULL;
    g_he.h_name = g_he_name;
    g_he.h_aliases = g_he_aliases;
    g_he.h_addrtype = AF_INET;
    g_he.h_length = sizeof(struct in_addr);
    g_he.h_addr_list = g_he_addrs;
    return &g_he;
}

struct hostent *gethostbyname(const char *name) {
    struct hostent *he = hostent_from_first_pin(name);
    if (he)
        return he;
    return real_ghbn()(name);
}

struct hostent *gethostbyname2(const char *name, int af) {
    if (af == AF_INET) {
        struct hostent *he = hostent_from_first_pin(name);
        if (he)
            return he;
    }
    return real_ghbn2()(name, af);
}

/* Pack a pinned hostent into the caller-supplied buffer of the _r API.
 * Layout: h_name string | aliases{NULL} | addr_list{ptr,NULL} | in_addr. */
static int fill_hostent_r(const char *node, const char *ip,
                          struct hostent *ret, char *buf, size_t buflen,
                          struct hostent **result, int *h_errnop) {
    size_t off = 0;

    if (h_errnop)
        *h_errnop = 0;
    *result = NULL;

#define ALIGN_UP(x) (((x) + sizeof(void *) - 1) & ~(sizeof(void *) - 1))

    if (buflen < strlen(node) + 1)
        goto too_small;
    memcpy(buf, node, strlen(node) + 1);
    ret->h_name = buf;
    off = ALIGN_UP(strlen(node) + 1);

    if (buflen < off + sizeof(char *))
        goto too_small;
    ret->h_aliases = (char **)(buf + off);
    ret->h_aliases[0] = NULL;
    off += sizeof(char *);

    off = ALIGN_UP(off);
    if (buflen < off + 2 * sizeof(char *) + sizeof(struct in_addr))
        goto too_small;
    ret->h_addr_list = (char **)(buf + off);
    {
        struct in_addr *ia =
            (struct in_addr *)(buf + off + 2 * sizeof(char *));
        if (inet_pton(AF_INET, ip, ia) != 1) {
            if (h_errnop)
                *h_errnop = NO_RECOVERY;
            return ENOENT;
        }
        ret->h_addr_list[0] = (char *)ia;
        ret->h_addr_list[1] = NULL;
    }
    ret->h_addrtype = AF_INET;
    ret->h_length = sizeof(struct in_addr);
    *result = ret;
    return 0;

too_small:
    if (h_errnop)
        *h_errnop = ERANGE;
    return ERANGE;
}

int gethostbyname_r(const char *name, struct hostent *ret, char *buf,
                    size_t buflen, struct hostent **result, int *h_errnop) {
    char pins[1][64];
    if (collect_pins(name, pins, 1) >= 1)
        return fill_hostent_r(name, pins[0], ret, buf, buflen, result,
                              h_errnop);
    return real_ghbn_r()(name, ret, buf, buflen, result, h_errnop);
}

int gethostbyname2_r(const char *name, int af, struct hostent *ret, char *buf,
                     size_t buflen, struct hostent **result, int *h_errnop) {
    char pins[1][64];
    if (af == AF_INET && collect_pins(name, pins, 1) >= 1)
        return fill_hostent_r(name, pins[0], ret, buf, buflen, result,
                              h_errnop);
    return real_ghbn2_r()(name, af, ret, buf, buflen, result, h_errnop);
}
