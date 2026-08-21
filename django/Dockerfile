# syntax=docker/dockerfile:1
#
# Imagem da API Django. Multi-stage: as dependências são resolvidas numa camada
# separada para que mudanças no código não invalidem o cache do `uv sync`.

FROM python:3.14-slim AS deps
COPY --from=ghcr.io/astral-sh/uv:latest /uv /bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PROJECT_ENVIRONMENT=/venv
WORKDIR /app
# Só os manifestos: esta camada só é reconstruída quando as dependências mudam.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

FROM python:3.14-slim AS runtime
COPY --from=deps /venv /venv
ENV PATH="/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    DJANGO_SETTINGS_MODULE=kernel.settings
WORKDIR /app
COPY . .

# Usuário sem privilégios; /app precisa ser gravável por causa do SQLite.
# O HOME precisa existir: o gunicorn 26 cria ali o socket do control server e,
# sem o diretório, loga `Permission denied` a cada boot.
RUN useradd --uid 10001 --create-home --home-dir /home/rinha rinha \
 && chown -R rinha:rinha /app /home/rinha
USER rinha

EXPOSE 8080
ENTRYPOINT ["/app/docker-entrypoint.sh"]
