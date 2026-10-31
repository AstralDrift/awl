#!/bin/sh
# The migrate task's project, plus tools/open-ticket.sh from setup/.
cp -r "$TASK/../migrate/setup/." . && rm -rf app/__pycache__ app/services/__pycache__
