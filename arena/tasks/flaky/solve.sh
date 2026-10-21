#!/bin/sh
sed -i 's/", ".join(set(tags))/", ".join(sorted(set(tags)))/; s/datetime.datetime.utcnow().date()/datetime.date.today()/' report/render.py
