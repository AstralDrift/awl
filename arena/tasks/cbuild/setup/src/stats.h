#ifndef STATS_H
#define STATS_H
#include <stddef.h>

struct summary {
    size_t n;
    double mean;
    double sd; /* sample standard deviation (n - 1); 0 when n < 2 */
    double min;
    double max;
};

/* Fill *out from xs[0..n). Returns 0 on success, -1 when n == 0 or out is NULL. */
int stats_summary(const double *xs, size_t n, struct summary *out);

#endif
