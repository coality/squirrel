#!/bin/sh
#
# file-deploy launcher.
#
# A thin wrapper whose only job is to pick the Python interpreter and hand off
# to deploy.py, which is the whole program.
#
#   file-deploy.sh [--config FILE] [--dry-run] [--once] [--check]
#                  [--rediscover] [--debug] [--verbose]
#
# Interpreter selection: $FILE_DEPLOY_PYTHON, else python3 on PATH.

set -u

case $0 in
    */*) dir=${0%/*} ;;
    *)   dir=. ;;
esac
dir=$(CDPATH= cd -- "$dir" && pwd)
py=${FILE_DEPLOY_PYTHON:-python3}

if ! command -v "$py" >/dev/null 2>&1; then
    echo "python3 interpreter not found: '$py'" >&2
    exit 1
fi

exec "$py" "$dir/deploy.py" "$@"
