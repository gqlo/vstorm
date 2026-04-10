#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void usage(const char *prog) {
    fprintf(stderr,
            "usage: %s <fraction>\n"
            "  fraction: 0.1 .. 0.9 (fraction of physical RAM)\n"
            "  buffer size and dirty rate (bytes/s) both use this fraction;\n"
            "  about one full pass through the buffer per second.\n",
            prog);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        usage(argv[0]);
        return 1;
    }

    errno = 0;
    char *end = NULL;
    double pct = strtod(argv[1], &end);
    if (errno != 0 || end == argv[1] || *end != '\0') {
        fprintf(stderr, "%s: invalid number: %s\n", argv[0], argv[1]);
        return 1;
    }
    if (pct < 0.1 || pct > 0.9) {
        fprintf(stderr, "%s: fraction must be between 0.1 and 0.9\n", argv[0]);
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

    uint64_t bytes = (uint64_t)((double)mem_total * pct);
    bytes -= bytes % page;
    if (bytes < page)
        bytes = page;
    if (bytes > SIZE_MAX) {
        fprintf(stderr, "%s: requested size too large\n", argv[0]);
        return 1;
    }

    const size_t TOTAL = (size_t)bytes;
    const size_t n_pages = TOTAL / page;

    const size_t DIRTY_PER_SEC = TOTAL;
    const size_t PAGES_PER_SEC = DIRTY_PER_SEC / page;

    fprintf(stderr,
            "%s: phys_ram=%llu MiB fraction=%.3f buffer=%zu MiB dirty=%zu MiB/s page=%zu\n",
            argv[0],
            (unsigned long long)(mem_total / (1024 * 1024)),
            pct,
            TOTAL / (1024 * 1024),
            DIRTY_PER_SEC / (1024 * 1024),
            page);

    char *mem = malloc(TOTAL);
    if (!mem) {
        perror("malloc");
        return 1;
    }

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
               DIRTY_PER_SEC / (1024 * 1024), elapsed_us, remaining > 0 ? remaining : 0);
    }
}
