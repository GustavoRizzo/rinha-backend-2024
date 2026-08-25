#!/bin/sh
# Entrega o processo ao binário, depois de decidir como o runtime se dimensiona.
#
# Este arquivo é o lugar onde as armadilhas do Go sob cgroup são tratadas. Ver
# `.claude/docs/performance/go/00-indice.md`, seções 5 e 7.
set -e

# --------------------------------------------------------------------------
# Armadilha 1 — quantas threads o scheduler usa
#
# A previsão de `django/06` dizia que uma porta Go ingênua subiria 20 threads
# disputando 0.40 CPU, porque o cgroup limita a COTA e não a VISIBILIDADE — o
# mesmo mecanismo que fez 4 workers de Gunicorn perderem para 1 em `django/04`.
#
# MEDIDO em `performance/go/00-indice.md`, seção 7.1: o Go 1.27 lê a cota do
# cgroup, mas ARREDONDA PARA CIMA ATÉ 2 (`runtime/cgroup_linux.go:85-92`). Sob
# a cota da competição (0.40 CPU) são duas threads, não vinte — e não uma, como
# faz o OTP 27 do projeto Elixir.
#
# Por isso `auto` é o PADRÃO e `1` é o braço do experimento, ao contrário do
# entrypoint do Elixir, onde a relação é inversa: lá o padrão precisa corrigir
# o runtime, aqui o runtime já se corrige e a pergunta é se o piso de 2 ajuda.
#
# `GOMAXPROCS` é lida pelo próprio runtime; `auto` não é um valor que ele
# entenda, então o traduzimos para "variável ausente".
case "${GOMAXPROCS:-auto}" in
    auto)
        unset GOMAXPROCS ;;
    ''|*[!0-9]*)
        echo "GOMAXPROCS='${GOMAXPROCS}' inválido; use um inteiro positivo ou 'auto'" >&2
        exit 1 ;;
    0)
        echo "GOMAXPROCS=0 inválido; use um inteiro positivo ou 'auto'" >&2
        exit 1 ;;
    *)
        export GOMAXPROCS ;;
esac

# --------------------------------------------------------------------------
# Armadilha 3 — o GC não sabe do teto de memória do cgroup
#
# Mesmo mecanismo da armadilha 1, aplicado a outro recurso: `GOGC` (padrão 100)
# manda coletar quando o heap DOBRA, sem saber que o container tem 100MB.
# `GOMEMLIMIT` informa o teto ao runtime, que passa a coletar antes de chegar
# lá em vez de ser morto por OOM.
#
# Vazio por padrão: a previsão é que sobre folga com larga margem, e ligar um
# limite "por precaução" mudaria o comportamento do GC em toda série sem que
# ninguém tivesse medido a necessidade. Fica como braço de experimento.
if [ -n "${GOMEMLIMIT:-}" ]; then
    export GOMEMLIMIT
fi

# O socket precisa ser acessível ao nginx, que roda com outro usuário. O
# `net.Listen` cria o arquivo com a máscara do processo — definimos aqui e o
# binário herda. Mesma solução do entrypoint do FastAPI e do Elixir. O
# `os.Chmod` em `main.go` é o cinto de segurança.
umask 0

# Só no rig de benchmark: planta histórico para o extrato não medir lista vazia.
# O estado resultante é idêntico ao do `preparar_bench` dos outros três projetos.
if [ "${BENCH_SEED:-0}" = "1" ]; then
    /app/rinha preparar-bench
fi

# `exec` é essencial: o binário vira PID 1 e recebe o SIGTERM do `docker stop`
# diretamente. Sem isso o shell segura o sinal e o container leva 10s para
# morrer em toda derrubada.
exec /app/rinha
