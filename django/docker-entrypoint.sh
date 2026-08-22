#!/bin/sh
# Prepara o banco e entrega o processo ao gunicorn.
#
# `exec` no final é essencial: o gunicorn vira PID 1 e recebe o SIGTERM do
# `docker stop` diretamente. Sem isso o shell segura o sinal e o container leva
# 10s para morrer em toda derrubada.
set -e

# Com DUAS instâncias, deixar as duas rodarem `migrate` é uma corrida: ambas
# tentam criar as mesmas tabelas. Na stack completa o schema e a carga inicial
# vêm de infra/sql/, executados uma única vez pela imagem do Postgres na criação
# do volume — antes de qualquer API existir.
if [ "${DB_SKIP_MIGRATE:-0}" != "1" ]; then
    python manage.py migrate --no-input
    python manage.py loaddata clientes
fi

# Só no rig de benchmark: planta histórico para o extrato não medir lista vazia.
if [ "${BENCH_SEED:-0}" = "1" ]; then
    python manage.py preparar_bench
fi

# Falhar aqui é muito melhor que descobrir a divergência no relatório da carga.
python manage.py verificar_clientes

# GUNICORN_BIND permite `unix:/sockets/api01.sock` no lugar de host:porta.
# --umask 0 deixa o socket acessível ao nginx, que roda com outro usuário.
exec gunicorn kernel.wsgi:application \
    --bind "${GUNICORN_BIND:-0.0.0.0:${PORTA:-8080}}" \
    --umask 0 \
    --workers "${WEB_CONCURRENCY:-1}" \
    --error-logfile - --log-level warning
