#!/usr/bin/env bash
set -euo pipefail

if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && getent hosts example.com >/dev/null 2>&1; then
  exit 0
else
  exit 1
fi
