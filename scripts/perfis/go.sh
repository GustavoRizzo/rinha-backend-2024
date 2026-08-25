#!/usr/bin/env bash
# shellcheck disable=SC2034  # as variáveis são lidas por quem faz o `source`
# Perfil de bancada do projeto Go. Ver `scripts/perfis/django.sh` para o que é
# um perfil.
#
# Só existem os rigs com Postgres, como no FastAPI e no Elixir: este projeto
# nunca teve variante SQLite, e inventar uma agora só para ter paridade de rig
# mediria uma configuração que ninguém pretende usar.

PERFIL_API=rinha-bench-go-api01
PERFIL_LB=rinha-bench-go-nginx

perfil_rig() {
    local rig="$1"
    local base_pg="$RAIZ/go/compose.bench-postgres.yml"

    case "$rig" in
        # A stack da COMPETIÇÃO: nginx + 2 APIs + banco, somando 1.5 CPU e
        # 550MB. É o único rig em que a repartição da cota é uma pergunta
        # legítima, porque é o único que precisa caber no orçamento.
        producao)
            compose_args=(-f "$RAIZ/go/docker-compose.yml")
            export BENCH_BANCO=postgres
            PERFIL_API="rinha-backend-go-api01-1 rinha-backend-go-api02-1"
            PERFIL_LB=rinha-backend-go-nginx-1
            PERFIL_DB=rinha-backend-go-db-1
            PERFIL_ORCAMENTO=1 ;;
        postgres) compose_args=(-f "$base_pg"); export BENCH_BANCO=postgres
                  PERFIL_DB=rinha-bench-go-db ;;
        postgres-sem-limite)
            compose_args=(-f "$base_pg" -f "$RAIZ/go/compose.bench-sem-limite.yml")
            export BENCH_BANCO=postgres
            PERFIL_DB=rinha-bench-go-db ;;
        *) return 1 ;;
    esac
}

# O mesmo binário que serve tem o modo `preparar-bench`, então repor o estado
# não exige interpretador nem carregar código separado — é o equivalente do
# `bin/rinha eval` do Elixir e do `python -m app.preparar_bench` do FastAPI, e
# produz estado idêntico ao dos dois.
perfil_resetar() {
    docker exec "$API" /app/rinha preparar-bench
}

# `GOMAXPROCS` entra no slug SEMPRE, e não só quando difere do padrão: é a
# pergunta central do experimento (o piso de 2 do runtime, medido em
# `performance/go/00-indice.md`, seção 7.1), e um slug que omite o valor padrão
# passa a significar coisas diferentes se o padrão mudar — com o mesmo nome de
# arquivo. Foi o erro que o perfil do FastAPI teve de corrigir com
# `EXTRATO_QUERY`, e o do Elixir já nasceu com esta regra.
perfil_sufixo_servidor() {
    local sufixo="$SERVIDOR"
    sufixo="${sufixo}-p${GOMAXPROCS:-auto}"
    sufixo="${sufixo}-q${EXTRATO_QUERY:-unica}"
    [[ "${SERIALIZACAO:-manual}" != "manual" ]] && sufixo="${sufixo}-${SERIALIZACAO}"
    [[ -n "${GOMEMLIMIT:-}" ]] && sufixo="${sufixo}-mem${GOMEMLIMIT}"
    [[ -n "${DB_POOL_MAX:-}" && "${DB_POOL_MAX}" != "8" ]] && sufixo="${sufixo}-pool${DB_POOL_MAX}"
    printf '%s' "$sufixo"
}
