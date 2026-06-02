# AIQ research agent image for OpenShell sandboxes.
#
# OpenShell requires a glibc-based image with iproute2. Ubuntu 24.04 (Noble)
# provides glibc 2.39, required for the openshell-sandbox supervisor.
#
# Build:
#   docker build -f Containerfile -t aiq-openshell:local .
#
# This Containerfile expects the NVIDIA AIQ source tree at the build context root.
# If building from the quickstart repo, clone AIQ first:
#   git clone https://github.com/NVIDIA/AIQ.git aiq-src
#   docker build -f Containerfile -t aiq-openshell:local aiq-src/

FROM ubuntu:24.04 AS builder

WORKDIR /app

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    tzdata \
    build-essential \
    curl \
    git \
    python3.12 \
    python3.12-dev \
    python3.12-venv \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin sh \
    && chmod +x /usr/local/bin/uv \
    && ln -sf /usr/bin/python3.12 /usr/local/bin/python \
    && ln -sf /usr/bin/python3.12 /usr/local/bin/python3

RUN uv venv /app/.venv --python /usr/local/bin/python

ENV VIRTUAL_ENV=/app/.venv
ENV PATH="/app/.venv/bin:$PATH"
ENV UV_PYTHON=/app/.venv/bin/python
ENV UV_HTTP_TIMEOUT=300

COPY pyproject.toml uv.lock ./
COPY src/ ./src/
COPY sources/ ./sources/
COPY frontends/aiq_api/ ./frontends/aiq_api/
COPY frontends/cli/ ./frontends/cli/
COPY frontends/debug/ ./frontends/debug/
COPY configs/ ./configs/
COPY deploy/entrypoint.py deploy/start_web.py ./deploy/

RUN uv sync --frozen --no-dev --no-install-workspace

RUN uv pip install --no-deps -e . \
    && uv pip install --no-deps -e ./sources/google_scholar_paper_search \
    && uv pip install --no-deps -e ./sources/tavily_web_search \
    && uv pip install --no-deps -e "./sources/knowledge_layer[all]" \
    && uv pip install --no-deps -e ./frontends/aiq_api \
    && uv pip install "psycopg[binary]>=3.0.0"

RUN uv pip install "dask[distributed]>=2024.1.0"

# ChromaDB >=1.0 uses a Rust-based SQLite backend that triggers SQLITE_CANTOPEN
# under Landlock (OpenShell sandbox). Pin to the last pure-Python release.
RUN uv pip install "chromadb>=0.5.0,<1.0.0"

RUN /app/.venv/bin/python -c "import aiq_api; import knowledge_layer; import distributed; print('Base packages OK')" \
    && test -x /app/.venv/bin/dask-scheduler && test -x /app/.venv/bin/dask-worker \
    && sed -i 's/return aiohttp.ClientSession(connector=connector)/return aiohttp.ClientSession(connector=connector, trust_env=True)/' \
       /app/.venv/lib/python3.12/site-packages/langchain_nvidia_ai_endpoints/_common.py \
    && sed -i 's/aiohttp.ClientSession()/aiohttp.ClientSession(trust_env=True)/g' \
       /app/.venv/lib/python3.12/site-packages/langchain_tavily/_utilities.py \
    && sed -i 's/aiohttp.ClientSession(timeout=timeout)/aiohttp.ClientSession(timeout=timeout, trust_env=True)/g' \
       /app/.venv/lib/python3.12/site-packages/langchain_tavily/_utilities.py

RUN chmod +x /app/deploy/start_web.py \
    && mkdir -p /app/data \
    && chown -R 1000:1000 /app

FROM builder AS dev-builder

RUN uv pip install --no-deps -e ./frontends/cli \
    && uv pip install --no-deps -e ./frontends/debug

RUN /app/.venv/bin/python -c "import aiq_api; import aiq_research_cli; import aiq_debug; import knowledge_layer; print('All packages OK')"

# -- OpenShell runtime --
FROM ubuntu:24.04 AS openshell

WORKDIR /app

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    iproute2 \
    iptables \
    python3.12 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=dev-builder /app /app

RUN ln -sf /usr/bin/python3.12 /usr/local/bin/python \
    && ln -sf /usr/bin/python3.12 /usr/local/bin/python3

RUN groupadd -g 1000660000 sandbox \
    && useradd -m -u 1000660000 -g sandbox sandbox \
    && mkdir -p /sandbox/data /app/data \
    && chown -R sandbox:sandbox /app /sandbox

USER sandbox

ENV PATH="/app/.venv/bin:$PATH"
ENV OPENSHELL=true
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV HOST=0.0.0.0
ENV PORT=8000
ENV CONFIG_FILE=/app/configs/config_web_default_llamaindex.yml
ENV NAT_JOB_STORE_DB_URL=sqlite+aiosqlite:////sandbox/data/jobs.db
ENV AIQ_CHROMA_DIR=/sandbox/data/chroma_data
ENV AIQ_CHECKPOINT_DB=/sandbox/data/checkpoints.db
ENV AIQ_SUMMARY_DB=sqlite+aiosqlite:////sandbox/data/summaries.db

EXPOSE 8000
