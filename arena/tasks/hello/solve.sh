#!/bin/sh
printf '#include <stdio.h>\nint main(void){puts("hello, omarchy");return 0;}\n' > hello.c
cc -o hello hello.c && ./hello > out.txt
