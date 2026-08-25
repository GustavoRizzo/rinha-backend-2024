#!/usr/bin/env bash
# Roda o ExUnit do projeto Elixir contra um Postgres descartável.
#
# Diferença para `fastapi-db-teste.sh`, e o motivo dela: o FastAPI roda a suíte
# no HOST, porque `uv` e Python já estão instalados. Elixir e Erlang não estão,
# e exigir que estejam faria `just ex-test` falhar numa máquina limpa. Então a
# suíte roda DENTRO da mesma imagem que o Dockerfile usa para compilar —
# mesmíssimas versões de Elixir e de OTP que a stack medida.
#
# Consequência prática: banco e testes ficam numa rede Docker própria e o banco
# NÃO publica porta no host. Não há porta para conflitar com a stack de produção.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDE=rinha-elixir-teste
DB=rinha-elixir-db-teste
IMAGEM=hexpm/elixir:1.18.4-erlang-27.3.4-alpine-3.21.3

derrubar() {
    docker rm -f "$DB" >/dev/null 2>&1 || true
    docker network rm "$REDE" >/dev/null 2>&1 || true
}

subir_banco() {
    docker network create "$REDE" >/dev/null 2>&1 || true
    docker rm -f "$DB" >/dev/null 2>&1 || true
    # O schema e a carga inicial vêm de infra/sql/ — os MESMOS arquivos que as
    # três stacks usam. Um schema só para o teste testaria outra coisa.
    docker run -d --name "$DB" --network "$REDE" --network-alias db \
        -e POSTGRES_DB=rinha -e POSTGRES_USER=rinha -e POSTGRES_PASSWORD=rinha \
        -v "${RAIZ}/infra/sql:/docker-entrypoint-initdb.d:ro" \
        postgres:18-alpine >/dev/null

    for _ in $(seq 1 30); do
        # -h 127.0.0.1 de propósito: durante a inicialização a imagem sobe um
        # servidor TEMPORÁRIO que escuta apenas no socket Unix, e sem o -h o
        # pg_isready aprova esse servidor provisório.
        if docker exec "$DB" pg_isready -h 127.0.0.1 -U rinha -d rinha >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "FALHOU: o banco de teste não ficou pronto em 30s" >&2
    docker logs --tail=30 "$DB" >&2
    return 1
}

case "${1:-test}" in
    down) derrubar; echo "removido: ${DB}"; exit 0 ;;
    test) shift || true ;;
    *) echo "uso: $0 [test [args do mix test...] | down]" >&2; exit 1 ;;
esac

trap derrubar EXIT
subir_banco

# `--no-start`: a suíte NÃO sobe a árvore de supervisão da aplicação. O que ela
# exercita é o roteador e o domínio, e subir o Bandit exigiria um socket Unix em
# /sockets — um diretório que só existe na imagem de produção. O pool do
# Postgres, que os testes de fato usam, é iniciado por `test/test_helper.exs`
# com o mesmo nome registrado da produção (`Rinha.DB`).
#
# `_build` e `deps` ficam no diretório do projeto (montado), então a segunda
# execução não recompila as dependências. `HOME=/tmp` porque o usuário do host
# não existe dentro da imagem e o Mix precisa de um lugar para o Hex.
docker run --rm --network "$REDE" \
    -v "${RAIZ}/elixir":/src -w /src \
    -u "$(id -u):$(id -g)" -e HOME=/tmp \
    -e MIX_ENV=test -e DB_HOST=db \
    "$IMAGEM" \
    sh -c "mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null \
        && mix deps.get >/dev/null && mix test --no-start $*"
