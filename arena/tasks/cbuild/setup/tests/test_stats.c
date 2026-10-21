#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "stats.h"

int main(void)
{
    double xs[] = {2, 4, 4, 4, 5, 5, 7, 9};
    struct summary s;
    assert(stats_summary(xs, 8, &s) == 0);
    assert(s.n == 8);
    assert(fabs(s.mean - 5.0) < 1e-9);
    assert(s.min == 2 && s.max == 9);
    assert(stats_summary(xs, 0, &s) == -1);
    puts("test_stats ok");
    return 0;
}
