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

# TUDO isto é lido depois de `perfil_rig`, e nunca antes: é ele que define os
# nomes dos containers, e cada rig usa os seus. Ler cedo demais foi um bug real
# — o bloco do banco sumia do resultado em silêncio, e a tabela imprimia
# travessão como se o rig não tivesse banco.
#
# Lista, não nome único: o rig da stack de produção tem DUAS instâncias, e o
# custo por requisição só faz sentido somando os dois cgroups — cada requisição
# cai numa delas, e o total gasto é o que a cota do orçamento paga.
read -r -a APIS <<< "$PERFIL_API"
# Primeira instância: é nela que `perfil_resetar` executa o comando que replanta
# o estado. O banco é compartilhado, então uma só basta.
export API="${APIS[0]}"
LB="$PERFIL_LB"
DB="${PERFIL_DB:-}"
if [[ "${BENCH_BANCO:-}" == "postgres" && -z "$DB" ]]; then
    echo "ABORTADO: rig '$rig' usa Postgres mas o perfil não declarou PERFIL_DB." >&2
    echo "Sem o cgroup do banco não dá para dizer quem é o gargalo." >&2
    exit 1
fi

# Rigs marcados como "orçamento da competição" precisam fechar em 1.5 CPU e
# 550MB. Sem esta trava, uma repartição inválida produziria um número ótimo e
# ilegal — e um número ilegal contamina a comparação inteira, porque não dá
# para saber depois qual linha da tabela podia existir.
if [[ "${PERFIL_ORCAMENTO:-0}" == "1" ]]; then
    export API_CPUS="$cpus" DB_CPUS="${DB_CPUS:-0.60}" LB_CPUS="${LB_CPUS:-0.10}"
    if ! bash "$RAIZ/scripts/check-limites.sh" "${compose_args[@]}" >/dev/null; then
        echo "ABORTADO: a repartição estoura o orçamento da Rinha." >&2
        bash "$RAIZ/scripts/check-limites.sh" "${compose_args[@]}" >&2 || true
        exit 1
    fi
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

# Soma a métrica em todos os containers passados. Com um só, é a leitura
# direta; com dois, é a soma — que é o número certo para uma stack de duas
# instâncias sob um orçamento único.
stat_de() {
    local chave="$1"; shift
    local total=0 valor
    for container in "$@"; do
        valor=$(docker exec "$container" awk -v k="$chave" '$1==k{print $2}' /sys/fs/cgroup/cpu.stat)
        [[ -n "$valor" ]] || { echo "ABORTADO: cpu.stat sem '$chave' em $container." >&2; exit 1; }
        total=$(( total + valor ))
    done
    printf '%s' "$total"
}

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
# BENCH_TAG separa séries de experimentos diferentes que compartilham a mesma
# configuração. Sem ele, repetir uma configuração com instrumentação nova
# sobrescreve — em silêncio — o arquivo que sustenta um documento já escrito.
[[ -n "${BENCH_TAG:-}" ]] && config="${config}-${BENCH_TAG}"

# Antes do aquecimento, e para QUALQUER endpoint: o extrato precisa de
# histórico para não medir a serialização de uma lista vazia, e o rig da stack
# de produção não tem BENCH_SEED no compose — nem deveria ter, é a stack da
# competição.
if ! perfil_resetar >/dev/null 2>&1; then
    echo "ABORTADO: não consegui plantar o estado inicial do benchmark." >&2
    exit 1
fi

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

    a_uso=$(stat_de usage_usec "${APIS[@]}");  a_thr=$(stat_de nr_throttled "${APIS[@]}")
    a_thu=$(stat_de throttled_usec "${APIS[@]}"); a_per=$(stat_de nr_periods "${APIS[@]}")
    n_uso=$(stat_de usage_usec "$LB");   n_thr=$(stat_de nr_throttled "$LB")
    n_thu=$(stat_de throttled_usec "$LB");  n_per=$(stat_de nr_periods "$LB")
    if [[ -n "$DB" ]]; then
        d_uso=$(stat_de usage_usec "$DB");   d_thr=$(stat_de nr_throttled "$DB")
        d_thu=$(stat_de throttled_usec "$DB"); d_per=$(stat_de nr_periods "$DB")
    fi

    saida=$(oha -z "$duracao" -c "$CONCORRENCIA" --no-tui --output-format json \
                "${taxa[@]}" "${alvo[@]}")

    total=$(printf '%s' "$saida" | python3 -c 'import json,sys;print(sum(json.load(sys.stdin)["statusCodeDistribution"].values()))')
    erros=$(printf '%s' "$saida" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("errorDistribution",{}).get("connection error",0))')
    if [[ "$total" -eq 0 || "$erros" -gt $((total / 100 + 1)) ]]; then
        echo "ABORTADO: $erros erros de conexão para $total respostas." >&2
        exit 1
    fi

    args_cgroup=(
        "$total"
        "$(( $(stat_de usage_usec "${APIS[@]}")     - a_uso ))"
        "$(( $(stat_de nr_throttled "${APIS[@]}")   - a_thr ))"
        "$(( $(stat_de throttled_usec "${APIS[@]}") - a_thu ))"
        "$(( $(stat_de nr_periods "${APIS[@]}")     - a_per ))"
        "$(( $(stat_de usage_usec "$LB")      - n_uso ))"
        "$(( $(stat_de nr_throttled "$LB")    - n_thr ))"
        "$(( $(stat_de throttled_usec "$LB")  - n_thu ))"
        "$(( $(stat_de nr_periods "$LB")      - n_per ))"
    )
    if [[ -n "$DB" ]]; then
        args_cgroup+=(
            "$(( $(stat_de usage_usec "$DB")     - d_uso ))"
            "$(( $(stat_de nr_throttled "$DB")   - d_thr ))"
            "$(( $(stat_de throttled_usec "$DB") - d_thu ))"
            "$(( $(stat_de nr_periods "$DB")     - d_per ))"
        )
    fi
    extra=$(python3 "$RAIZ/scripts/bench-cgroup.py" "${args_cgroup[@]}")

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
