#!/usr/bin/env bash
# Roda a suíte `go test` do projeto Go contra um Postgres descartável.
#
# Mesmo desenho de `elixir-teste.sh`, e pelo mesmo motivo: não há Go instalado
# no host, e exigir que houvesse faria `just go-test` falhar numa máquina limpa.
# A suíte roda DENTRO da mesma imagem que o Dockerfile usa para compilar —
# mesmíssima versão de Go que a stack medida.
#
# Consequência prática: banco e testes ficam numa rede Docker própria e o banco
# NÃO publica porta no host. Não há porta para conflitar com a stack de produção.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDE=rinha-go-teste
DB=rinha-go-db-teste
IMAGEM=golang:1.27-alpine
# Volume nomeado para os caches do Go. Sem ele, cada execução rebaixa as
# dependências e recompila a stdlib — ~40s a mais por rodada.
CACHE=rinha-go-cache

derrubar() {
    docker rm -f "$DB" >/dev/null 2>&1 || true
    docker network rm "$REDE" >/dev/null 2>&1 || true
}

preparar_cache() {
    docker volume create "$CACHE" >/dev/null
    # O container de teste roda com o UID do host; o volume nasce pertencendo ao
    # root e o Go não conseguiria escrever nele.
    docker run --rm -v "${CACHE}":/gocache alpine \
        sh -c "mkdir -p /gocache/build /gocache/mod && chown -R $(id -u):$(id -g) /gocache"
}

subir_banco() {
    docker network create "$REDE" >/dev/null 2>&1 || true
    docker rm -f "$DB" >/dev/null 2>&1 || true
    # O schema e a carga inicial vêm de infra/sql/ — os MESMOS arquivos que as
    # quatro stacks usam. Um schema só para o teste testaria outra coisa.
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
    *) echo "uso: $0 [test [args do go test...] | down]" >&2; exit 1 ;;
esac

trap derrubar EXIT
preparar_cache
subir_banco

# `-count=1` desliga o cache de RESULTADO de teste: a suíte depende de um banco
# externo, então um "ok (cached)" seria uma aprovação sem execução — exatamente
# o modo de falha que o `CLAUDE.md` proíbe (número plausível em vez de erro).
#
# `-p 1` mantém os pacotes em série. Hoje há um só, mas os testes disputam as
# mesmas 5 linhas de `crebitos_cliente`, e dois pacotes em paralelo se
# sabotariam em silêncio.
docker run --rm --network "$REDE" \
    -v "${RAIZ}/go":/src -w /src \
    -v "${CACHE}":/gocache \
    -u "$(id -u):$(id -g)" -e HOME=/tmp \
    -e GOCACHE=/gocache/build -e GOMODCACHE=/gocache/mod \
    -e DB_HOST=db -e VERIFICAR_CLIENTES=0 \
    "$IMAGEM" \
    go test -count=1 -p 1 "$@" ./...
