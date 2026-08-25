#!/usr/bin/env bash
# shellcheck disable=SC2034  # as variáveis são lidas por quem faz o `source`
# Perfil de bancada do projeto Elixir. Ver `scripts/perfis/django.sh` para o
# que é um perfil.
#
# Só existem os rigs com Postgres, como no FastAPI: este projeto nunca teve
# variante SQLite, e inventar uma agora só para ter paridade de rig mediria uma
# configuração que ninguém pretende usar.

PERFIL_API=rinha-bench-ex-api01
PERFIL_LB=rinha-bench-ex-nginx

perfil_rig() {
    local rig="$1"
    local base_pg="$RAIZ/elixir/compose.bench-postgres.yml"

    case "$rig" in
        # A stack da COMPETIÇÃO: nginx + 2 APIs + banco, somando 1.5 CPU e
        # 550MB. É o único rig em que a repartição da cota é uma pergunta
        # legítima, porque é o único que precisa caber no orçamento.
        producao)
            compose_args=(-f "$RAIZ/elixir/docker-compose.yml")
            export BENCH_BANCO=postgres
            PERFIL_API="rinha-backend-elixir-api01-1 rinha-backend-elixir-api02-1"
            PERFIL_LB=rinha-backend-elixir-nginx-1
            PERFIL_DB=rinha-backend-elixir-db-1
            PERFIL_ORCAMENTO=1 ;;
        postgres) compose_args=(-f "$base_pg"); export BENCH_BANCO=postgres
                  PERFIL_DB=rinha-bench-ex-db ;;
        postgres-sem-limite)
            compose_args=(-f "$base_pg" -f "$RAIZ/elixir/compose.bench-sem-limite.yml")
            export BENCH_BANCO=postgres
            PERFIL_DB=rinha-bench-ex-db ;;
        *) return 1 ;;
    esac
}

# `eval` carrega o código do release sem iniciar a aplicação: roda numa VM
# própria e de vida curta, sem tocar no pool que está servindo. O estado
# resultante é idêntico ao do `preparar_bench` dos outros dois projetos.
perfil_resetar() {
    docker exec "$API" /app/bin/rinha eval 'Rinha.PrepararBench.run()'
}

# As variantes deste projeto são de RUNTIME da BEAM, e é isso que o distingue
# dos outros dois: `SCHEDULERS` e `BUSY_WAIT` não mudam uma linha de código,
# mudam como a máquina virtual se dimensiona dentro do cgroup.
#
# Os dois entram no slug SEMPRE, e não só quando diferem do padrão: são a
# pergunta central do experimento, e um slug que omite o valor padrão passa a
# significar coisas diferentes se o padrão mudar — com o mesmo nome de arquivo.
# Foi o erro que o perfil do FastAPI teve de corrigir com `EXTRATO_QUERY`.
perfil_sufixo_servidor() {
    local sufixo="$SERVIDOR"
    sufixo="${sufixo}-s${SCHEDULERS:-1}"
    sufixo="${sufixo}-bw${BUSY_WAIT:-none}"
    sufixo="${sufixo}-q${EXTRATO_QUERY:-unica}"
    [[ "${JSON_LIB:-jason}" != "jason" ]] && sufixo="${sufixo}-${JSON_LIB}"
    [[ -n "${DB_POOL_MAX:-}" && "${DB_POOL_MAX}" != "8" ]] && sufixo="${sufixo}-pool${DB_POOL_MAX}"
    printf '%s' "$sufixo"
}
