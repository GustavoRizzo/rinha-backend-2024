#!/usr/bin/env bash
# Gera infra/sql/{ddl,dml}.sql a partir do que o Django e a fixture definem.
#
# Por que gerar em vez de escrever à mão: com DUAS instâncias de API subindo ao
# mesmo tempo, deixá-las rodar `migrate` é uma corrida — as duas tentam criar as
# mesmas tabelas. A imagem do Postgres executa `/docker-entrypoint-initdb.d/*.sql`
# uma única vez, na criação do volume, antes de qualquer API existir.
#
# Gerando, o modelo Django continua sendo a única fonte da verdade e o SQL nunca
# diverge em silêncio.
#
# O DDL vem do schema real (pg_dump); o DML vem da FIXTURE, não do banco — um
# dump de dados carrega o estado do momento, incluindo saldos alterados por um
# smoke test.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINO="$RAIZ/infra/sql"
DB="${DB_CONTAINER:-rinha-bench-db}"

docker exec "$DB" pg_isready -h 127.0.0.1 -U rinha -d rinha >/dev/null

{
    echo "-- GERADO por scripts/gerar-sql.sh — não edite à mão."
    echo "-- Fonte da verdade: as migrations do Django em django/crebitos/migrations/."
    echo "-- Regenere com: just gen-sql"
    echo
    docker exec "$DB" pg_dump -U rinha -d rinha --schema-only --no-owner --no-privileges
    echo
    echo "-- Marca as migrations como aplicadas: sem isto o Django tentaria criar"
    echo "-- tabelas que já existem."
    docker exec "$DB" pg_dump -U rinha -d rinha --data-only --no-owner --table=django_migrations
} > "$DESTINO/ddl.sql"

python3 "$RAIZ/scripts/gerar-dml.py"

echo "gerado:"
wc -l "$DESTINO/ddl.sql" "$DESTINO/dml.sql"
