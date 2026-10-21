#!/bin/sh
sed -i 's/stock.get(name) + qty/stock.get(name, 0) + qty/' inventory.py
