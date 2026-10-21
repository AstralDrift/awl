# lru: string-keyed LRU cache

Implement `lru.c` for the API in `lru.h`. C11, no dependencies beyond libc.

## Semantics

- `lru_new(capacity)`: empty cache holding at most `capacity` entries. Returns NULL when
  `capacity == 0` or allocation fails.
- `lru_free(c)`: releases everything. `lru_free(NULL)` is a no-op.
- `lru_put(c, key, value)`: the cache owns a **copy** of `key`.
  - Existing key: replace the value and make it the most recently used. Returns 0.
  - New key with room: insert as most recently used. Returns 0.
  - New key when full: evict the **least recently used** entry first, then insert. Returns 1.
  - Returns -1 on allocation failure (cache unchanged).
- `lru_get(c, key, &out)`: when found, store the value in `*out`, make the entry the most
  recently used, return 1. Otherwise return 0 and leave `*out` untouched.
- `lru_del(c, key)`: remove the entry. Returns 1 if it existed, 0 otherwise.
- `lru_len(c)`: number of entries.
- `lru_keys(c, out, n)`: write up to `n` keys into `out`, most recently used first; returns the
  number written. The pointers stay valid until the next call that changes the cache.
  `lru_keys` does not change recency.

## Requirements

- `lru_get`, `lru_put` and `lru_del` are O(1) on average (hash table + doubly linked list).
  Caches with tens of thousands of entries must stay fast.
- No leaks and no invalid memory access (tested with `-fsanitize=address,undefined`).
- `make test` builds and runs `tests/test_lru.c`.
