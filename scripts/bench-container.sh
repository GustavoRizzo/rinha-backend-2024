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

if [[ -n "$(git -C "$RAIZ" status --porcelain -- . ':(exclude)resultados' 2>/dev/null)" && "${BENCH_PERMITIR_SUJO:-0}" != "1" ]]; then
    echo "ABORTADO: árvore suja. O resultado grava o hash do commit." >&2
    exit 1
fi

compose_args=(-f "$COMPOSE_BASE")
[[ "$rede" == "host" ]] && compose_args+=(-f "$RAIZ/django/compose.bench-sqlite.host.yml")

export API_CPUS="$cpus" API_WORKERS="$workers" API_PORTA="$PORTA"
# stderr preservado: com `2>&1 >/dev/null`, uma falha de subida derrubava o
# script em silêncio por causa do `set -e`, sem dizer o motivo.
if ! docker compose "${compose_args[@]}" up -d --build >/dev/null; then
    echo "ABORTADO: a stack não subiu (veja o erro do compose acima)." >&2
    exit 1
fi
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
# A taxa entra no nome: sem isso, uma série de taxa fixa SOBRESCREVE a de
# saturação da mesma configuração.
[[ -n "$rps" ]] && config="${config}-${rps}rps"
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
    # Erros de conexão envenenam a medição sem zerá-la: o worker sync do gunicorn
    # fecha toda conexão (sync.py:177, `resp.force_close()`), então cada request
    # é um TCP novo. Em vazão alta o host esgota portas efêmeras e a série vira
    # lixo silenciosamente. Ver performance/02-container-e-cgroup.md.
    erros=$(printf '%s' "$saida" | python3 -c 'import json,sys;print(sum(json.load(sys.stdin).get("errorDistribution",{}).get(k,0) for k in ["connection error"]))')
    if [[ "$erros" -gt $((total / 100 + 1)) ]]; then
        echo "ABORTADO: $erros erros de conexão para $total respostas." >&2
        echo "  Portas efêmeras esgotadas (ss -tan state time-wait | wc -l)." >&2
        echo "  Espere o TIME_WAIT drenar (~60s) ou reduza a vazão." >&2
        exit 1
    fi
    if [[ "$total" -eq 0 ]]; then
        echo "ABORTADO: zero requisições atendidas — a API não ficou acessível." >&2
        echo "  (em Docker Desktop, network_mode:host não alcança o localhost do WSL)" >&2
        exit 1
    fi
    # Uma chamada só, em vez de seis `bc`: as divisões aqui têm denominador
    # legitimamente zero (sem throttling, nr_periods pode não avançar) e o `bc`
    # respondia com erro em stderr e string vazia, produzindo JSON quebrado.
    extra=$(python3 "$RAIZ/scripts/bench-cgroup.py" \
        "$total" \
        "$(( $(stat_cgroup usage_usec)   - antes_uso ))" \
        "$(( $(stat_cgroup nr_throttled) - antes_thr ))" \
        "$(( $(stat_cgroup throttled_usec) - antes_thr_us ))" \
        "$(( $(stat_cgroup nr_periods)   - antes_per ))")

    destino="$RAIZ/resultados/bench/${config}.rep${i}.json"
    printf '%s' "$saida" | python3 "$RAIZ/scripts/bench-metadata.py" \
        "$destino" "$config" extrato "$duracao" "$modelo" "$CONCORRENCIA" "$extra" >/dev/null
    amostras+=("$destino")
    echo "[$config] rep $i/$reps" >&2
    # Dá tempo ao TIME_WAIT do host de drenar antes da próxima repetição.
    [[ "$i" -lt "$reps" ]] && sleep "${BENCH_PAUSA:-5}"
done

python3 "$RAIZ/scripts/bench-agregar.py" \
    "$RAIZ/resultados/bench/${config}.serie.json" "${amostras[@]}"
rm -f "${amostras[@]}"
