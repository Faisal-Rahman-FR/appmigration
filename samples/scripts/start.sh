#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
docker info --format '{{.OSType}}'
if [ ! -f .local/demo.env ]; then node scripts/initialize.mjs "${1:-.env.sample}"; fi
docker compose --env-file .local/demo.env up --build -d
docker compose --env-file .local/demo.env ps
