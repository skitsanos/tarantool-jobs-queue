FROM tarantool/tarantool:3.8.0

RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends tarantool-http=1:1.9.0.0-1 \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /app /var/lib/tarantool \
    && chown -R tarantool:tarantool /app /var/lib/tarantool

WORKDIR /app
COPY --chown=tarantool:tarantool src/ /app/

USER tarantool

ENV TARANTOOL_DATA_DIR=/var/lib/tarantool \
    TARANTOOL_WAL_MODE=fsync

ENTRYPOINT ["env", "-u", "TT_APP_NAME", "-u", "TT_INSTANCE_NAME"]
CMD ["tarantool", "/app/server.lua"]
