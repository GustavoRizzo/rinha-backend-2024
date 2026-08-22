#!/bin/sh
# Prepara o banco e entrega o processo ao gunicorn.
#
# `exec` no final é essencial: o gunicorn vira PID 1 e recebe o SIGTERM do
# `docker stop` diretamente. Sem isso o shell segura o sinal e o container leva
# 10s para morrer em toda derrubada.
set -e

python manage.py migrate --no-input
python manage.py loaddata clientes

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
