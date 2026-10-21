#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "lru.h"

int main(void)
{
    lru *c = lru_new(2);
    assert(c);
    int v = 0;
    assert(lru_put(c, "a", 1) == 0);
    assert(lru_put(c, "b", 2) == 0);
    assert(lru_get(c, "a", &v) == 1 && v == 1); /* a is now most recent */
    assert(lru_put(c, "c", 3) == 1);             /* evicts b */
    assert(lru_get(c, "b", &v) == 0);
    assert(lru_len(c) == 2);
    lru_free(c);
    assert(lru_new(0) == NULL);
    puts("test_lru ok");
    return 0;
}
