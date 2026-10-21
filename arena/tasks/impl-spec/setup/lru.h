#ifndef LRU_H
#define LRU_H
#include <stddef.h>

/* String-keyed LRU cache of int values. See SPEC.md. */
typedef struct lru lru;

lru *lru_new(size_t capacity);
void lru_free(lru *c);
int lru_put(lru *c, const char *key, int value);
int lru_get(lru *c, const char *key, int *out);
int lru_del(lru *c, const char *key);
size_t lru_len(const lru *c);
size_t lru_keys(const lru *c, const char **out, size_t n);

#endif
