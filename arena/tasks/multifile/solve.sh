#!/bin/sh
sed -i 's/^EUR ,2,Euro$/EUR,2,Euro/' billing/data/currencies.csv
sed -i 's/            table\[code\] = (int(minor), name)/            table[code.strip()] = (int(minor), name.strip())/' billing/currency.py
