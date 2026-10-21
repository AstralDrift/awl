#include <math.h>
#include "stats.h"

struct summary stats_summary(const double *xs, int n)
{
    struct summary s = {0};
    s.n = n;
    if (n == 0)
        return s;
    s.min = s.max = xs[0];
    double sum = 0;
    for (int i = 0; i < n; i++) {
        sum += xs[i];
        if (xs[i] < s.min) s.min = xs[i];
        if (xs[i] > s.max) s.max = xs[i];
    }
    s.mean = sum / n;
    double ss = 0;
    for (int i = 0; i < n; i++)
        ss += (xs[i] - s.mean) * (xs[i] - s.mean);
    s.sd = n > 1 ? sqrt(ss / (n - 1)) : 0;
    return s;
}
