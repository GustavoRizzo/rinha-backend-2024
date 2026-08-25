#!/bin/sh
# Entrega o processo ao release, depois de decidir como a BEAM se dimensiona.
#
# Este arquivo é o lugar onde as duas armadilhas do BEAM sob cgroup são
# tratadas. Ver `.claude/docs/performance/elixir/00-indice.md`, seção 3.
set -e

# --------------------------------------------------------------------------
# Armadilha 1 — schedulers por núcleo VISÍVEL
#
# O cgroup limita a COTA, não a visibilidade: dentro de um container com 0.40
# CPU, a BEAM enxerga os 20 núcleos do host e sobe ~20 schedulers normais, 20
# dirty-CPU e 10 dirty-IO. São 40+ threads disputando 0.40 de CPU — o mesmo
# mecanismo que fez 4 workers de Gunicorn perderem para 1 em `django/04`, e o
# mesmo que a previsão do Go registrou para o `GOMAXPROCS`.
#
# `+S N:N` fixa schedulers e schedulers online; `+SDcpu`/`+SDio`, os dirty.
# --------------------------------------------------------------------------
case "${SCHEDULERS:-1}" in
    auto)
        # Braço de CONTROLE do experimento: deixa a BEAM se dimensionar sozinha.
        # A previsão registrada é que este braço tenha cauda pior que o Django.
        FLAGS_SCHED="" ;;
    ''|*[!0-9]*)
        echo "SCHEDULERS='${SCHEDULERS}' inválido; use um inteiro ou 'auto'" >&2
        exit 1 ;;
    *)
        FLAGS_SCHED="+S ${SCHEDULERS}:${SCHEDULERS} +SDcpu ${SCHEDULERS}:${SCHEDULERS} +SDio ${SCHEDULERS}" ;;
esac

# --------------------------------------------------------------------------
# Armadilha 2 — busy-wait queima cota sem fazer trabalho
#
# Os schedulers da BEAM fazem *spin* antes de dormir, apostando que trabalho
# novo chega logo. Numa máquina dedicada é uma troca boa: evita o custo de
# acordar uma thread. Sob cota de cgroup é possivelmente péssima, porque o
# cgroup cobra o spin como CPU usada — e `django/04` já mediu que, sob cota,
# ESPERAR é de graça e QUEIMAR não é.
#
# Esta é a hipótese própria deste experimento; não estava prevista em
# `django/06`.
# --------------------------------------------------------------------------
case "${BUSY_WAIT:-none}" in
    none)    FLAGS_BUSY="+sbwt none +sbwtdcpu none +sbwtdio none +swt very_low" ;;
    default) FLAGS_BUSY="" ;;   # braço de controle
    *)  echo "BUSY_WAIT='${BUSY_WAIT}' desconhecido; use 'none' ou 'default'" >&2
        exit 1 ;;
esac

export ERL_FLAGS="${FLAGS_SCHED} ${FLAGS_BUSY} ${ERL_FLAGS:-}"

# O socket precisa ser acessível ao nginx, que roda com outro usuário. A BEAM
# cria o arquivo de socket com a máscara do processo, e não tem opção para isso
# — definimos no shell e ela herda. Mesma solução do entrypoint do FastAPI.
umask 0

# Só no rig de benchmark: planta histórico para o extrato não medir lista vazia.
# `eval` carrega o código sem iniciar a aplicação, então roda numa VM própria e
# de vida curta, antes da que vai servir.
if [ "${BENCH_SEED:-0}" = "1" ]; then
    /app/bin/rinha eval 'Rinha.PrepararBench.run()'
fi

# `exec` é essencial: o release vira PID 1 e recebe o SIGTERM do `docker stop`
# diretamente. Sem isso o shell segura o sinal e o container leva 10s para
# morrer em toda derrubada.
exec /app/bin/rinha start
