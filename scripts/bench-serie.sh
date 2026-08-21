#!/usr/bin/env bash
# Série estatística: descarta uma rodada de aquecimento e repete N vezes.
#
# Existe porque a PRIMEIRA execução de cada configuração sai sistematicamente
# mais lenta (cache de página frio, .pyc, conexões). Sem descartá-la, a
# diferença entre configurações fica soterrada no ruído.
#
# Uso: bench-serie.sh <config> <endpoint> [duracao] [reps]
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${1:?config}"; endpoint="${2:?endpoint}"; duracao="${3:-15s}"; reps="${4:-3}"

echo "[$config] aquecimento (descartado)..." >&2
"$RAIZ/scripts/bench-local.sh" "$config" "$endpoint" "$duracao" >/dev/null 2>&1

amostras=()
for i in $(seq 1 "$reps"); do
    "$RAIZ/scripts/bench-local.sh" "$config" "$endpoint" "$duracao" >/dev/null 2>&1
    cp "$RAIZ/resultados/bench/${config}-${endpoint}.json" \
       "$RAIZ/resultados/bench/${config}-${endpoint}.rep${i}.json"
    amostras+=("$RAIZ/resultados/bench/${config}-${endpoint}.rep${i}.json")
    echo "[$config] rep $i/$reps" >&2
done

python3 "$RAIZ/scripts/bench-agregar.py" \
    "$RAIZ/resultados/bench/${config}-${endpoint}.serie.json" "${amostras[@]}"
rm -f "${amostras[@]}"
