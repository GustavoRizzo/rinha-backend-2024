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
        postgres) compose_args=(-f "$base_pg"); export BENCH_BANCO=postgres
                  PERFIL_DB=rinha-bench-fa-db ;;
        postgres-sem-limite)
            compose_args=(-f "$base_pg" -f "$RAIZ/fastapi/compose.bench-sem-limite.yml")
            export BENCH_BANCO=postgres
            PERFIL_DB=rinha-bench-fa-db ;;
        *) return 1 ;;
    esac
}

perfil_resetar() {
    docker exec "$PERFIL_API" python -m app.preparar_bench
}

# As variantes deste projeto são de aplicação, não de servidor: `uvicorn` é o
# único servidor por enquanto, e o que muda entre séries é validação, forma da
# query do extrato e serializador.
#
# A forma da query entra no slug SEMPRE, e não só quando difere do padrão. O
# padrão mudou de `duas` para `unica` no experimento 01, e um slug que omite o
# valor padrão passa a significar coisas diferentes antes e depois da mudança —
# com o mesmo nome de arquivo. As séries do experimento 01 gravadas sem esse
# marcador ficam como registro histórico e não são regeneradas.
perfil_sufixo_servidor() {
    local sufixo="$SERVIDOR"
    [[ "${VALIDACAO:-manual}" != "manual" ]] && sufixo="${sufixo}-${VALIDACAO}"
    sufixo="${sufixo}-q${EXTRATO_QUERY:-unica}"
    [[ "${SERIALIZACAO:-orjson}" != "orjson" ]] && sufixo="${sufixo}-${SERIALIZACAO}"
    [[ -n "${DB_POOL_MAX:-}" && "${DB_POOL_MAX}" != "8" ]] && sufixo="${sufixo}-pool${DB_POOL_MAX}"
    printf '%s' "$sufixo"
}
