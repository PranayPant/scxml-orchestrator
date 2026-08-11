# ---------------------------------------------------------------------------
# scxml_orchestrator — deps-free testing image
#
# The sole purpose of this image is to let anyone run the build/test/lint
# toolchain with ZERO local Elixir/Mix/deps installed. It is NOT a
# distribution vehicle for the library or the escript CLI (the escript runs
# with only Erlang at runtime and does not need Docker).
#
# Usage:
#   docker build -t scxml-orchestrator .
#   docker run --rm scxml-orchestrator test            # mix test
#   docker run --rm scxml-orchestrator credo           # mix credo --strict
#   docker run --rm scxml-orchestrator format          # mix format --check-formatted
#   docker run --rm scxml-orchestrator compile         # mix compile --warnings-as-errors
#   docker run --rm scxml-orchestrator shell           # iex -S mix
#   docker run --rm scxml-orchestrator escript         # mix escript.build
# ---------------------------------------------------------------------------

FROM hexpm/elixir:1.20.3-erlang-28.5.0.5-debian-bookworm-20260803-slim

# Create a non-root user for hygiene inside the container. All subsequent
# toolchain steps run as this user so Hex/deps/_build live in its home and the
# runtime `USER scxml` (below) can read/write them without permission issues.
RUN useradd --create-home --uid 1000 scxml

WORKDIR /app

# Give the non-root user ownership of the working directory so it can create
# deps/ and _build/ inside it.
RUN chown scxml:scxml /app

# Everything from here runs as the non-root user.
USER scxml

# Install the Hex and rebar package managers (into /home/scxml/.mix).
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy only the build manifest first to leverage Docker layer caching on deps.
COPY --chown=scxml:scxml mix.exs mix.lock ./

# Fetch deps (cached unless mix.exs / mix.lock change).
RUN mix deps.get

# Copy the rest of the project.
COPY --chown=scxml:scxml lib ./lib
COPY --chown=scxml:scxml test ./test
COPY --chown=scxml:scxml .formatter.exs ./.formatter.exs
COPY --chown=scxml:scxml .credo.exs ./.credo.exs

# Copy the container entrypoint, stripping any CRLF line endings that a
# Windows checkout may have introduced, and make it executable.
COPY --chown=scxml:scxml bin/run ./bin/run
RUN sed -i 's/\r$//' ./bin/run && \
    chmod +x ./bin/run

# Precompile the project (also compiles test support).
RUN mix compile

# Selected via the first positional arg (defaults to `test`).
ENTRYPOINT ["/app/bin/run"]
CMD ["test"]
