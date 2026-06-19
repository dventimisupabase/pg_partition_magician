ARG PG_VERSION=17
FROM postgres:${PG_VERSION}

# Build a Postgres image with pg_cron (pg_partition_magician's only runtime
# dependency), pgTAP, and pg_prove for the channel test matrix.
# pg_cron pinned by SHA on main: the latest tagged releases predate reliable
# PostgreSQL 18 support, and this commit builds cleanly on 15–18.
ARG PG_CRON_SHA=61d693be59f456dbc2e26f73bf5e81e4fed7d73c
ARG PGTAP_REF=v1.3.4

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
    && apt-get remove -y build-essential git \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# pg_cron must be preloaded; point its scheduler at the default database.
RUN echo "shared_preload_libraries = 'pg_cron'" >> /usr/share/postgresql/postgresql.conf.sample \
    && echo "cron.database_name = 'postgres'"   >> /usr/share/postgresql/postgresql.conf.sample
