# syntax=docker/dockerfile:1.7

ARG PYTHON_VERSION=3.14

FROM python:${PYTHON_VERSION}-slim AS build-base

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_PROJECT_ENVIRONMENT=/build/.venv

WORKDIR /build

RUN python -m pip install --no-cache-dir build uv

COPY pyproject.toml uv.lock README.md LICENSE /build/

FROM build-base AS deps-wheel

RUN uv sync --frozen --no-install-project --no-dev

FROM build-base AS deps-native

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    pkg-config \
    libffi-dev \
    libavcodec-dev \
    libavdevice-dev \
    libavfilter-dev \
    libavformat-dev \
    libavutil-dev \
    libswresample-dev \
    libswscale-dev \
    libxml2-dev \
    libxslt-dev \
    zlib1g-dev \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.cargo/bin:${PATH}"

RUN uv sync --frozen --no-install-project --no-dev

FROM deps-wheel AS builder-wheel

COPY mediaflow_proxy /build/mediaflow_proxy

RUN python -m build --wheel --outdir /dist \
    && uv pip install --python /build/.venv/bin/python --no-deps /dist/*.whl

FROM deps-native AS builder-native

COPY mediaflow_proxy /build/mediaflow_proxy

RUN python -m build --wheel --outdir /dist \
    && uv pip install --python /build/.venv/bin/python --no-deps /dist/*.whl

FROM builder-wheel AS builder-amd64
FROM builder-wheel AS builder-arm64
FROM builder-native AS builder-arm

ARG TARGETARCH
FROM builder-${TARGETARCH} AS builder

FROM python:${PYTHON_VERSION}-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8888 \
    WEB_CONCURRENCY=1

RUN useradd -m -u 1000 mediaflow_proxy

WORKDIR /mediaflow_proxy

COPY --from=builder --chown=mediaflow_proxy:mediaflow_proxy /build/.venv /mediaflow_proxy/.venv

USER mediaflow_proxy

ENV PATH="/mediaflow_proxy/.venv/bin:${PATH}"

EXPOSE 8888

CMD ["sh", "-c", "exec python -m gunicorn mediaflow_proxy.main:app -w \"${WEB_CONCURRENCY:-1}\" -k uvicorn.workers.UvicornWorker --bind 0.0.0.0:${PORT:-8888} --timeout 120 --max-requests 500 --max-requests-jitter 200 --access-logfile - --error-logfile - --log-level info --forwarded-allow-ips \"${FORWARDED_ALLOW_IPS:-127.0.0.1}\""]
