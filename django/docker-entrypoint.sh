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

# VIEWS_ASYNC só faz sentido sob ASGI: em WSGI o Django envolveria as views
# `async def` em `async_to_sync` e a medição diria o contrário do que pretende.
# Abortar aqui, e não deixar rodar, porque essa combinação produz um número
# plausível em vez de um erro — o modo de falha que já custou três bugs a este
# projeto.
if [ "${VIEWS_ASYNC:-0}" = "1" ] && [ "${WEB_SERVER:-gunicorn-sync}" != "uvicorn" ]; then
    echo "ABORTADO: VIEWS_ASYNC=1 exige WEB_SERVER=uvicorn (recebido: ${WEB_SERVER:-gunicorn-sync})" >&2
    exit 1
fi

# Servidor escolhido por ambiente, para o comparativo do experimento 06.
# GUNICORN_BIND aceita `unix:/sockets/api01.sock` no lugar de host:porta.
#
# umask 0 é essencial nos três casos: o socket precisa ser acessível ao nginx,
# que roda com outro usuário. O gunicorn tem a opção --umask; o uvicorn não,
# então definimos no shell e ele herda.
umask 0

case "${WEB_SERVER:-gunicorn-sync}" in
    gunicorn-sync)
        exec gunicorn kernel.wsgi:application \
            --bind "${GUNICORN_BIND:-0.0.0.0:${PORTA:-8080}}" \
            --umask 0 \
            --workers "${WEB_CONCURRENCY:-1}" \
            --error-logfile - --log-level warning
        ;;
    gunicorn-gthread)
        # Pool de threads de tamanho FIXO. Diferença crucial para o runserver do
        # experimento 01, que criava uma thread por conexão sem limite e
        # colapsava por disputa de GIL. Este worker também faz keep-alive, que o
        # sync recusa (sync.py:177, resp.force_close).
        exec gunicorn kernel.wsgi:application \
            --bind "${GUNICORN_BIND:-0.0.0.0:${PORTA:-8080}}" \
            --umask 0 \
            --worker-class gthread \
            --workers "${WEB_CONCURRENCY:-1}" \
            --threads "${WEB_THREADS:-4}" \
            --error-logfile - --log-level warning
        ;;
    uvicorn)
        # ASGI. Com VIEWS_ASYNC=0 (padrão) as views são SÍNCRONAS e o Django as
        # executa num pool de threads — o async é do servidor HTTP, não da
        # aplicação; foi essa a hipótese do experimento 06. Com VIEWS_ASYNC=1 as
        # views são `async def` e falam com o banco pelo pool assíncrono do
        # psycopg: experimento 08.
        caminho_socket=${GUNICORN_BIND#unix:}
        exec uvicorn kernel.asgi:application \
            --uds "$caminho_socket" \
            --workers "${WEB_CONCURRENCY:-1}" \
            --log-level warning \
            --no-access-log
        ;;
    *)
        echo "WEB_SERVER desconhecido: ${WEB_SERVER}" >&2
        exit 1
        ;;
esac
