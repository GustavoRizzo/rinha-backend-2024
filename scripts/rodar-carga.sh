#!/usr/bin/env bash
# Executa a simulação oficial da Rinha e arquiva o resultado com metadados.
#
# Sempre RECRIA a stack antes de rodar. A simulação verifica consistência de
# saldo, e um banco com estado residual de uma execução anterior faz a
# verificação acusar inconsistência que não existe.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${COMPOSE_ARQUIVO:-$RAIZ/django/docker-compose.yml}"
SLUG="${1:-django}"
SIMULACAO=RinhaBackendCrebitosSimulation

# `resultados/` de fora: são saídas versionadas, e uma execução anterior
# deixaria a árvore suja para a próxima.
if [[ -n "$(git -C "$RAIZ" status --porcelain -- . ':(exclude)resultados' 2>/dev/null)" && "${BENCH_PERMITIR_SUJO:-0}" != "1" ]]; then
    echo "ABORTADO: árvore suja. O resultado grava o hash do commit." >&2
    exit 1
fi

echo "==> recriando a stack (estado residual falsifica a verificação de consistência)"
docker compose -f "$COMPOSE" down -v >/dev/null 2>&1 || true
inicio=$(date +%s)
docker compose -f "$COMPOSE" up -d --build >/dev/null

# A competição dá 40s para a API responder, testando de 2 em 2 segundos.
pronta=0
for _ in $(seq 1 20); do
    if curl -fsS http://localhost:9999/clientes/1/extrato >/dev/null 2>&1; then
        pronta=$(( $(date +%s) - inicio )); break
    fi
    sleep 2
done
if [[ "$pronta" -eq 0 ]]; then
    echo "FALHOU: a API não respondeu em 40s (limite da competição)" >&2
    docker compose -f "$COMPOSE" logs --tail=40 >&2
    exit 1
fi
echo "==> stack pronta em ${pronta}s"

bash "$RAIZ/scripts/smoke-test.sh"

echo "==> resetando o estado alterado pelo smoke test"
docker compose -f "$COMPOSE" down -v >/dev/null 2>&1
docker compose -f "$COMPOSE" up -d >/dev/null
for _ in $(seq 1 20); do
    curl -fsS http://localhost:9999/clientes/1/extrato >/dev/null 2>&1 && break
    sleep 2
done

echo "==> executando o Gatling (a simulação dura 4 minutos)"
cd "$RAIZ/gatling"
./mvnw -B -q gatling:test "-Dgatling.simulationClass=$SIMULACAO"

relatorio=$(find "$RAIZ/gatling/target/gatling" -maxdepth 1 -type d -name "*simulation*" \
            | sort | tail -1)
[[ -n "$relatorio" ]] || { echo "não achei o relatório do Gatling" >&2; exit 1; }

carimbo=$(date +%Y%m%dT%H%M%S)
destino="$RAIZ/resultados/$SLUG/$carimbo"
mkdir -p "$destino"
cp -r "$relatorio/." "$destino/"

python3 "$RAIZ/scripts/metadata-carga.py" "$destino" "$SLUG" "$COMPOSE" "$pronta"
echo "==> resultado em $destino"
