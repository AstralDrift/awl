CC ?= cc
CFLAGS ?= -O2 -Wall -Werror -std=c11
LDLIBS ?=

OBJ = src/stats.o src/fmt.o

all: statcli

statcli: src/main.o $(OBJ)
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

tests/test_stats: tests/test_stats.o $(OBJ)
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.c
	$(CC) $(CFLAGS) -Isrc -c -o $@ $<

test: statcli tests/test_stats
	./tests/test_stats
	printf '1\n2\n3\n4\n' | ./statcli | grep -q 'n=4 mean=2.500 sd=1.291'
	@echo all tests passed

clean:
	rm -f statcli tests/test_stats src/*.o tests/*.o

.PHONY: all test clean
