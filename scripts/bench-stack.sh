#!/usr/bin/env bash
# Experimento 03 em diante: a stack atrás do load balancer.
#
# Diferenças para o bench-container.sh (que continua válido para reproduzir o
# experimento 02): a carga entra pelo nginx na porta 9999, a API não é exposta,
# e o cpu.stat é coletado dos DOIS cgroups — o custo do LB é parte do resultado.
#
# Uso: bench-stack.sh <rig> <cpus> <workers> [duracao] [reps] [rps]
#   rig: nginx-unix | nginx-tcp | postgres | postgres-sem-persistencia
#
# BENCH_ENDPOINT=transacoes mede a ESCRITA. Fica em variável de ambiente, e
# não como argumento posicional, para não quebrar os comandos publicados no
# documento do experimento 03.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_SQLITE="$RAIZ/django/compose.bench-nginx.yml"
BASE_PG="$RAIZ/django/compose.bench-postgres.yml"
ENDPOINT="${BENCH_ENDPOINT:-extrato}"
API=rinha-bench-api01
LB=rinha-bench-nginx
PORTA="${LB_PORTA:-9999}"
CONCORRENCIA="${BENCH_CONCORRENCIA:-50}"

rig="${1:?rig}"; cpus="${2:?cpus}"; workers="${3:?workers}"
duracao="${4:-10s}"; reps="${5:-5}"; rps="${6:-}"

if [[ -n "$(git -C "$RAIZ" status --porcelain 2>/dev/null)" && "${BENCH_PERMITIR_SUJO:-0}" != "1" ]]; then
    echo "ABORTADO: árvore suja. O resultado grava o hash do commit." >&2
    exit 1
fi

case "$rig" in
    nginx-unix) compose_args=(-f "$BASE_SQLITE") ;;
    nginx-tcp)  compose_args=(-f "$BASE_SQLITE" -f "$RAIZ/django/compose.bench-nginx-tcp.yml") ;;
    postgres)   compose_args=(-f "$BASE_PG"); export BENCH_BANCO=postgres ;;
    # Mede o custo de abrir uma conexão nova a cada requisição (CONN_MAX_AGE=0,
    # que é o PADRÃO do Django).
    postgres-sem-persistencia)
        compose_args=(-f "$BASE_PG"); export DB_PERSISTENTE=0 BENCH_BANCO=postgres ;;
    *) echo "rig desconhecido: $rig" >&2; exit 1 ;;
esac

export API_CPUS="$cpus" API_WORKERS="$workers" LB_PORTA="$PORTA"
docker compose "${compose_args[@]}" up -d --build >/dev/null 2>&1
trap 'docker compose "${compose_args[@]}" down -v >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 80); do
    curl -fsS "http://127.0.0.1:$PORTA/clientes/1/extrato" >/dev/null 2>&1 && break
    sleep 0.5
done

stat_de() { docker exec "$1" awk -v k="$2" '$1==k{print $2}' /sys/fs/cgroup/cpu.stat; }

case "$ENDPOINT" in
    extrato)
        alvo=(-m GET "http://127.0.0.1:$PORTA/clientes/1/extrato") ;;
    transacoes)
        # Débito de 1 centavo, sempre no MESMO cliente: é o pior caso de
        # contenção, com toda a carga concentrada numa linha. Débito (e não
        # crédito) porque é o caminho que exercita a validação de limite dentro
        # do UPDATE condicional.
        alvo=(-m POST -H "Content-Type: application/json"
              -d '{"valor":1,"tipo":"d","descricao":"bench"}'
              "http://127.0.0.1:$PORTA/clientes/1/transacoes") ;;
    *) echo "endpoint desconhecido: $ENDPOINT" >&2; exit 1 ;;
esac

modelo="fechado(saturacao)"; taxa=()
if [[ -n "$rps" ]]; then
    taxa=(-q "$rps" --latency-correction); modelo="aberto(${rps}rps)"
fi

config="${rig}-${ENDPOINT}-cpu${cpus}-w${workers}"
[[ -n "$rps" ]] && config="${config}-${rps}rps"

echo "[$config] aquecimento (descartado)..." >&2
oha -z "$duracao" -c "$CONCORRENCIA" --no-tui --output-format quiet \
    "${taxa[@]}" "${alvo[@]}" >/dev/null 2>&1

amostras=()
for i in $(seq 1 "$reps"); do
    # Escrita muda o estado: sem resetar, o saldo desce até bater no limite e a
    # partir dali tudo vira 422 — que responde rápido e infla o rps com
    # respostas falsas. Toda repetição parte do mesmo ponto.
    if [[ "$ENDPOINT" == "transacoes" ]]; then
        docker exec "$API" python manage.py preparar_bench >/dev/null 2>&1
    fi

    a_uso=$(stat_de "$API" usage_usec);  a_thr=$(stat_de "$API" nr_throttled)
    a_thu=$(stat_de "$API" throttled_usec); a_per=$(stat_de "$API" nr_periods)
    n_uso=$(stat_de "$LB" usage_usec);   n_thr=$(stat_de "$LB" nr_throttled)
    n_thu=$(stat_de "$LB" throttled_usec);  n_per=$(stat_de "$LB" nr_periods)

    saida=$(oha -z "$duracao" -c "$CONCORRENCIA" --no-tui --output-format json \
                "${taxa[@]}" "${alvo[@]}")

    total=$(printf '%s' "$saida" | python3 -c 'import json,sys;print(sum(json.load(sys.stdin)["statusCodeDistribution"].values()))')
    erros=$(printf '%s' "$saida" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("errorDistribution",{}).get("connection error",0))')
    if [[ "$total" -eq 0 || "$erros" -gt $((total / 100 + 1)) ]]; then
        echo "ABORTADO: $erros erros de conexão para $total respostas." >&2
        exit 1
    fi

    extra=$(python3 "$RAIZ/scripts/bench-cgroup.py" "$total" \
        "$(( $(stat_de "$API" usage_usec)     - a_uso ))" \
        "$(( $(stat_de "$API" nr_throttled)   - a_thr ))" \
        "$(( $(stat_de "$API" throttled_usec) - a_thu ))" \
        "$(( $(stat_de "$API" nr_periods)     - a_per ))" \
        "$(( $(stat_de "$LB" usage_usec)      - n_uso ))" \
        "$(( $(stat_de "$LB" nr_throttled)    - n_thr ))" \
        "$(( $(stat_de "$LB" throttled_usec)  - n_thu ))" \
        "$(( $(stat_de "$LB" nr_periods)      - n_per ))")

    destino="$RAIZ/resultados/bench/${config}.rep${i}.json"
    printf '%s' "$saida" | python3 "$RAIZ/scripts/bench-metadata.py" \
        "$destino" "$config" "$ENDPOINT" "$duracao" "$modelo" "$CONCORRENCIA" "$extra" >/dev/null
    amostras+=("$destino")
    echo "[$config] rep $i/$reps" >&2
    [[ "$i" -lt "$reps" ]] && sleep "${BENCH_PAUSA:-3}"
done

python3 "$RAIZ/scripts/bench-agregar.py" \
    "$RAIZ/resultados/bench/${config}.serie.json" "${amostras[@]}"
rm -f "${amostras[@]}"
