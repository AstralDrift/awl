#include <stdio.h>
#include <stdlib.h>
#include "stats.h"
#include "fmt.h"

int main(void)
{
    size_t cap = 64, n = 0;
    double *xs = malloc(cap * sizeof *xs);
    if (!xs)
        return 1;
    double x;
    while (scanf("%lf", &x) == 1) {
        if (n == cap) {
            cap *= 2;
            double *t = realloc(xs, cap * sizeof *xs);
            if (!t)
                return 1;
            xs = t;
        }
        xs[n++] = x;
    }
    struct summary s;
    if (stats_summary(xs, n, &s) != 0) {
        fprintf(stderr, "no input\n");
        free(xs);
        return 1;
    }
    fmt_summary(stdout, &s);
    free(xs);
    return 0;
}
