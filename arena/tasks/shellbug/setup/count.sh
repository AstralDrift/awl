#!/bin/bash
# Print the total number of lines in all files under data/.
total=0
for f in $(ls data); do
  n=$(wc -l < data/$f)
  total=$((total + n))
done
echo "$total"
