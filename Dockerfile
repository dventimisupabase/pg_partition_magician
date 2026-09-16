ARG PG_VERSION=17
FROM postgres:${PG_VERSION}

# Build a Postgres image with pg_cron (pg_partition_magician's only runtime
# dependency), pgTAP, and pg_prove for the channel test matrix.
# pg_cron pinned by SHA on main: the latest tagged releases predate reliable
# PostgreSQL 18 support, and this commit builds cleanly on 15–18.
ARG PG_CRON_SHA=61d693be59f456dbc2e26f73bf5e81e4fed7d73c
ARG PGTAP_REF=v1.3.4

# Optional: pgsql-http, needed only by the archive track (pgpm_archive/, S3 uploads via the http
# extension). Off by default so the default pg15-18 matrix images stay exactly as they were --
# no extra build step, no extra installed packages. docker-compose.yml's `archive` service passes
# WITH_PGSQL_HTTP=true.
ARG WITH_PGSQL_HTTP=false
ARG PGSQL_HTTP_REF=v1.6.2

# Optional: eBPF lock tracing, needed only by the locktrace track (bench/lock_trace.sh, issue #383).
# Off by default and installed in its OWN layer below, after the expensive pg_cron/pgTAP build, so
# turning it on neither rebuilds that layer nor adds a single package to the default pg15-18 matrix
# images. docker-compose.yml's `locktrace` service passes WITH_LOCK_TRACER=true.
ARG WITH_LOCK_TRACER=false

RUN apt-get update \
    && apt-get install -y \
        postgresql-server-dev-${PG_MAJOR} \
        build-essential \
        git \
    && git clone https://github.com/citusdata/pg_cron.git \
    && cd pg_cron && git checkout ${PG_CRON_SHA} && make && make install && cd .. && rm -rf pg_cron \
    && git clone --depth 1 --branch ${PGTAP_REF} https://github.com/theory/pgtap.git \
    && cd pgtap && make && make install && cd .. && rm -rf pgtap \
    && apt-get install -y libtap-parser-sourcehandler-pgtap-perl \
    && if [ "$WITH_PGSQL_HTTP" = "true" ]; then \
         apt-get install -y libcurl4-openssl-dev \
         && apt-mark manual libcurl4 \
         && git clone --depth 1 --branch ${PGSQL_HTTP_REF} https://github.com/pramsey/pgsql-http.git \
         && cd pgsql-http && make && make install && cd .. && rm -rf pgsql-http; \
       fi \
    && apt-get remove -y build-essential git \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# pg_cron must be preloaded; point its scheduler at the default database.
RUN echo "shared_preload_libraries = 'pg_cron'" >> /usr/share/postgresql/postgresql.conf.sample \
    && echo "cron.database_name = 'postgres'"   >> /usr/share/postgresql/postgresql.conf.sample

# eBPF lock tracing for the locktrace track (bench/lock_trace.sh, issue #383). Its own layer, on
# purpose: the RUN above builds pg_cron and pgTAP from source for every image in the matrix, and
# appending to it would invalidate that cache for all four to serve one optional track.
# bcc is the ONLY addition beyond debug symbols. This layer used to install pg-lock-tracer, four
# Python libraries it needed, and a script that patched two places in its source; all of that is gone
# (#389). bench/lock_probe.py is ~40 lines of BPF C we own, it filters in the kernel, and it needs
# nothing but bcc. It is not COPYed in either: the repo is bind-mounted at /repo by the locktrace
# compose service, so the probe is edited and run straight from the checkout.
#
# The dbgsym package is PINNED to the exact postgres already in this image, and is still required:
# LockRelationOid is exported in .dynsym, but CommitTransaction is not. A build id identifies ONE
# build, so an unpinned install that floated a point release ahead would resolve nothing and the
# probe would attach nothing -- a guard reading an empty stream and concluding the locks it watched
# for never happened. Pinning turns that into a build failure instead.
RUN if [ "$WITH_LOCK_TRACER" = "true" ]; then \
      set -e; \
      apt-get update; \
      apt-get install -y --no-install-recommends \
        python3-bpfcc \
        "postgresql-${PG_MAJOR}-dbgsym=$(dpkg-query -W -f='${Version}' "postgresql-${PG_MAJOR}")"; \
      rm -rf /var/lib/apt/lists/*; \
    fi
