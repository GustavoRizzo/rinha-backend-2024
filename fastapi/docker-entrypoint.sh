#!/bin/sh
# Entrega o processo ao uvicorn.
#
# Não há passo de migração aqui, ao contrário do entrypoint do Django: o schema
# e a carga inicial vêm de `infra/sql/`, executados uma única vez pela imagem do
# Postgres na criação do volume. A conferência dos 5 clientes acontece no
# lifespan da aplicação (`app/db.py`), então uma carga divergente impede a
# subida em vez de virar "inconsistência" no relatório do Gatling.
#
# `exec` é essencial: o uvicorn vira PID 1 e recebe o SIGTERM do `docker stop`
# diretamente. Sem isso o shell segura o sinal e o container leva 10s para
# morrer em toda derrubada.
set -e

# Só no rig de benchmark: planta histórico para o extrato não medir lista vazia.
# O estado resultante é idêntico ao do `manage.py preparar_bench` do Django.
if [ "${BENCH_SEED:-0}" = "1" ]; then
    python -m app.preparar_bench
fi

# O socket precisa ser acessível ao nginx, que roda com outro usuário. O uvicorn
# não tem opção de umask (o gunicorn tem: --umask), então definimos no shell e
# ele herda.
umask 0

case "${WEB_SERVER:-uvicorn}" in
    uvicorn)
        # --loop uvloop e --http httptools são explícitos, e não deixados no
        # "auto", para que o experimento não dependa do que está instalado: se
        # o uvloop sumir do lock, queremos falha na subida e não um número 30%
        # pior sem explicação.
        exec uvicorn app.main:app \
            --uds "${UVICORN_BIND#unix:}" \
            --workers "${WEB_CONCURRENCY:-1}" \
            --loop uvloop \
            --http httptools \
            --log-level warning \
            --no-access-log
        ;;
    *)
        echo "WEB_SERVER desconhecido: ${WEB_SERVER}" >&2
        exit 1
        ;;
esac
