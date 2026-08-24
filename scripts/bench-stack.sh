#!/usr/bin/env bash
# Experimento 03 em diante: a stack atrás do load balancer.
#
# Diferenças para o bench-container.sh (que continua válido para reproduzir o
# experimento 02): a carga entra pelo nginx na porta 9999, a API não é exposta,
# e o cpu.stat é coletado dos DOIS cgroups — o custo do LB é parte do resultado.
#
# Uso: bench-stack.sh <rig> <cpus> <workers> [duracao] [reps] [rps]
#   rig: nginx-unix | nginx-tcp | postgres | postgres-sem-persistencia
#        | postgres-sem-limite   (remove as cotas de CPU/memória)
#
# BENCH_PROJETO=django|fastapi escolhe o projeto medido. O que muda de projeto
# para projeto — rigs disponíveis, arquivos de compose, nomes de container e
# como o estado é reposto — vive em `scripts/perfis/<projeto>.sh`. Tudo o mais
# é igual aqui, e é isso que torna as séries comparáveis entre projetos.
#
# BENCH_SERVER=gunicorn-sync|gunicorn-gthread|uvicorn escolhe o servidor HTTP.
# BENCH_THREADS=N define o tamanho do pool do gthread.
# BENCH_POOL=1 liga o pool de conexões do psycopg (necessário no ASGI).
#
# BENCH_ENDPOINT=transacoes mede a ESCRITA. Fica em variável de ambiente, e
# não como argumento posicional, para não quebrar os comandos publicados no
# documento do experimento 03.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJETO="${BENCH_PROJETO:-django}"
PERFIL="$RAIZ/scripts/perfis/${PROJETO}.sh"
if [[ ! -f "$PERFIL" ]]; then
    echo "ABORTADO: projeto '$PROJETO' não tem perfil de bancada ($PERFIL)." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$PERFIL"

ENDPOINT="${BENCH_ENDPOINT:-extrato}"
# O servidor padrão é do PROJETO, não do script: o Django ganhou com gunicorn
# sync (`django/06`), e o FastAPI não tem WSGI para servir.
SERVIDOR="${BENCH_SERVER:-$([[ "$PROJETO" == "django" ]] && echo gunicorn-sync || echo uvicorn)}"
THREADS="${BENCH_THREADS:-4}"
API="$PERFIL_API"
LB="$PERFIL_LB"
PORTA="${LB_PORTA:-9999}"
CONCORRENCIA="${BENCH_CONCORRENCIA:-50}"

rig="${1:?rig}"; cpus="${2:?cpus}"; workers="${3:?workers}"
duracao="${4:-10s}"; reps="${5:-5}"; rps="${6:-}"

if [[ -n "$(git -C "$RAIZ" status --porcelain -- . ':(exclude)resultados' 2>/dev/null)" && "${BENCH_PERMITIR_SUJO:-0}" != "1" ]]; then
    echo "ABORTADO: árvore suja. O resultado grava o hash do commit." >&2
    exit 1
fi

compose_args=()
if ! perfil_rig "$rig"; then
    echo "ABORTADO: rig '$rig' não existe no projeto '$PROJETO'." >&2
    exit 1
fi

export API_CPUS="$cpus" API_WORKERS="$workers" LB_PORTA="$PORTA"
export API_SERVER="$SERVIDOR" API_THREADS="$THREADS"
# stderr preservado: com `2>&1 >/dev/null`, uma falha de subida derrubava o
# script em silêncio por causa do `set -e`, sem dizer o motivo.
if ! docker compose "${compose_args[@]}" up -d --build >/dev/null; then
    echo "ABORTADO: a stack não subiu (veja o erro do compose acima)." >&2
    exit 1
fi
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

# O nome do servidor entra no slug: sem isso uma série de gthread
# sobrescreveria a de sync na mesma cota.
sufixo_servidor="$(perfil_sufixo_servidor)"
# O projeto entra no slug, senão uma série do FastAPI sobrescreveria a do Django
# no mesmo rig e na mesma cota — e o arquivo antigo seria perdido em silêncio.
# `django` fica de fora por compatibilidade: os slugs já publicados nos
# documentos de `performance/django/` continuam válidos.
prefixo_projeto=""
[[ "$PROJETO" != "django" ]] && prefixo_projeto="${PROJETO}-"
config="${prefixo_projeto}${rig}-${sufixo_servidor}-${ENDPOINT}-cpu${cpus}-w${workers}"
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
        if ! perfil_resetar >/dev/null 2>&1; then
            echo "ABORTADO: não consegui repor o estado entre repetições." >&2
            echo "Sem isso o saldo desce até o limite e tudo vira 422 — que" >&2
            echo "responde rápido e infla o rps com respostas falsas." >&2
            exit 1
        fi
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
