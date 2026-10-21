#!/bin/sh
cat > src/stats.c <<'C'
#include <math.h>
#include "stats.h"

int stats_summary(const double *xs, size_t n, struct summary *out)
{
    if (n == 0 || !out)
        return -1;
    struct summary s = {0};
    s.n = n;
    s.min = s.max = xs[0];
    double sum = 0;
    for (size_t i = 0; i < n; i++) {
        sum += xs[i];
        if (xs[i] < s.min) s.min = xs[i];
        if (xs[i] > s.max) s.max = xs[i];
    }
    s.mean = sum / n;
    double ss = 0;
    for (size_t i = 0; i < n; i++)
        ss += (xs[i] - s.mean) * (xs[i] - s.mean);
    s.sd = n > 1 ? sqrt(ss / (n - 1)) : 0;
    *out = s;
    return 0;
}
C
sed -i 's/^LDLIBS ?=$/LDLIBS ?= -lm/' Makefile
