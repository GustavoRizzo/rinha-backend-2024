#!/usr/bin/env bash
# Comparativo local de configurações da API Django (SQLite, sem Docker).
#
# Uma configuração por execução: sobe o servidor, espera ficar pronto, dispara o
# oha, arquiva o JSON com metadados (incluindo o commit) e derruba o servidor.
#
# Uso: bench-local.sh <config> <endpoint> <duracao> [rps]
#   config:   runserver-debug | runserver-prod | gunicorn-1w | gunicorn-1w-debug
#             | gunicorn-4w
#   endpoint: extrato | transacoes
#   duracao:  ex. 15s
#   rps:      se informado, modelo ABERTO a essa taxa; senão, saturação (fechado)
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DJANGO="$RAIZ/django"
PORTA="${BENCH_PORTA:-8123}"
CONCORRENCIA="${BENCH_CONCORRENCIA:-50}"

config="${1:?config}"; endpoint="${2:?endpoint}"; duracao="${3:-15s}"; rps="${4:-}"

# Um benchmark grava o commit junto do resultado. Com a árvore suja esse hash
# descreve outro código — proveniência falsa é pior que proveniência nenhuma.
# `resultados/` fica de fora da conferência: são SAÍDAS versionadas, e uma
# execução anterior deixaria a árvore suja para a próxima.
# Para exploração deliberada, sem intenção de documentar: BENCH_PERMITIR_SUJO=1
if [[ -n "$(git -C "$RAIZ" status --porcelain -- . ':(exclude)resultados' 2>/dev/null)" ]]; then
    if [[ "${BENCH_PERMITIR_SUJO:-0}" != "1" ]]; then
        echo "ABORTADO: árvore de trabalho suja." >&2
        echo "  Commite antes de medir — o resultado grava o hash do commit." >&2
        echo "  Para medir mesmo assim: BENCH_PERMITIR_SUJO=1 $0 $*" >&2
        exit 1
    fi
    echo "AVISO: árvore suja; o commit gravado NÃO descreve o código medido." >&2
fi

case "$config" in
  runserver-debug) export DJANGO_DEBUG=1; servidor=runserver; workers=1 ;;
  runserver-prod)  export DJANGO_DEBUG=0; servidor=runserver; workers=1 ;;
  gunicorn-1w)     export DJANGO_DEBUG=0; servidor=gunicorn;  workers=1 ;;
  # Isola o efeito do DEBUG sem o runserver mascarando o resultado.
  gunicorn-1w-debug) export DJANGO_DEBUG=1; servidor=gunicorn; workers=1 ;;
  gunicorn-4w)     export DJANGO_DEBUG=0; servidor=gunicorn;  workers=4 ;;
  *) echo "config desconhecida: $config" >&2; exit 1 ;;
esac

cd "$DJANGO"

# Estado idêntico em toda rodada. Comparar execuções que partiram de bancos
# diferentes não compara nada.
uv run python manage.py migrate --no-input >/dev/null
uv run python manage.py loaddata clientes >/dev/null
uv run python manage.py preparar_bench >/dev/null

if [[ "$servidor" == "runserver" ]]; then
    uv run python manage.py runserver "127.0.0.1:$PORTA" --noreload \
        >/tmp/bench-servidor.log 2>&1 &
else
    uv run gunicorn kernel.wsgi:application \
        --bind "127.0.0.1:$PORTA" --workers "$workers" \
        >/tmp/bench-servidor.log 2>&1 &
fi
servidor_pid=$!
limpar() { kill "$servidor_pid" 2>/dev/null || true; wait "$servidor_pid" 2>/dev/null || true; }
trap limpar EXIT

for _ in $(seq 1 40); do
    curl -fsS "http://127.0.0.1:$PORTA/clientes/1/extrato" >/dev/null 2>&1 && break
    sleep 0.25
done

case "$endpoint" in
  extrato)    args=(-m GET  "http://127.0.0.1:$PORTA/clientes/1/extrato") ;;
  transacoes) args=(-m POST -H 'Content-Type: application/json'
                    -d '{"valor":1,"tipo":"c","descricao":"bench"}'
                    "http://127.0.0.1:$PORTA/clientes/1/transacoes") ;;
  *) echo "endpoint desconhecido: $endpoint" >&2; exit 1 ;;
esac

modelo="fechado(saturacao)"
taxa=()
if [[ -n "$rps" ]]; then
    taxa=(-q "$rps"); modelo="aberto(${rps}rps)"
fi

# --no-tui: sem TUI o oha não gasta CPU desenhando — importante, o gerador
# disputa a mesma máquina que o servidor.
saida=$(oha -z "$duracao" -c "$CONCORRENCIA" --no-tui --output-format json \
            "${taxa[@]}" "${args[@]}")

slug="${config}-${endpoint}"
[[ -n "$rps" ]] && slug="${slug}-${rps}rps"
destino="$RAIZ/resultados/bench/${slug}.json"
mkdir -p "$(dirname "$destino")"

# Metadados junto do resultado: sem o commit e as versões, o número não é
# replicável daqui a alguns meses.
printf '%s' "$saida" | python3 "$RAIZ/scripts/bench-metadata.py" \
    "$destino" "$config" "$endpoint" "$duracao" "$modelo" "$CONCORRENCIA"
