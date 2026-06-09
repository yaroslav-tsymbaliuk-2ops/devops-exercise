# syntax=docker/dockerfile:1.7
# -----------------------------------------------------------------------------
# YellowPad api-gateway — hardened production image.
#
# Hardening vs. the original single-stage image:
#   * Multi-stage build (builder → runtime venv) → no compilers in final image.
#   * Pinned, digest-aware base image (python:3.11-slim-bookworm).
#   * Non-root user (appuser, uid/gid 10001).
#   * Minimal runtime apt deps (libpq5 only; build deps live in builder stage).
#   * .dockerignore shrinks build context.
#   * HEALTHCHECK using the existing /healthz endpoint.
#   * OCI image labels for provenance.
# -----------------------------------------------------------------------------

# Pin to slim-bookworm; replace tag with @sha256:... in CI for full reproducibility.
ARG PYTHON_IMAGE=python:3.11.15-slim-bookworm

# --- builder ------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY requirements.txt .

RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --upgrade pip \
 && /opt/venv/bin/pip install -r requirements.txt

# --- runtime ------------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS runtime

ARG APP_VERSION=1.0.0
LABEL org.opencontainers.image.title="yellowpad-api-gateway" \
      org.opencontainers.image.description="YellowPad API gateway (FastAPI)" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/yellowpadaifunc/devops-exercise" \
      org.opencontainers.image.licenses="Proprietary"

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# libpq5 is the only runtime native dep psycopg2-binary actually needs; curl for HEALTHCHECK.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libpq5 \
        curl \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 appuser \
 && useradd  --system --uid 10001 --gid appuser --home /app --shell /usr/sbin/nologin appuser

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --chown=appuser:appuser app.py .

USER appuser
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8000/healthz || exit 1

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
