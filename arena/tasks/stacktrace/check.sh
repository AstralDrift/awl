#!/bin/sh
[ "$(python3 inventory.py 2>&1)" = "{'apple': 5, 'pear': 4}" ]
