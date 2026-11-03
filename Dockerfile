# syntax=docker/dockerfile:1

# Keep RUBY_VERSION in step with .ruby-version.
ARG RUBY_VERSION=4.0.9
FROM docker.io/library/ruby:$RUBY_VERSION-slim-trixie AS base

WORKDIR /app

ENV BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    BUNDLE_GEMFILE="/app/Gemfile"


# Compilers and git, for the native gems and the github sources.
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock mailscore.gemspec ./
COPY lib/mailscore/version.rb lib/mailscore/

# The committed lock pins the versions for x86_64 and aarch64 Linux. Install
# frozen, without the development and test gems, and audit the lock with a
# bundle-audit of its own, kept out of the bundle that ships. bundle-audit
# fetches its advisory database, so this needs network.
RUN bundle install && \
    gem install --no-document --install-dir /tmp/audit bundler-audit && \
    GEM_HOME=/tmp/audit GEM_PATH=/tmp/audit /tmp/audit/bin/bundle-audit check --update && \
    rm -rf /tmp/audit ~/.bundle ~/.local/share/ruby-advisory-db "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git


# Runtime only: no compilers, no git.
FROM base

LABEL org.opencontainers.image.title="mailscore" \
      org.opencontainers.image.description="A boring spam scorer for mail servers." \
      org.opencontainers.image.source="https://github.com/mailpiece/mailscore" \
      org.opencontainers.image.licenses="MIT"

# Debian's pending security patches, which the base tag can lag behind.
RUN apt-get update -qq && \
    apt-get upgrade -y --no-install-recommends && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

RUN groupadd --system --gid 1000 mailscore && \
    useradd --system --uid 1000 --gid 1000 --home-dir /data --no-create-home --shell /usr/sbin/nologin mailscore && \
    mkdir /data && chown mailscore:mailscore /data

COPY --chmod=755 <<'EOF' /usr/local/bin/mailscore
#!/bin/sh
exec ruby -rbundler/setup /app/exe/mailscore "$@"
EOF

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY . .

# Strip the setuid and setgid bits off mount, su and the rest as the last
# root step, so the strip covers whatever a step above installed.
RUN find / -xdev -type f -perm /06000 -exec chmod a-s {} +

USER 1000:1000

# The database and its WAL live in /data. Request bodies over 112 KB and
# SQLite's temporary files go to /tmp, so run with --read-only --tmpfs /tmp.
VOLUME /data

EXPOSE 8080

# Assumes the default port: 8080; override the health check if the config sets another.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["ruby", "-rnet/http", "-e", "exit Net::HTTP.get_response(URI('http://127.0.0.1:8080/ping')).is_a?(Net::HTTPOK)"]

# Reads /etc/mailscore.yml when one is mounted, and runs on the defaults otherwise.
ENTRYPOINT ["mailscore"]
