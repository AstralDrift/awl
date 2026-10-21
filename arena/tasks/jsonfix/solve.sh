#!/bin/sh
sed -i 's/"b.local",]/"b.local"]/; s/"timeout_ms": 2500,/"timeout_ms": 2500/' settings.json
