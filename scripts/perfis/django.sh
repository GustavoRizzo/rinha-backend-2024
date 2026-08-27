#!/usr/bin/env bash
# shellcheck disable=SC2034  # as variáveis são lidas por quem faz o `source`
# Perfil de bancada do projeto Django.
#
# Um perfil descreve o que muda de projeto para projeto num rig de bancada:
# quais rigs existem, quais arquivos de compose os compõem, como os containers
# se chamam e como o estado é reposto entre repetições. Tudo o mais —
# aquecimento, coleta de cpu.stat, agregação — é igual e vive em
# `bench-stack.sh`.
#
# Sourced por `bench-stack.sh`; `$RAIZ` já existe quando isto roda.

PERFIL_API=rinha-bench-api01
PERFIL_LB=rinha-bench-nginx

# Preenche `compose_args` (array) para o rig pedido, e exporta o que o compose
# daquele rig espera. Aborta em rig desconhecido: um rig que não existe neste
# projeto tem de falhar, não cair num padrão.
perfil_rig() {
    local rig="$1"
    local base_sqlite="$RAIZ/django/compose.bench-nginx.yml"
    local base_pg="$RAIZ/django/compose.bench-postgres.yml"

    case "$rig" in
        nginx-unix) compose_args=(-f "$base_sqlite") ;;
        nginx-tcp)  compose_args=(-f "$base_sqlite" -f "$RAIZ/django/compose.bench-nginx-tcp.yml") ;;
        postgres)   compose_args=(-f "$base_pg"); export BENCH_BANCO=postgres
                    PERFIL_DB=rinha-bench-db ;;
        postgres-sem-limite)
            compose_args=(-f "$base_pg" -f "$RAIZ/django/compose.bench-sem-limite.yml")
            export BENCH_BANCO=postgres
            PERFIL_DB=rinha-bench-db ;;
        # Mede o custo de abrir uma conexão nova a cada requisição
        # (CONN_MAX_AGE=0, que é o PADRÃO do Django).
        postgres-sem-persistencia)
            compose_args=(-f "$base_pg"); export DB_PERSISTENTE=0 BENCH_BANCO=postgres
            PERFIL_DB=rinha-bench-db ;;
        *) return 1 ;;
    esac
    export DB_POOL="${BENCH_POOL:-0}"
    export VIEWS_ASYNC="${BENCH_ASYNC:-0}"
}

# Repõe o histórico entre repetições de um bench de ESCRITA.
perfil_resetar() {
    docker exec "$API" python manage.py preparar_bench
}

# Sufixo do slug que identifica o servidor HTTP e suas opções. Sem ele, uma
# série de gthread sobrescreveria a de sync na mesma cota.
perfil_sufixo_servidor() {
    local sufixo="$SERVIDOR"
    [[ "$SERVIDOR" == "gunicorn-gthread" ]] && sufixo="gthread${THREADS}t"
    [[ "$SERVIDOR" == "gunicorn-sync" ]] && sufixo="sync"
    [[ "${BENCH_POOL:-0}" == "1" ]] && sufixo="${sufixo}-pool"
    # Variantes de `performance/django/07`. Só entram no slug quando diferem do
    # padrão: as séries publicadas foram todas medidas com os padrões, e mudar
    # o nome delas invalidaria os documentos que as citam.
    [[ "${DB_PREPARED:-0}" == "1" ]] && sufixo="${sufixo}-prep"
    [[ "${DB_HEALTH_CHECKS:-1}" == "0" ]] && sufixo="${sufixo}-nohc"
    # Experimento 08. Sem isto, a série async sobrescreveria a série do
    # experimento 06 — as duas são `uvicorn` na mesma cota, e só o slug as
    # distingue.
    [[ "${VIEWS_ASYNC:-0}" == "1" ]] && sufixo="${sufixo}-async"
    printf '%s' "$sufixo"
}
