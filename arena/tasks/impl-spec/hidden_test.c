#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "lru.h"

static int fails;
#define CHECK(c) do { if (!(c)) { printf("hidden: FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static void keys_are(lru *c, const char *want)
{
    const char *k[16];
    size_t n = lru_keys(c, k, 16);
    char got[256] = "";
    for (size_t i = 0; i < n; i++) {
        if (i) strcat(got, ",");
        strcat(got, k[i]);
    }
    if (strcmp(got, want)) { printf("hidden: keys %s, want %s\n", got, want); fails++; }
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "perf")) {
        size_t cap = 20000;
        lru *c = lru_new(cap);
        char key[32];
        clock_t t0 = clock();
        for (int i = 0; i < 300000; i++) {
            snprintf(key, sizeof key, "k%ld", (long)i * 7919 % 40000);
            int v;
            if (!lru_get(c, key, &v)) lru_put(c, key, i);
        }
        double s = (double)(clock() - t0) / CLOCKS_PER_SEC;
        CHECK(lru_len(c) == cap);
        lru_free(c);
        if (s > 2.0) { printf("hidden: too slow (%.1fs for 300k ops at 20k entries), not O(1)\n", s); fails++; }
        return fails != 0;
    }
    lru *c = lru_new(3);
    int v = -7;
    CHECK(lru_get(c, "x", &v) == 0 && v == -7);
    CHECK(lru_del(c, "x") == 0);

    char buf[8];
    strcpy(buf, "a");
    CHECK(lru_put(c, buf, 1) == 0);
    strcpy(buf, "zz"); /* cache must have copied the key */
    CHECK(lru_get(c, "a", &v) == 1 && v == 1);
    CHECK(lru_put(c, "b", 2) == 0);
    CHECK(lru_put(c, "c", 3) == 0);
    keys_are(c, "c,b,a");
    CHECK(lru_put(c, "a", 10) == 0); /* update moves to front, no eviction */
    keys_are(c, "a,c,b");
    CHECK(lru_len(c) == 3);
    CHECK(lru_put(c, "d", 4) == 1); /* evicts b */
    keys_are(c, "d,a,c");
    CHECK(lru_get(c, "c", &v) == 1 && v == 3);
    keys_are(c, "c,d,a");
    const char *k1[1];
    CHECK(lru_keys(c, k1, 1) == 1 && !strcmp(k1[0], "c"));
    keys_are(c, "c,d,a"); /* keys does not change recency */
    CHECK(lru_del(c, "d") == 1);
    CHECK(lru_del(c, "d") == 0);
    keys_are(c, "c,a");
    CHECK(lru_len(c) == 2);
    CHECK(lru_put(c, "e", 5) == 0); /* room after delete: no eviction */
    CHECK(lru_put(c, "f", 6) == 1); /* evicts a */
    CHECK(lru_get(c, "a", &v) == 0);
    keys_are(c, "f,e,c");
    CHECK(lru_del(c, "c") == 1 && lru_del(c, "e") == 1 && lru_del(c, "f") == 1);
    CHECK(lru_len(c) == 0);
    keys_are(c, "");
    CHECK(lru_put(c, "g", 7) == 0);
    keys_are(c, "g");
    lru_free(c);
    lru_free(NULL);

    lru *one = lru_new(1); /* capacity 1 */
    CHECK(lru_put(one, "p", 1) == 0);
    CHECK(lru_put(one, "q", 2) == 1);
    CHECK(lru_get(one, "p", &v) == 0 && lru_get(one, "q", &v) == 1 && v == 2);
    lru_free(one);

    /* many keys, long keys, churn */
    lru *big = lru_new(500);
    char key[300];
    for (int i = 0; i < 5000; i++) {
        memset(key, 'x', 200);
        snprintf(key + 200, 50, "%d", i);
        lru_put(big, key, i);
        if (i % 3 == 0) lru_del(big, key);
    }
    CHECK(lru_len(big) == 500);
    lru_free(big);
    if (!fails) puts("hidden ok");
    return fails != 0;
}
