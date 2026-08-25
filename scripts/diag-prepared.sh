#!/usr/bin/env bash
# Decide, com medição, se os statements estão sendo REUSADOS ou REPLANEJADOS.
#
# Pergunta de origem: `performance/elixir/01`, seção 5.4. O Elixir gasta de
# 1,36x a 3,47x mais CPU de Postgres que o FastAPI, com SQL idêntico, mesmo
# schema e mesma cota. A hipótese principal é que o Postgrex não esteja
# reusando o prepared statement, fazendo o Postgres refazer Parse+Plan a cada
# requisição.
#
# O que decide: a coluna `plans` de `pg_stat_statements` contra a coluna
# `calls`.
#   plans ~= calls  -> replanejando a cada chamada (hipótese CONFIRMADA)
#   plans << calls  -> statement preparado e reusado (hipótese REFUTADA)
#
# FORA da metodologia de medição: o pg_stat_statements tem custo próprio, e
# nada daqui entra em `resultados/`. É diagnóstico, não benchmark.
#
# Uso: diag-prepared.sh <elixir|fastapi|go> [endpoint]
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJETO="${1:?uso: diag-prepared.sh <elixir|fastapi|go> [extrato|transacoes]}"
ENDPOINT="${2:-extrato}"
DURACAO="${DIAG_DURACAO:-10s}"

case "$PROJETO" in
    elixir)  DB=rinha-bench-ex-db ;;
    fastapi) DB=rinha-bench-fa-db ;;
    go)      DB=rinha-bench-go-db ;;
    *) echo "projeto sem rig de diagnóstico: $PROJETO" >&2; exit 1 ;;
esac

compose=(-f "$RAIZ/$PROJETO/compose.bench-postgres.yml"
         -f "$RAIZ/$PROJETO/compose.bench-diag.yml")

limpar() { docker compose "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap limpar EXIT
limpar

echo "==> subindo o rig de $PROJETO com pg_stat_statements"
docker compose "${compose[@]}" up -d --build >/dev/null

for _ in $(seq 1 60); do
    curl -fsS "http://127.0.0.1:9999/clientes/1/extrato" >/dev/null 2>&1 && break
    sleep 1
done
curl -fsS "http://127.0.0.1:9999/clientes/1/extrato" >/dev/null 2>&1 || {
    echo "FALHOU: a stack não respondeu" >&2
    docker compose "${compose[@]}" logs --tail=40 >&2
    exit 1
}

psql() { docker exec "$DB" psql -qtAX -U rinha -d rinha -c "$1"; }

psql "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" >/dev/null
# Aborta se a extensão não carregou: sem shared_preload_libraries ela cria a
# view mas nunca coleta nada, e a saída seria uma tabela vazia — plausível, e
# sem significado.
carregada=$(psql "SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements'")
[[ "$carregada" == "1" ]] || { echo "ABORTADO: pg_stat_statements não está carregada." >&2; exit 1; }
planejamento=$(psql "SHOW pg_stat_statements.track_planning")
[[ "$planejamento" == "on" ]] || {
    echo "ABORTADO: track_planning=$planejamento; a coluna 'plans' ficaria zerada." >&2
    exit 1
}

case "$ENDPOINT" in
    extrato)    alvo=(-m GET "http://127.0.0.1:9999/clientes/1/extrato") ;;
    transacoes) alvo=(-m POST -H "Content-Type: application/json"
                      -d '{"valor":1,"tipo":"d","descricao":"bench"}'
                      "http://127.0.0.1:9999/clientes/1/transacoes") ;;
    *) echo "endpoint desconhecido: $ENDPOINT" >&2; exit 1 ;;
esac

echo "==> aquecendo (a primeira execução prepara o que houver para preparar)"
oha -z 5s -c 50 --no-tui "${alvo[@]}" >/dev/null

echo "==> zerando as estatísticas e medindo por $DURACAO"
psql "SELECT pg_stat_statements_reset()" >/dev/null
oha -z "$DURACAO" -c 50 --no-tui "${alvo[@]}" >/dev/null

echo
echo "=== $PROJETO / $ENDPOINT ==="
docker exec "$DB" psql -X -U rinha -d rinha -c "
SELECT calls,
       plans,
       round(plans::numeric / NULLIF(calls,0), 3) AS planos_por_chamada,
       round(total_plan_time::numeric, 1)  AS ms_planejando,
       round(total_exec_time::numeric, 1)  AS ms_executando,
       round((100 * total_plan_time / NULLIF(total_plan_time + total_exec_time, 0))::numeric, 1)
           AS pct_do_tempo_planejando,
       left(regexp_replace(query, '\s+', ' ', 'g'), 46) AS query
  FROM pg_stat_statements
 WHERE query NOT ILIKE '%pg_stat_statements%'
   AND calls > 10
 ORDER BY total_plan_time + total_exec_time DESC
 LIMIT 8;"
