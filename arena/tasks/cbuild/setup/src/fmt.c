#include "fmt.h"

void fmt_summary(FILE *f, const struct summary *s)
{
    fprintf(f, "n=%zu mean=%.3f sd=%.3f min=%.3f max=%.3f\n", s->n, s->mean, s->sd, s->min, s->max);
}
