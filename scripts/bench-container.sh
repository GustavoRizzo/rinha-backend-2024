#!/usr/bin/env bash
# Experimento 02: a API em container, sob os limites de cgroup da Rinha.
#
# Diferença do bench-local.sh: além da vazão, coleta o que só existe sob cota —
# `nr_throttled` e `throttled_usec` do cgroup, e o CPU consumido por requisição,
# que é a métrica que a cota realmente recompensa.
#
# Uso: bench-container.sh <cpus> <workers> <rede> [duracao] [reps]
#   rede: bridge | host
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_BASE="$RAIZ/django/compose.bench-sqlite.yml"
CONTAINER=rinha-bench-api01
PORTA="${API_PORTA:-8090}"
CONCORRENCIA="${BENCH_CONCORRENCIA:-50}"

cpus="${1:?cpus}"; workers="${2:?workers}"; rede="${3:-bridge}"
duracao="${4:-10s}"; reps="${5:-3}"; rps="${6:-}"

if [[ -n "$(git -C "$RAIZ" status --porcelain 2>/dev/null)" && "${BENCH_PERMITIR_SUJO:-0}" != "1" ]]; then
    echo "ABORTADO: árvore suja. O resultado grava o hash do commit." >&2
    exit 1
fi

compose_args=(-f "$COMPOSE_BASE")
[[ "$rede" == "host" ]] && compose_args+=(-f "$RAIZ/django/compose.bench-sqlite.host.yml")

export API_CPUS="$cpus" API_WORKERS="$workers" API_PORTA="$PORTA"
docker compose "${compose_args[@]}" up -d --build >/dev/null 2>&1
limpar() { docker compose "${compose_args[@]}" down >/dev/null 2>&1 || true; }
trap limpar EXIT

for _ in $(seq 1 80); do
    curl -fsS "http://127.0.0.1:$PORTA/clientes/1/extrato" >/dev/null 2>&1 && break
    sleep 0.5
done

# Campo do cpu.stat do cgroup v2, lido de dentro do container.
stat_cgroup() { docker exec "$CONTAINER" awk -v k="$1" '$1==k{print $2}' /sys/fs/cgroup/cpu.stat; }

modelo="fechado(saturacao)"; taxa=()
if [[ -n "$rps" ]]; then
    # --latency-correction compensa coordinated omission: sem ela, a latência sob
    # taxa fixa sai otimista porque o atraso da própria fila do gerador some.
    taxa=(-q "$rps" --latency-correction); modelo="aberto(${rps}rps)"
fi

config="cpu${cpus}-w${workers}-${rede}"
echo "[$config] aquecimento (descartado)..." >&2
oha -z "$duracao" -c "$CONCORRENCIA" --no-tui --output-format quiet \
    "${taxa[@]}" "http://127.0.0.1:$PORTA/clientes/1/extrato" >/dev/null 2>&1

amostras=()
for i in $(seq 1 "$reps"); do
    antes_uso=$(stat_cgroup usage_usec)
    antes_thr=$(stat_cgroup nr_throttled)
    antes_thr_us=$(stat_cgroup throttled_usec)
    antes_per=$(stat_cgroup nr_periods)

    saida=$(oha -z "$duracao" -c "$CONCORRENCIA" --no-tui --output-format json \
                "${taxa[@]}" "http://127.0.0.1:$PORTA/clientes/1/extrato")

    # ATENÇÃO: `summary.total` do oha é a DURAÇÃO em segundos, não a contagem.
    # A contagem sai da soma da distribuição de status.
    total=$(printf '%s' "$saida" | python3 -c 'import json,sys;print(sum(json.load(sys.stdin)["statusCodeDistribution"].values()))')
    delta_uso=$(( $(stat_cgroup usage_usec) - antes_uso ))
    extra=$(printf '{"cgroup":{"cpu_usado_s":%s,"cpu_us_por_request":%s,"nr_throttled":%s,"throttled_ms":%s,"nr_periods":%s,"pct_periodos_throttlados":%s}}' \
        "$(echo "scale=3; $delta_uso/1000000" | bc)" \
        "$(echo "scale=1; $delta_uso/$total" | bc)" \
        "$(( $(stat_cgroup nr_throttled) - antes_thr ))" \
        "$(echo "scale=1; ($(stat_cgroup throttled_usec) - $antes_thr_us)/1000" | bc)" \
        "$(( $(stat_cgroup nr_periods) - antes_per ))" \
        "$(echo "scale=1; ($(stat_cgroup nr_throttled) - antes_thr)*100/($(stat_cgroup nr_periods) - antes_per)" | bc)")

    destino="$RAIZ/resultados/bench/${config}.rep${i}.json"
    printf '%s' "$saida" | python3 "$RAIZ/scripts/bench-metadata.py" \
        "$destino" "$config" extrato "$duracao" "$modelo" "$CONCORRENCIA" "$extra" >/dev/null
    amostras+=("$destino")
    echo "[$config] rep $i/$reps" >&2
done

python3 "$RAIZ/scripts/bench-agregar.py" \
    "$RAIZ/resultados/bench/${config}.serie.json" "${amostras[@]}"
rm -f "${amostras[@]}"
