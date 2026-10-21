#!/bin/sh
cat > count.sh <<'SH'
#!/bin/bash
total=0
for f in data/*; do
  n=$(wc -l < "$f")
  total=$((total + n))
done
echo "$total"
SH
