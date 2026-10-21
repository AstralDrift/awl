#include <math.h>
#include <stdio.h>
#include "stats.h"

#define CHECK(c) do { if (!(c)) { printf("hidden: FAIL %s\n", #c); return 1; } } while (0)

int main(void)
{
    double xs[] = {2, 4, 4, 4, 5, 5, 7, 9};
    struct summary s = {0};
    CHECK(stats_summary(xs, 8, &s) == 0);
    CHECK(fabs(s.sd - 2.138089935299395) < 1e-9);
    double one = 3.5;
    CHECK(stats_summary(&one, 1, &s) == 0);
    CHECK(s.n == 1 && s.mean == 3.5 && s.sd == 0 && s.min == 3.5 && s.max == 3.5);
    CHECK(stats_summary(xs, 0, &s) == -1);
    CHECK(stats_summary(xs, 3, NULL) == -1);
    double neg[] = {-1, -5, -3};
    CHECK(stats_summary(neg, 3, &s) == 0);
    CHECK(s.min == -5 && s.max == -1 && s.mean == -3);
    puts("hidden ok");
    return 0;
}
