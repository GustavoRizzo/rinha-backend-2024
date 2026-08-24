#!/usr/bin/env bash
# shellcheck disable=SC2034  # as variáveis são lidas por quem faz o `source`
# Perfil de bancada do projeto FastAPI. Ver `scripts/perfis/django.sh` para o
# que é um perfil.
#
# Só existem os rigs com Postgres: este projeto nunca teve variante SQLite, e
# inventar uma agora só para ter paridade de rig mediria uma configuração que
# ninguém pretende usar.

PERFIL_API=rinha-bench-fa-api01
PERFIL_LB=rinha-bench-fa-nginx

perfil_rig() {
    local rig="$1"
    local base_pg="$RAIZ/fastapi/compose.bench-postgres.yml"

    case "$rig" in
        postgres) compose_args=(-f "$base_pg"); export BENCH_BANCO=postgres ;;
        postgres-sem-limite)
            compose_args=(-f "$base_pg" -f "$RAIZ/fastapi/compose.bench-sem-limite.yml")
            export BENCH_BANCO=postgres ;;
        *) return 1 ;;
    esac
}

perfil_resetar() {
    docker exec "$PERFIL_API" python -m app.preparar_bench
}

# As variantes deste projeto são de aplicação, não de servidor: `uvicorn` é o
# único servidor por enquanto, e o que muda entre séries é validação, forma da
# query do extrato e serializador. Entram todas no slug, senão uma série
# sobrescreve a outra.
perfil_sufixo_servidor() {
    local sufixo="$SERVIDOR"
    [[ "${VALIDACAO:-manual}" != "manual" ]] && sufixo="${sufixo}-${VALIDACAO}"
    [[ "${EXTRATO_QUERY:-duas}" != "duas" ]] && sufixo="${sufixo}-q${EXTRATO_QUERY}"
    [[ "${SERIALIZACAO:-orjson}" != "orjson" ]] && sufixo="${sufixo}-${SERIALIZACAO}"
    [[ -n "${DB_POOL_MAX:-}" && "${DB_POOL_MAX}" != "8" ]] && sufixo="${sufixo}-pool${DB_POOL_MAX}"
    printf '%s' "$sufixo"
}
