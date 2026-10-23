# plant a bug: a fraction like 12.5 is accepted as an integer
sed -i "s/for (s\[dot + 1 ..\]) |c| if (c != '0') return null;/for (s[dot + 1 ..]) |c| if (c != '0') break;/" src/jint.zig
grep -q "if (c != '0') break;" src/jint.zig
