#!/usr/bin/env bash
# Fotografa o `cpu.stat` de TODOS os serviços de uma stack, em JSON.
#
# Existe porque a bancada coletava cgroup e a prova oficial não. Sem isto,
# "redistribuir a cota" só podia ser decidido em SATURAÇÃO — e
# `performance/fastapi/02` mediu que a repartição eleita em saturação foi
# recusada pela carga real. Duas fotos, antes e depois do Gatling, dão o
# consumo de CPU de cada serviço NA CARGA QUE REALMENTE CHEGA.
#
# Uso: cgroup-snapshot.sh -f <compose.yml> [-f <override.yml> ...]
set -euo pipefail

compose_args=("$@")
[[ ${#compose_args[@]} -gt 0 ]] || { echo "uso: cgroup-snapshot.sh -f <compose.yml>..." >&2; exit 1; }

# `docker compose ps` dá o par serviço->container, que é o que permite nomear
# as chaves por SERVIÇO (api01, db, nginx) em vez de por nome de container —
# este último muda entre rigs e entre projetos.
mapa=$(docker compose "${compose_args[@]}" ps --format '{{.Service}} {{.Name}}')
[[ -n "$mapa" ]] || { echo "ABORTADO: nenhum container de pé para esta stack." >&2; exit 1; }

primeiro=1
printf '{'
while read -r servico container; do
    [[ -n "$servico" ]] || continue
    stat=$(docker exec "$container" cat /sys/fs/cgroup/cpu.stat 2>/dev/null || true)
    # Abortar, e não assumir zero: um serviço sem cpu.stat legível viraria
    # "0 µs de CPU" na tabela — plausível, e mentira. Três bugs deste projeto
    # foram exatamente disso.
    for chave in usage_usec nr_periods nr_throttled throttled_usec; do
        grep -q "^${chave} " <<<"$stat" || {
            echo "ABORTADO: cpu.stat sem '${chave}' em ${container} (serviço ${servico})." >&2
            exit 1
        }
    done
    [[ $primeiro -eq 1 ]] || printf ','
    primeiro=0
    printf '"%s":{' "$servico"
    awk '$1=="usage_usec"||$1=="nr_periods"||$1=="nr_throttled"||$1=="throttled_usec" {
             printf "%s\"%s\":%s", (n++ ? "," : ""), $1, $2
         }' <<<"$stat"
    printf '}'
done <<<"$mapa"
printf '}\n'
