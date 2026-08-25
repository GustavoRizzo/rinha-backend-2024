#!/usr/bin/env bash
# Executa a simulação oficial da Rinha e arquiva o resultado com metadados.
#
# Sempre RECRIA a stack antes de rodar. A simulação verifica consistência de
# saldo, e um banco com estado residual de uma execução anterior faz a
# verificação acusar inconsistência que não existe.
#
# Uso: rodar-carga.sh <slug> -f <compose.yml> [-f <override.yml> ...]
#
# Os arquivos de compose são OBRIGATÓRIOS e vêm de quem chama (o justfile, via
# `just _compose`). Já foram um padrão apontando para o Django, e o resultado
# foi `just run fastapi` subir a stack do Django para medir: o slug dizia
# fastapi e o compose dizia django. Só não virou um número errado porque as duas
# stacks colidiram na porta 9999.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLUG="${1:-}"
shift || true
compose_args=("$@")

if [[ -z "$SLUG" || ${#compose_args[@]} -eq 0 ]]; then
    echo "uso: rodar-carga.sh <slug> -f <compose.yml> [-f <override.yml> ...]" >&2
    exit 1
fi

# Repassados ao compose apenas se quem chama os definiu: cada projeto tem o seu
# padrão, declarado no próprio compose. Um default aqui seria o mesmo erro de
# novo — API_SERVER=gunicorn-sync num projeto ASGI não é um padrão, é um bug.
SIMULACAO=RinhaBackendCrebitosSimulation

# `resultados/` de fora: são saídas versionadas, e uma execução anterior
# deixaria a árvore suja para a próxima.
if [[ -n "$(git -C "$RAIZ" status --porcelain -- . ':(exclude)resultados' 2>/dev/null)" && "${BENCH_PERMITIR_SUJO:-0}" != "1" ]]; then
    echo "ABORTADO: árvore suja. O resultado grava o hash do commit." >&2
    exit 1
fi

echo "==> recriando a stack (estado residual falsifica a verificação de consistência)"
docker compose "${compose_args[@]}" down -v >/dev/null 2>&1 || true
inicio=$(date +%s)
docker compose "${compose_args[@]}" up -d --build >/dev/null

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
    docker compose "${compose_args[@]}" logs --tail=40 >&2
    exit 1
fi
echo "==> stack pronta em ${pronta}s"

bash "$RAIZ/scripts/smoke-test.sh"

echo "==> resetando o estado alterado pelo smoke test"
docker compose "${compose_args[@]}" down -v >/dev/null 2>&1
docker compose "${compose_args[@]}" up -d >/dev/null
for _ in $(seq 1 20); do
    curl -fsS http://localhost:9999/clientes/1/extrato >/dev/null 2>&1 && break
    sleep 2
done

# Foto do cpu.stat ANTES da carga. O delta contra a foto de depois é o consumo
# de CPU de cada serviço durante os 4 minutos — o número que decide
# redistribuição de cota sem repetir o erro de `performance/fastapi/02`, que
# elegeu uma repartição em saturação e a viu ser recusada pela carga real.
cgroup_antes=$(mktemp)
cgroup_depois=$(mktemp)
trap 'rm -f "$cgroup_antes" "$cgroup_depois"' EXIT
bash "$RAIZ/scripts/cgroup-snapshot.sh" "${compose_args[@]}" > "$cgroup_antes"

echo "==> executando o Gatling (a simulação dura 4 minutos)"
cd "$RAIZ/gatling"
./mvnw -B -q gatling:test "-Dgatling.simulationClass=$SIMULACAO"

# Antes de qualquer coisa que demore: a stack ainda está de pé, e cada segundo
# a mais entre o fim da carga e esta leitura adiciona CPU ociosa ao delta.
bash "$RAIZ/scripts/cgroup-snapshot.sh" "${compose_args[@]}" > "$cgroup_depois"

relatorio=$(find "$RAIZ/gatling/target/gatling" -maxdepth 1 -type d -name "*simulation*" \
            | sort | tail -1)
[[ -n "$relatorio" ]] || { echo "não achei o relatório do Gatling" >&2; exit 1; }

carimbo=$(date +%Y%m%dT%H%M%S)
destino="$RAIZ/resultados/$SLUG/$carimbo"
mkdir -p "$destino"
cp -r "$relatorio/." "$destino/"

python3 "$RAIZ/scripts/metadata-carga.py" "$destino" "$SLUG" "$pronta" \
    "$cgroup_antes" "$cgroup_depois" "${compose_args[@]}"
echo "==> resultado em $destino"
