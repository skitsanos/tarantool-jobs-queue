#!/bin/sh
set -eu

mkdir -p /tmp/jobs-queue
cd /tmp/jobs-queue

if [ ! -f .test-dependencies-ready ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        tarantool-http=1:1.9.0.0-1
    rm -rf /var/lib/apt/lists/*
    touch .test-dependencies-ready
fi

exec env -u TT_APP_NAME -u TT_INSTANCE_NAME tarantool /workspace/src/server.lua
