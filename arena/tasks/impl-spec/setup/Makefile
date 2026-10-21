CC ?= cc
CFLAGS ?= -O2 -g -Wall -Wextra -std=c11

tests/test_lru: tests/test_lru.c lru.c lru.h
	$(CC) $(CFLAGS) -I. -o $@ tests/test_lru.c lru.c

test: tests/test_lru
	./tests/test_lru

clean:
	rm -f tests/test_lru

.PHONY: test clean
