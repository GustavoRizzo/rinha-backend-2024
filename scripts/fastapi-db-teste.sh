#!/usr/bin/env bash
# Sobe (ou derruba) um Postgres descartável para os testes do projeto FastAPI.
#
# Porta 5433 de propósito: 5432 é a da stack de produção, e um teste que
# encontra o banco errado de pé produz falha por um motivo que não é o dele.
#
# O schema e a carga inicial vêm de infra/sql/ — os MESMOS arquivos que as duas
# stacks usam. Um schema só para o teste testaria outra coisa.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOME=rinha-fastapi-db-teste
PORTA="${FA_DB_PORTA:-5433}"

case "${1:-up}" in
    up)
        if [ -n "$(docker ps -q -f "name=^${NOME}$")" ]; then
            echo "já de pé: ${NOME} na porta ${PORTA}"
            exit 0
        fi
        docker rm -f "$NOME" >/dev/null 2>&1 || true
        docker run -d --name "$NOME" \
            -e POSTGRES_DB=rinha -e POSTGRES_USER=rinha -e POSTGRES_PASSWORD=rinha \
            -p "${PORTA}:5432" \
            -v "${RAIZ}/infra/sql:/docker-entrypoint-initdb.d:ro" \
            postgres:18-alpine >/dev/null

        echo "aguardando o banco..."
        for _ in $(seq 1 30); do
            # -h 127.0.0.1 de propósito: durante a inicialização a imagem sobe
            # um servidor TEMPORÁRIO que escuta apenas no socket Unix, e sem o
            # -h o pg_isready aprova esse servidor provisório.
            if docker exec "$NOME" pg_isready -h 127.0.0.1 -U rinha -d rinha >/dev/null 2>&1; then
                echo "pronto: ${NOME} na porta ${PORTA}"
                exit 0
            fi
            sleep 1
        done
        echo "FALHOU: o banco de teste não ficou pronto em 30s" >&2
        docker logs --tail=30 "$NOME" >&2
        exit 1
        ;;
    down)
        docker rm -f "$NOME" >/dev/null 2>&1 || true
        echo "removido: ${NOME}"
        ;;
    *)
        echo "uso: $0 [up|down]" >&2
        exit 1
        ;;
esac
