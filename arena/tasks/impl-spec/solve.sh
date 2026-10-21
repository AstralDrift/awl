#!/bin/sh
cat > lru.c <<'C'
#include <stdlib.h>
#include <string.h>
#include "lru.h"

typedef struct node {
    char *key;
    int value;
    struct node *prev, *next; /* recency list, head = most recent */
    struct node *chain;       /* hash bucket chain */
} node;

struct lru {
    size_t cap, len, nb;
    node **buckets;
    node *head, *tail;
};

static size_t hash(const char *s)
{
    size_t h = 1469598103934665603u;
    while (*s) h = (h ^ (unsigned char)*s++) * 1099511628211u;
    return h;
}

static node **slot(const lru *c, const char *key)
{
    node **p = &c->buckets[hash(key) % c->nb];
    while (*p && strcmp((*p)->key, key)) p = &(*p)->chain;
    return p;
}

static void unlink_node(lru *c, node *n)
{
    if (n->prev) n->prev->next = n->next; else c->head = n->next;
    if (n->next) n->next->prev = n->prev; else c->tail = n->prev;
    n->prev = n->next = NULL;
}

static void push_front(lru *c, node *n)
{
    n->next = c->head;
    if (c->head) c->head->prev = n;
    c->head = n;
    if (!c->tail) c->tail = n;
}

static void remove_node(lru *c, node *n)
{
    node **p = slot(c, n->key);
    *p = n->chain;
    unlink_node(c, n);
    free(n->key);
    free(n);
    c->len--;
}

lru *lru_new(size_t capacity)
{
    if (!capacity) return NULL;
    lru *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->cap = capacity;
    c->nb = capacity * 2 + 1;
    c->buckets = calloc(c->nb, sizeof *c->buckets);
    if (!c->buckets) { free(c); return NULL; }
    return c;
}

void lru_free(lru *c)
{
    if (!c) return;
    node *n = c->head;
    while (n) {
        node *next = n->next;
        free(n->key);
        free(n);
        n = next;
    }
    free(c->buckets);
    free(c);
}

int lru_put(lru *c, const char *key, int value)
{
    node *n = *slot(c, key);
    if (n) {
        n->value = value;
        unlink_node(c, n);
        push_front(c, n);
        return 0;
    }
    n = calloc(1, sizeof *n);
    size_t kl = strlen(key) + 1;
    char *k = malloc(kl);
    if (k) memcpy(k, key, kl);
    if (!n || !k) { free(n); free(k); return -1; }
    int evicted = 0;
    if (c->len == c->cap) { remove_node(c, c->tail); evicted = 1; }
    n->key = k;
    n->value = value;
    node **p = slot(c, key);
    *p = n;
    push_front(c, n);
    c->len++;
    return evicted;
}

int lru_get(lru *c, const char *key, int *out)
{
    node *n = *slot(c, key);
    if (!n) return 0;
    *out = n->value;
    unlink_node(c, n);
    push_front(c, n);
    return 1;
}

int lru_del(lru *c, const char *key)
{
    node *n = *slot(c, key);
    if (!n) return 0;
    remove_node(c, n);
    return 1;
}

size_t lru_len(const lru *c) { return c->len; }

size_t lru_keys(const lru *c, const char **out, size_t n)
{
    size_t i = 0;
    for (node *p = c->head; p && i < n; p = p->next) out[i++] = p->key;
    return i;
}
C
