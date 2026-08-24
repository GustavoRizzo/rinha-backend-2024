# syntax=docker/dockerfile:1
#
# Imagem da API FastAPI. Mesma estrutura da imagem do Django (multi-stage, `uv`,
# usuário sem privilégios) de propósito: se as imagens diferissem em base, em
# gerenciador de pacotes ou em usuário, a diferença medida entre os dois
# projetos não seria atribuível só ao framework.

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
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY . .

# /sockets guarda o socket Unix compartilhado com o nginx. Precisa existir na
# imagem e pertencer ao usuário: um volume nomeado herda a posse do diretório da
# imagem na primeira criação — se não existir, o Docker o cria como root e o
# uvicorn não consegue escrever nele.
RUN useradd --uid 10001 --create-home --home-dir /home/rinha rinha \
 && mkdir -p /sockets \
 && chown -R rinha:rinha /app /home/rinha /sockets
USER rinha

EXPOSE 8080
ENTRYPOINT ["/app/docker-entrypoint.sh"]
