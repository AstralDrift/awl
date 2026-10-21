#!/bin/sh
sed -i 's/normalize("NFC", text)/normalize("NFKD", text)/' core/_impl/fold.py
