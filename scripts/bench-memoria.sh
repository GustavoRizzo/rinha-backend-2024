#!/usr/bin/env bash
# Mede o crescimento de memória residente do processo servidor sob carga.
#
# O custo do DEBUG=True em VAZÃO é pequeno; o perigo é outro e um teste de
# throughput não o enxerga: `connection.queries` acumula TODA query executada,
# sem limite. Este script expõe isso comparando o RSS ao longo da carga.
#
# Uso: bench-memoria.sh <config> <endpoint> <duracao_s>
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DJANGO="$RAIZ/django"
PORTA="${BENCH_PORTA:-8124}"
config="${1:?config}"; endpoint="${2:-extrato}"; segundos="${3:-30}"

case "$config" in
  gunicorn-1w)       export DJANGO_DEBUG=0 ;;
  gunicorn-1w-debug) export DJANGO_DEBUG=1 ;;
  *) echo "use gunicorn-1w ou gunicorn-1w-debug" >&2; exit 1 ;;
esac

cd "$DJANGO"
uv run python manage.py migrate --no-input >/dev/null
uv run python manage.py loaddata clientes >/dev/null
uv run python manage.py preparar_bench >/dev/null

uv run gunicorn kernel.wsgi:application --bind "127.0.0.1:$PORTA" --workers 1 \
    >/tmp/bench-memoria.log 2>&1 &
mestre=$!
trap 'kill $mestre 2>/dev/null || true' EXIT

for _ in $(seq 1 40); do
    curl -fsS "http://127.0.0.1:$PORTA/clientes/1/extrato" >/dev/null 2>&1 && break
    sleep 0.25
done
# O worker é filho do mestre do gunicorn; é ele que atende os requests.
worker=$(pgrep -P "$mestre" | head -1)

oha -z "${segundos}s" -c 20 --no-tui --output-format quiet \
    "http://127.0.0.1:$PORTA/clientes/1/$endpoint" >/dev/null 2>&1 &
carga=$!

amostras=()
while kill -0 "$carga" 2>/dev/null; do
    rss=$(awk '/VmRSS/{print $2}' "/proc/$worker/status" 2>/dev/null || echo 0)
    amostras+=("$rss")
    sleep 2
done
wait "$carga" 2>/dev/null || true

printf '%s\n' "${amostras[@]}" | python3 -c "
import sys
kb=[int(l) for l in sys.stdin if l.strip() and l.strip()!='0']
print('$config: RSS inicial=%.1fMB final=%.1fMB crescimento=%+.1fMB (%d amostras)'
      % (kb[0]/1024, kb[-1]/1024, (kb[-1]-kb[0])/1024, len(kb)))
"
