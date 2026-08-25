#!/usr/bin/env bash
# Amostra o `cpu.stat` de todos os serviços de uma stack a cada N segundos.
#
# Complementa `cgroup-snapshot.sh`, que tira DUAS fotos (antes e depois) e por
# isso só responde "quanto cada serviço gastou no total". Esta responde "gastou
# QUANDO" — e existe por uma pergunta concreta: a prova oficial do Go colocou
# 882 requisições acima de 250ms, todas nos 4 últimos segundos de 244
# (`performance/go/00-indice.md`, seção 7.5). Uma média de 4 minutos não
# distingue um serviço saturado o tempo todo de um serviço que congelou por 4
# segundos.
#
# FORA da metodologia de medição: `docker exec` por serviço por segundo custa
# CPU no host, e a stack medida disputa a máquina com o Gatling. Serve para
# achar QUANDO, não para dizer QUANTO. Nada daqui entra em `resultados/`.
#
# Uso: cgroup-serie.sh <saida.jsonl> <segundos> -f <compose.yml> [-f ...]
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
saida="${1:?uso: cgroup-serie.sh <saida.jsonl> <segundos> -f <compose.yml>...}"
duracao="${2:?segundos}"
shift 2
[[ $# -gt 0 ]] || { echo "faltam os -f do compose" >&2; exit 1; }

: > "$saida"
fim=$(( $(date +%s) + duracao ))

while [[ $(date +%s) -lt $fim ]]; do
    # O instante vai no registro, e não é inferido pela posição da linha: o
    # `docker exec` de cada amostra leva algumas centenas de milissegundos, e
    # assumir cadência exata deslocaria a correlação com o relatório do Gatling
    # justamente no fim, que é o trecho que interessa.
    agora=$(date +%s.%N)
    linha=$(bash "$RAIZ/scripts/cgroup-snapshot.sh" "$@" 2>/dev/null || true)
    # Sem `||`-fallback silencioso: uma amostra vazia é registrada como nula, e
    # quem lê a série vê o buraco em vez de interpolar por cima dele.
    if [[ -z "$linha" ]]; then
        printf '{"t":%s,"servicos":null}\n' "$agora" >> "$saida"
    else
        printf '{"t":%s,"servicos":%s}\n' "$agora" "$linha" >> "$saida"
    fi
    sleep 1
done
