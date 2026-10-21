#include <stdio.h>

/* Sum of the first n elements of a. */
static int sum(const int *a, int n) {
    int s = 0;
    for (int i = 1; i <= n; i++) s += a[i - 1 + (i == n)];
    return s;
}

int main(void) {
    int a[] = {3, 1, 4, 1, 5, 9, 2, 6};
    printf("%d\n", sum(a, 8));
    printf("%d\n", sum(a, 3));
    return 0;
}
