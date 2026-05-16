# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production. Use with Kamal or build by hand:
#   docker build -t callscreen .
#   docker run -d -p 80:80 -e RAILS_MASTER_KEY=... --name callscreen callscreen

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.4.8
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# Runtime dependencies. python3 + ffmpeg are needed for the in-container
# voice cloning pipeline (Chatterbox runs out of /opt/tts_venv, see the
# tts_build stage below).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl libjemalloc2 sqlite3 \
      ffmpeg \
      python3 python3-venv && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so" \
    SOLID_QUEUE_IN_PUMA="1" \
    TZ="Europe/Rome" \
    TTS_VENV_PYTHON="/opt/tts_venv/bin/python" \
    HF_HOME="/rails/storage/.hf_cache"

# === Python TTS build stage =============================================
# Compiles + installs Chatterbox (CPU torch) into a venv that the final
# image then copies whole. Separate stage keeps build tooling (gcc, pip
# headers) out of the final image, but we still pay the disk cost for
# torch + chatterbox model code (~1.5 GB).
FROM base AS tts_build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      python3-pip python3-dev build-essential gcc git ca-certificates curl && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Kokoro pins to Python <3.13 but the base image ships Python 3.13. Use uv
# to install a standalone Python 3.12 build into /opt/python and create the
# tts venv from it. uv itself is only needed at build time.
ENV UV_PYTHON_INSTALL_DIR=/opt/python
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh && \
    uv python install 3.12 && \
    "$(uv python find 3.12)" -m venv /opt/tts_venv && \
    /opt/tts_venv/bin/python -m pip install --upgrade pip && \
    /opt/tts_venv/bin/python -m pip install --no-cache-dir \
        torch --index-url https://download.pytorch.org/whl/cpu && \
    /opt/tts_venv/bin/python -m pip install --no-cache-dir \
        chatterbox-tts "kokoro>=0.9.4" soundfile numpy

# === Ruby gem build stage ===============================================
FROM base AS ruby_build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# === Final image ========================================================
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash

# Copy built artifacts: gems, application, and the Python TTS venv
COPY --chown=rails:rails --from=ruby_build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=ruby_build /rails /rails
COPY --chown=rails:rails --from=tts_build /opt/python /opt/python
COPY --chown=rails:rails --from=tts_build /opt/tts_venv /opt/tts_venv

RUN mkdir -p /rails/storage/recordings /rails/storage/greetings \
             /rails/storage/voice_samples /rails/storage/.hf_cache && \
    chown -R rails:rails /rails/storage

USER 1000:1000

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD curl -fsS http://localhost/up || exit 1
CMD ["./bin/thrust", "./bin/rails", "server"]
