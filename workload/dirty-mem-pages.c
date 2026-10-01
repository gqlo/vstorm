#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <ctype.h>

static void usage(const char *prog) {
    fprintf(stderr,
            "usage: %s <value>\n"
            "  value: - a fraction of physical RAM (e.g., 0.5)\n"
            "         - an explicit byte count (e.g., 1073741824)\n"
            "         - a human-readable size (e.g., 512M, 2G, 4KB, 1.5G)\n\n"
            "  Allocates a buffer of that size and dirties it at one full\n"
            "  pass per second (dirty rate equals buffer size per second).\n",
            prog);
}

/* Parses a string into bytes. Supports fractions (0.1-0.9) and units (K, M, G, T). */
static int parse_input(const char *str, uint64_t mem_total, uint64_t *out_bytes) {
    char *endptr = NULL;
    errno = 0;
    double val = strtod(str, &endptr);

    if (errno != 0 || endptr == str) {
        return -1;
    }

    while (isspace((unsigned char)*endptr)) {
        endptr++;
    }

    if (*endptr == '\0') {
        if (val <= 0.0)
            return -1;

        if (val < 1.0) {
            if (val < 0.1 || val > 0.9)
                return -2;
            *out_bytes = (uint64_t)(mem_total * val);
            return 0;
        }

        *out_bytes = (uint64_t)val;
        return 0;
    }

    char unit = tolower((unsigned char)*endptr);
    endptr++;

    if (tolower((unsigned char)*endptr) == 'i')
        endptr++;
    if (tolower((unsigned char)*endptr) == 'b')
        endptr++;

    if (*endptr != '\0')
        return -1;

    double multiplier = 1.0;
    switch (unit) {
        case 'k': multiplier = 1024.0; break;
        case 'm': multiplier = 1024.0 * 1024.0; break;
        case 'g': multiplier = 1024.0 * 1024.0 * 1024.0; break;
        case 't': multiplier = 1024.0 * 1024.0 * 1024.0 * 1024.0; break;
        default: return -1;
    }

    *out_bytes = (uint64_t)(val * multiplier);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        usage(argv[0]);
        return 1;
    }

    long psz = sysconf(_SC_PAGESIZE);
    if (psz <= 0) {
        perror("sysconf(_SC_PAGESIZE)");
        return 1;
    }
    const size_t page = (size_t)psz;

    long phys_pages = sysconf(_SC_PHYS_PAGES);
    if (phys_pages < 0) {
        perror("sysconf(_SC_PHYS_PAGES)");
        return 1;
    }
    uint64_t mem_total = (uint64_t)phys_pages * (uint64_t)page;

    uint64_t bytes = 0;
    int rc = parse_input(argv[1], mem_total, &bytes);
    if (rc == -1) {
        fprintf(stderr, "%s: invalid input string: %s\n", argv[0], argv[1]);
        return 1;
    } else if (rc == -2) {
        fprintf(stderr, "%s: fraction must be between 0.1 and 0.9\n", argv[0]);
        return 1;
    }

    uint64_t max_bytes = (uint64_t)(mem_total * 0.9);
    if (bytes > max_bytes) {
        fprintf(stderr, "%s: requested size (%llu B) exceeds usable limit (%llu B, 90%% of %llu B RAM)\n",
                argv[0],
                (unsigned long long)bytes,
                (unsigned long long)max_bytes,
                (unsigned long long)mem_total);
        return 1;
    }

    bytes -= bytes % page;
    if (bytes < page)
        bytes = page;

    const size_t TOTAL = (size_t)bytes;
    const size_t n_pages = TOTAL / page;
    const size_t DIRTY_PER_SEC = TOTAL;
    const size_t PAGES_PER_SEC = DIRTY_PER_SEC / page;

    fprintf(stderr,
            "%s: phys_ram=%llu MiB buffer=%zu MiB dirty=%zu MiB/s page=%zu\n",
            argv[0],
            (unsigned long long)(mem_total / (1024 * 1024)),
            TOTAL / (1024 * 1024),
            DIRTY_PER_SEC / (1024 * 1024),
            page);

    void *buf = mmap(NULL, TOTAL, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    char *mem = (char *)buf;
    size_t page_idx = 0;

    while (1) {
        struct timespec start, end_ts;
        clock_gettime(CLOCK_MONOTONIC, &start);

        for (size_t i = 0; i < PAGES_PER_SEC; i++) {
            mem[page_idx * page] = (char)i;
            page_idx = (page_idx + 1) % n_pages;
        }

        clock_gettime(CLOCK_MONOTONIC, &end_ts);
        long elapsed_us = (end_ts.tv_sec - start.tv_sec) * 1000000L
                        + (end_ts.tv_nsec - start.tv_nsec) / 1000;

        long remaining = 1000000L - elapsed_us;
        if (remaining > 0)
            usleep((useconds_t)remaining);

        printf("dirtied %zu MiB, elapsed %ld us, sleep %ld us\n",
               DIRTY_PER_SEC / (1024 * 1024), elapsed_us,
               remaining > 0 ? remaining : 0);
        fflush(stdout);
    }
}
