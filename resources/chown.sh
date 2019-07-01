#!/bin/bash
set -x
set -e
docker run -i --rm --entrypoint=/bin/sh -v $(pwd):/app alpine:3.9 -c 'chown -R 1000:1000 /app'
