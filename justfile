# Rinha de Backend 2024/Q1 — laboratório de estudo
#
# Organização:
#   [ciclo]   comandos genéricos que valem para qualquer projeto/variante
#   [analise] leitura de resultados
#   [django]  comandos específicos do projeto Django
#   [setup]   preparação do ambiente
#
# Convenção: um "projeto" é uma pasta de stack (django, fastapi, go...).
# Uma "variante" é um override de compose dentro dele (sqlite, raw-sql...).
# O slug do resultado é "<projeto>-<variante>", ou só "<projeto>" na base.

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

RAIZ        := justfile_directory()
OFICIAL     := RAIZ / "rinha-de-backend-2024-q1"
RESULTADOS  := RAIZ / "resultados"

# lista os comandos disponíveis
default:
    @just --list --unsorted

# ==========================================================================
# ciclo — sobe, testa e derruba qualquer projeto/variante
# ==========================================================================

# monta a lista de arquivos -f do compose para um projeto/variante
_compose proj var="":
    #!/usr/bin/env bash
    set -euo pipefail
    base="{{RAIZ}}/{{proj}}/docker-compose.yml"
    [[ -f "$base" ]] || { echo "erro: $base não existe" >&2; exit 1; }
    args=(-f "$base")
    if [[ -n "{{var}}" ]]; then
        ov="{{RAIZ}}/{{proj}}/compose.{{var}}.yml"
        [[ -f "$ov" ]] || { echo "erro: variante '{{var}}' não existe ($ov)" >&2; exit 1; }
        args+=(-f "$ov")
    fi
    printf '%s\n' "${args[@]}"

# slug identificador da variante (usado em resultados/)
_slug proj var="":
    @[[ -n "{{var}}" ]] && echo "{{proj}}-{{var}}" || echo "{{proj}}"

# constrói as imagens
[group('ciclo')]
build proj var="":
    docker compose $(just _compose {{proj}} {{var}} | tr '\n' ' ') build

# sobe a stack e espera ficar pronta (limite de 40s, como na competição)
[group('ciclo')]
up proj var="": (build proj var)
    #!/usr/bin/env bash
    set -euo pipefail
    docker compose $(just _compose {{proj}} {{var}} | tr '\n' ' ') up -d
    echo "aguardando prontidão em http://localhost:9999 ..."
    for i in {1..20}; do
        if curl -fsS http://localhost:9999/clientes/1/extrato >/dev/null 2>&1; then
            echo "pronto em ~$((i*2))s"; exit 0
        fi
        sleep 2
    done
    echo "FALHOU: não ficou pronta em 40s (limite da competição)" >&2
    docker compose $(just _compose {{proj}} {{var}} | tr '\n' ' ') logs --tail=50 >&2
    exit 1

# derruba a stack e remove volumes (sempre -v: estado residual falsifica o teste)
[group('ciclo')]
down proj var="":
    docker compose $(just _compose {{proj}} {{var}} | tr '\n' ' ') down -v --remove-orphans

# logs da stack
[group('ciclo')]
logs proj var="" *args:
    docker compose $(just _compose {{proj}} {{var}} | tr '\n' ' ') logs {{args}}

# validação funcional rápida (~5s) — roda ANTES da carga para falhar cedo
[group('ciclo')]
smoke proj="" var="":
    @bash {{RAIZ}}/scripts/smoke-test.sh

# executa a simulação Gatling e arquiva o resultado
[group('ciclo')]
load proj var="":
    @bash {{RAIZ}}/scripts/rodar-carga.sh "$(just _slug {{proj}} {{var}})" \
        $(just _compose {{proj}} {{var}} | tr '\n' ' ')

# o comando do dia a dia: up -> smoke -> load -> down
[group('ciclo')]
run proj var="":
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'just down {{proj}} {{var}}' EXIT
    just up {{proj}} {{var}}
    just smoke {{proj}} {{var}}
    just load {{proj}} {{var}}

# amostra cpu.stat de cada serviço a cada segundo (diagnóstico: gastou QUANDO?)
[group('ciclo')]
stats-serie proj var="" segundos="300" saida="/tmp/cgroup-serie.jsonl":
    @bash {{RAIZ}}/scripts/cgroup-serie.sh {{saida}} {{segundos}} \
        $(just _compose {{proj}} {{var}} | tr '\n' ' ')

# docker stats + throttling de cgroup ao vivo (rode em outro terminal durante a carga)
[group('ciclo')]
stats:
    @bash {{RAIZ}}/scripts/coletar-metricas.sh

# valida os limites do compose: soma <= 1.5 CPU e <= 550MB
[group('ciclo')]
check proj var="":
    @bash {{RAIZ}}/scripts/check-limites.sh $(just _compose {{proj}} {{var}} | tr '\n' ' ')

# ==========================================================================
# analise — leitura dos resultados
# ==========================================================================

# lista as execuções arquivadas
[group('analise')]
runs:
    @ls -1 {{RESULTADOS}} 2>/dev/null | grep -v '^\.gitkeep$' || echo "(nenhuma execução ainda)"

# abre o relatório HTML da última execução
[group('analise')]
report slug:
    #!/usr/bin/env bash
    set -euo pipefail
    ultimo=$(ls -1d {{RESULTADOS}}/{{slug}}/*/ 2>/dev/null | sort | tail -1)
    [[ -n "$ultimo" ]] || { echo "sem resultados para '{{slug}}'" >&2; exit 1; }
    echo "abrindo ${ultimo}index.html"
    xdg-open "${ultimo}index.html" 2>/dev/null || explorer.exe "$(wslpath -w "${ultimo}index.html")"

# calcula a pontuação da Rinha (multa de SLA + multa de consistência)
[group('analise')]
score slug:
    @python3 {{RAIZ}}/scripts/pontuacao.py {{RESULTADOS}}/{{slug}}

# diagnóstico: a fraqueza é velocidade, concorrência ou consistência?
[group('analise')]
diag slug:
    @python3 {{RAIZ}}/scripts/diagnostico.py {{RESULTADOS}}/{{slug}}

# linhas de código por stack, separando documentação de implementação
[group('analise')]
codigo *args:
    @python3 {{RAIZ}}/scripts/contar-codigo.py {{args}}

# tabela comparativa entre variantes
[group('analise')]
compare +slugs:
    @python3 {{RAIZ}}/scripts/comparar.py {{slugs}}

# ==========================================================================
# django — projeto Django
# ==========================================================================

# manage.py com argumentos livres
[group('django')]
dj *args:
    cd {{RAIZ}}/django && uv run python manage.py {{args}}

# servidor de desenvolvimento (fora do Docker, para iterar rápido)
[group('django')]
dj-serve porta="8000":
    cd {{RAIZ}}/django && uv run python manage.py runserver {{porta}}

# shell interativo
[group('django')]
dj-shell:
    cd {{RAIZ}}/django && uv run python manage.py shell

# cria as migrações
[group('django')]
dj-mkmig *args:
    cd {{RAIZ}}/django && uv run python manage.py makemigrations {{args}}

# aplica as migrações
[group('django')]
dj-migrate *args:
    cd {{RAIZ}}/django && uv run python manage.py migrate {{args}}

# carrega os 5 clientes do README (limites e saldos iniciais)
[group('django')]
dj-seed:
    cd {{RAIZ}}/django && uv run python manage.py loaddata clientes

# NOTA: esta é a sequência a ser reproduzida no entrypoint do container.
# prepara o banco do zero: dependências -> schema -> carga inicial
[group('django')]
dj-setup: dj-sync dj-migrate dj-seed
    @echo "banco pronto: schema aplicado e 5 clientes carregados"

# zera o banco e recarrega a fixture (estado residual falsifica o teste)
[group('django')]
dj-reset:
    cd {{RAIZ}}/django && uv run python manage.py flush --no-input
    just dj-seed

# confere se a carga inicial bate com a tabela do README
[group('django')]
dj-verify:
    cd {{RAIZ}}/django && uv run python manage.py verificar_clientes

# adiciona dependência (ex: just dj-add psycopg[binary])
[group('django')]
dj-add +pkgs:
    cd {{RAIZ}}/django && uv add {{pkgs}}

# sincroniza o ambiente com o lock
[group('django')]
dj-sync:
    cd {{RAIZ}}/django && uv sync

# ==========================================================================
# fastapi — projeto FastAPI + asyncpg
# ==========================================================================

# sobe o Postgres descartável dos testes (porta 5433, schema de infra/sql/)
[group('fastapi')]
fa-db-teste acao="up":
    @bash {{RAIZ}}/scripts/fastapi-db-teste.sh {{acao}}

# roda a suíte contra o banco de teste (sobe e derruba sozinho)
[group('fastapi')]
fa-test *args:
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'bash {{RAIZ}}/scripts/fastapi-db-teste.sh down' EXIT
    bash {{RAIZ}}/scripts/fastapi-db-teste.sh up
    cd {{RAIZ}}/fastapi && uv run --no-active pytest {{args}}

# a suíte inteira em CADA variante — é o que autoriza compará-las depois
[group('fastapi')]
fa-test-variantes:
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'bash {{RAIZ}}/scripts/fastapi-db-teste.sh down' EXIT
    bash {{RAIZ}}/scripts/fastapi-db-teste.sh up
    cd {{RAIZ}}/fastapi
    for v in "VALIDACAO=manual" "VALIDACAO=pydantic" "EXTRATO_QUERY=duas" \
             "EXTRATO_QUERY=unica" "SERIALIZACAO=orjson" "SERIALIZACAO=stdlib"; do
        echo "=== $v"
        env "$v" uv run --no-active pytest -q
    done

# servidor local, fora do Docker (exige `just fa-db-teste`)
[group('fastapi')]
fa-serve porta="8000":
    cd {{RAIZ}}/fastapi && DB_PORT=5433 VERIFICAR_CLIENTES=0 \
        uv run --no-active uvicorn app.main:app --port {{porta}} --reload

# adiciona dependência (ex: just fa-add granian)
[group('fastapi')]
fa-add +pkgs:
    cd {{RAIZ}}/fastapi && uv add {{pkgs}}

# sincroniza o ambiente com o lock
[group('fastapi')]
fa-sync:
    cd {{RAIZ}}/fastapi && uv sync

# ==========================================================================
# elixir — projeto Elixir + Bandit + Postgrex
#
# Ao contrário de `dj-*` e `fa-*`, estas receitas NÃO exigem a linguagem
# instalada no host: tudo roda na mesma imagem que o Dockerfile usa para
# compilar. Ver `scripts/elixir-teste.sh` para o porquê.
# ==========================================================================

# roda o ExUnit contra um Postgres descartável (sobe e derruba sozinho)
[group('elixir')]
ex-test *args:
    @bash {{RAIZ}}/scripts/elixir-teste.sh test {{args}}

# derruba o banco de teste, se um `ex-test` interrompido o tiver deixado de pé
[group('elixir')]
ex-db-down:
    @bash {{RAIZ}}/scripts/elixir-teste.sh down

# mix arbitrário dentro da imagem de build (ex: just ex mix deps.tree)
[group('elixir')]
ex +args:
    docker run --rm -v {{RAIZ}}/elixir:/src -w /src -u "$(id -u):$(id -g)" \
        -e HOME=/tmp hexpm/elixir:1.18.4-erlang-27.3.4-alpine-3.21.3 \
        sh -c "mix local.hex --force >/dev/null && mix local.rebar --force >/dev/null && {{args}}"

# atualiza mix.lock a partir de mix.exs
[group('elixir')]
ex-deps:
    @just ex mix deps.get

# ==========================================================================
# go — projeto Go + net/http + pgx
#
# Como as receitas `ex-*`, estas NÃO exigem a linguagem instalada no host:
# tudo roda na mesma imagem que o Dockerfile usa para compilar. Ver
# `scripts/go-teste.sh` para o porquê.
# ==========================================================================

# roda `go test` contra um Postgres descartável (sobe e derruba sozinho)
[group('go')]
go-test *args:
    @bash {{RAIZ}}/scripts/go-teste.sh test {{args}}

# derruba o banco de teste, se um `go-test` interrompido o tiver deixado de pé
[group('go')]
go-db-down:
    @bash {{RAIZ}}/scripts/go-teste.sh down

# comando go arbitrário dentro da imagem de build (ex: just go go mod tidy)
[group('go')]
go +args:
    #!/usr/bin/env bash
    set -euo pipefail
    docker volume create rinha-go-cache >/dev/null
    docker run --rm -v rinha-go-cache:/gocache alpine \
        sh -c "mkdir -p /gocache/build /gocache/mod && chown -R $(id -u):$(id -g) /gocache"
    docker run --rm -v {{RAIZ}}/go:/src -w /src -u "$(id -u):$(id -g)" \
        -v rinha-go-cache:/gocache -e HOME=/tmp \
        -e GOCACHE=/gocache/build -e GOMODCACHE=/gocache/mod \
        golang:1.27-alpine {{args}}

# formata, examina e compila — o que rodar antes de commitar
[group('go')]
go-check:
    @just go gofmt -l .
    @just go go vet ./...
    @just go go build -o /dev/null .

# ==========================================================================
# bench — comparativos locais rápidos (SQLite, sem Docker, ferramenta: oha)
#
# NÃO confundir com `just load`, que roda o Gatling contra a stack completa.
# Números destes comandos jamais devem ser comparados com os do Gatling.
# ==========================================================================

# uma rodada única de uma configuração (use bench-serie para números confiáveis)
[group('bench')]
bench-1 config endpoint="extrato" duracao="10s" rps="":
    @bash {{RAIZ}}/scripts/bench-local.sh {{config}} {{endpoint}} {{duracao}} {{rps}}

# série com aquecimento descartado + N repetições — é o comando que gera os docs
[group('bench')]
bench-serie config endpoint="extrato" duracao="10s" reps="3":
    @bash {{RAIZ}}/scripts/bench-serie.sh {{config}} {{endpoint}} {{duracao}} {{reps}}

# crescimento de RSS sob carga (o que um teste de vazão não enxerga)
[group('bench')]
bench-mem config endpoint="extrato" segundos="30":
    @bash {{RAIZ}}/scripts/bench-memoria.sh {{config}} {{endpoint}} {{segundos}}

# reproduz o experimento 01 inteiro: DEBUG vs. produção, runserver vs. gunicorn
[group('bench')]
bench-01:
    #!/usr/bin/env bash
    set -euo pipefail
    for c in runserver-debug runserver-prod gunicorn-1w-debug gunicorn-1w gunicorn-4w; do
        bash {{RAIZ}}/scripts/bench-serie.sh "$c" extrato 10s 3
    done
    bash {{RAIZ}}/scripts/bench-memoria.sh gunicorn-1w extrato 30
    bash {{RAIZ}}/scripts/bench-memoria.sh gunicorn-1w-debug extrato 30
    just bench-tabela

# uma série da API em container sob cota de cgroup
[group('bench')]
bench-cont cpus="0.45" workers="1" rede="bridge" duracao="10s" reps="5" rps="":
    @bash {{RAIZ}}/scripts/bench-container.sh {{cpus}} {{workers}} {{rede}} {{duracao}} {{reps}} {{rps}}

# reproduz o experimento 02: workers sob cota, saturação e taxa fixa
[group('bench')]
bench-02:
    #!/usr/bin/env bash
    set -euo pipefail
    for w in 1 2 4; do
        bash {{RAIZ}}/scripts/bench-container.sh 0.45 "$w" bridge 10s 5
        bash {{RAIZ}}/scripts/bench-container.sh 0.45 "$w" bridge 10s 3 170
    done
    just bench-tabela

# uma série da stack atrás do nginx (rig: nginx-unix | nginx-tcp)
[group('bench')]
bench-stack rig="nginx-unix" cpus="0.45" workers="1" duracao="10s" reps="5" rps="":
    @bash {{RAIZ}}/scripts/bench-stack.sh {{rig}} {{cpus}} {{workers}} {{duracao}} {{reps}} {{rps}}

# reproduz o experimento 03: socket Unix vs TCP no salto nginx->API
[group('bench')]
bench-03:
    #!/usr/bin/env bash
    set -euo pipefail
    for rig in nginx-unix nginx-tcp; do
        bash {{RAIZ}}/scripts/bench-stack.sh "$rig" 0.45 1 10s 5
        bash {{RAIZ}}/scripts/bench-stack.sh "$rig" 0.45 1 10s 3 170
        bash {{RAIZ}}/scripts/bench-stack.sh "$rig" 1.5  1 10s 5
    done
    just bench-tabela

# gera infra/sql/{ddl,dml}.sql a partir do schema real (exige a stack de pé)
[group('django')]
gen-sql:
    @bash {{RAIZ}}/scripts/gerar-sql.sh

# reproduz o experimento 04: Postgres vs SQLite, leitura e escrita
[group('bench')]
bench-04:
    #!/usr/bin/env bash
    set -euo pipefail
    bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.45 1 10s 5
    for w in 1 2 4; do
        BENCH_ENDPOINT=transacoes bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.45 "$w" 10s 5
    done
    for w in 1 4; do
        BENCH_ENDPOINT=transacoes bash {{RAIZ}}/scripts/bench-stack.sh nginx-unix 0.45 "$w" 10s 5
    done
    BENCH_ENDPOINT=transacoes bash {{RAIZ}}/scripts/bench-stack.sh postgres-sem-persistencia 0.45 1 10s 5
    for w in 1 2; do
        BENCH_ENDPOINT=transacoes bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.45 "$w" 10s 3 170
    done
    just bench-tabela

# uma série variando o servidor HTTP (gunicorn-sync | gunicorn-gthread | uvicorn)
[group('bench')]
bench-servidor servidor="gunicorn-sync" threads="4" endpoint="transacoes" cpus="0.40" duracao="10s" reps="5":
    @BENCH_SERVER={{servidor}} BENCH_THREADS={{threads}} BENCH_ENDPOINT={{endpoint}} \
        bash {{RAIZ}}/scripts/bench-stack.sh postgres {{cpus}} 1 {{duracao}} {{reps}}

# reproduz o experimento 06: tipos de worker, com e sem cota de CPU
[group('bench')]
bench-06:
    #!/usr/bin/env bash
    set -euo pipefail
    for e in transacoes extrato; do
        BENCH_SERVER=gunicorn-sync   BENCH_ENDPOINT=$e bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.40 1 10s 5
        BENCH_SERVER=uvicorn         BENCH_ENDPOINT=$e bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.40 1 10s 5
    done
    for t in 2 4 8; do
        BENCH_SERVER=gunicorn-gthread BENCH_THREADS=$t BENCH_ENDPOINT=transacoes \
            bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.40 1 10s 5
    done
    # Sem cota: quanto a restrição está custando, e o que a aplicação entrega solta.
    for s in gunicorn-sync gunicorn-gthread uvicorn; do
        BENCH_SERVER=$s BENCH_ENDPOINT=transacoes \
            bash {{RAIZ}}/scripts/bench-stack.sh postgres-sem-limite 0 1 10s 5
    done
    just bench-tabela

# uma série do FastAPI atrás do nginx (variantes por variável de ambiente)
[group('bench')]
bench-fa endpoint="transacoes" cpus="0.40" duracao="10s" reps="5":
    @BENCH_PROJETO=fastapi BENCH_ENDPOINT={{endpoint}} \
        bash {{RAIZ}}/scripts/bench-stack.sh postgres {{cpus}} 1 {{duracao}} {{reps}}

# reproduz o experimento fastapi/01: linha de base contra o Django e as variantes
[group('bench')]
bench-fa-01:
    #!/usr/bin/env bash
    set -euo pipefail
    export BENCH_PROJETO=fastapi
    # Linha de base: a configuração que espelha o Django o mais de perto
    # possível (validação à mão, extrato em duas queries, orjson).
    for e in transacoes extrato; do
        BENCH_ENDPOINT=$e bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.40 1 10s 5
    done
    # Uma variante por vez, sempre contra a mesma linha de base.
    VALIDACAO=pydantic BENCH_ENDPOINT=transacoes \
        bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.40 1 10s 5
    EXTRATO_QUERY=unica BENCH_ENDPOINT=extrato \
        bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.40 1 10s 5
    SERIALIZACAO=stdlib BENCH_ENDPOINT=extrato \
        bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.40 1 10s 5
    # Sem cota: quanto a restrição está custando, e o que a aplicação entrega
    # solta. Comparável com a série equivalente do Django no experimento 06.
    BENCH_ENDPOINT=transacoes \
        bash {{RAIZ}}/scripts/bench-stack.sh postgres-sem-limite 0 1 10s 5
    just bench-tabela

# uma série do Elixir atrás do nginx (variantes por variável de ambiente)
[group('bench')]
bench-ex endpoint="transacoes" cpus="0.40" duracao="10s" reps="5":
    @BENCH_PROJETO=elixir BENCH_ENDPOINT={{endpoint}} \
        bash {{RAIZ}}/scripts/bench-stack.sh postgres {{cpus}} 1 {{duracao}} {{reps}}

# uma série do Go atrás do nginx (variantes por variável de ambiente)
[group('bench')]
bench-go endpoint="transacoes" cpus="0.40" duracao="10s" reps="5":
    @BENCH_PROJETO=go BENCH_ENDPOINT={{endpoint}} \
        bash {{RAIZ}}/scripts/bench-stack.sh postgres {{cpus}} 1 {{duracao}} {{reps}}

# reproduz o experimento elixir/01: linha de base e as duas armadilhas da BEAM
[group('bench')]
bench-ex-01:
    #!/usr/bin/env bash
    set -euo pipefail
    export BENCH_PROJETO=elixir
    # Linha de base: as duas armadilhas corrigidas (1 scheduler, sem busy-wait),
    # que é o padrão da stack. Comparável com as séries equivalentes do Django
    # (`bench-06`) e do FastAPI (`bench-fa-01`): mesmo rig, mesma cota, mesmo
    # endpoint, mesma duração.
    for e in transacoes extrato; do
        BENCH_ENDPOINT=$e bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.40 1 10s 5
    done
    # Armadilha 1 isolada: a BEAM se dimensionando pelos 20 núcleos VISÍVEIS,
    # dentro de uma cota de 0.40 CPU.
    SCHEDULERS=auto BENCH_ENDPOINT=transacoes \
        bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.40 1 10s 5
    # Armadilha 2 isolada: spin dos schedulers, cobrado pelo cgroup como CPU.
    BUSY_WAIT=default BENCH_ENDPOINT=transacoes \
        bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.40 1 10s 5
    # As duas juntas: a porta ingênua, que é o que sairia sem este experimento.
    SCHEDULERS=auto BUSY_WAIT=default BENCH_ENDPOINT=transacoes \
        bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.40 1 10s 5
    # Variantes de aplicação, uma por vez, contra a mesma linha de base.
    EXTRATO_QUERY=duas BENCH_ENDPOINT=extrato \
        bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.40 1 10s 5
    JSON_LIB=otp BENCH_ENDPOINT=extrato \
        bash {{RAIZ}}/scripts/bench-stack.sh postgres 0.40 1 10s 5
    # Sem cota: quanto a restrição está custando, e onde `SCHEDULERS=auto` deixa
    # de ser armadilha e passa a ser a configuração natural.
    for s in 1 auto; do
        SCHEDULERS=$s BENCH_ENDPOINT=transacoes \
            bash {{RAIZ}}/scripts/bench-stack.sh postgres-sem-limite 0 1 10s 5
    done
    just bench-tabela

# reproduz o experimento elixir/03: as TRÊS stacks sem limitação de hardware
#
# Fora do regulamento de propósito. Dois braços, porque "sem limitação" quer
# dizer duas coisas diferentes numa máquina de 20 núcleos:
#
#   A) 1 processo cada — mede quanto o RUNTIME paraleliza sozinho. Desfavorável
#      ao Python por construção: 1 processo CPython usa 1 núcleo, 1 nó da BEAM
#      usa os 20.
#   B) máquina inteira — cada stack configurada como alguém a subiria de fato.
#
# A restrição dura é `max_connections = 20` no `postgresql.conf`, compartilhado
# pelas três stacks: mudá-lo invalidaria todos os experimentos anteriores. Por
# isso o braço B para em 4 workers e pool 4.
#
# O Elixir recebe `workers=1` nos DOIS braços porque a BEAM não tem esse botão:
# um nó usa a máquina inteira sozinho. O que muda entre os braços dele é só o
# pool, e é isso que o slug registra (`-pool16`). Passar `w4` para o Elixir
# produziria um slug que mente sobre o que subiu.

# as QUATRO stacks sem limitação de hardware, em 20 vCPU (elixir/03, go/04)
[group('bench')]
bench-sem-cota:
    #!/usr/bin/env bash
    set -euo pipefail
    rig=postgres-sem-limite
    # --- braço A: 1 processo cada ---
    for e in transacoes extrato; do
        BENCH_PROJETO=django  BENCH_SERVER=gunicorn-sync BENCH_ENDPOINT=$e \
            bash {{RAIZ}}/scripts/bench-stack.sh $rig 0 1 10s 5
        BENCH_PROJETO=fastapi BENCH_ENDPOINT=$e \
            bash {{RAIZ}}/scripts/bench-stack.sh $rig 0 1 10s 5
        BENCH_PROJETO=elixir  BENCH_ENDPOINT=$e SCHEDULERS=auto \
            bash {{RAIZ}}/scripts/bench-stack.sh $rig 0 1 10s 5
        # GOMAXPROCS=1: um processador lógico, o par do braço A das outras.
        BENCH_PROJETO=go      BENCH_ENDPOINT=$e GOMAXPROCS=1 \
            bash {{RAIZ}}/scripts/bench-stack.sh $rig 0 1 10s 5
    done
    # --- braço B: máquina inteira, dentro de max_connections=20 ---
    for e in transacoes extrato; do
        # 4 workers sync, 1 conexão cada = 4 conexões.
        BENCH_PROJETO=django  BENCH_SERVER=gunicorn-sync BENCH_ENDPOINT=$e \
            bash {{RAIZ}}/scripts/bench-stack.sh $rig 0 4 10s 5
        # 4 workers x pool 4 = 16 conexões.
        BENCH_PROJETO=fastapi BENCH_ENDPOINT=$e DB_POOL_MAX=4 \
            bash {{RAIZ}}/scripts/bench-stack.sh $rig 0 4 10s 5
        # 1 nó, schedulers automáticos, pool 16 = 16 conexões.
        BENCH_PROJETO=elixir  BENCH_ENDPOINT=$e SCHEDULERS=auto DB_POOL_MAX=16 \
            bash {{RAIZ}}/scripts/bench-stack.sh $rig 0 1 10s 5
        # GOMAXPROCS=auto (os 20 núcleos, sem cota) e pool 16, como o Elixir.
        BENCH_PROJETO=go      BENCH_ENDPOINT=$e DB_POOL_MAX=16 \
            bash {{RAIZ}}/scripts/bench-stack.sh $rig 0 1 10s 5
    done
    just bench-tabela

# DIAGNÓSTICO (fora da metodologia de medição): os statements estão sendo
# reusados ou replanejados? Decide a hipótese aberta em performance/elixir/01,
# seção 5.4, comparando `plans` com `calls` no pg_stat_statements.
[group('bench')]
diag-prepared proj endpoint="extrato":
    @bash {{RAIZ}}/scripts/diag-prepared.sh {{proj}} {{endpoint}}


# imprime a tabela comparativa das séries já executadas
[group('bench')]
bench-tabela:
    @python3 {{RAIZ}}/scripts/bench-tabela.py {{RESULTADOS}}/bench

# ==========================================================================
# setup — preparação do ambiente
# ==========================================================================

# verifica se o ferramental necessário está disponível
[group('setup')]
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    ok=0
    chk() { if command -v "$1" >/dev/null 2>&1; then printf '  ✓ %-10s %s\n' "$1" "$($2 2>&1 | head -1)"; else printf '  ✗ %-10s AUSENTE\n' "$1"; ok=1; fi; }
    echo "ferramental:"
    chk docker "docker --version"
    chk just   "just --version"
    chk uv     "uv --version"
    chk java   "java -version"
    chk python3 "python3 --version"
    echo "docker engine:"
    docker info --format '  ✓ engine {{{{.ServerVersion}} — {{{{.NCPU}} CPUs' 2>/dev/null || { echo "  ✗ engine inacessível"; ok=1; }
    echo "gatling:"
    # A partir da 3.13 o bundle virou um projeto Maven: não há mais
    # bin/gatling.sh. O que precisa existir é o projeto em gatling/.
    if [[ -x "{{RAIZ}}/gatling/mvnw" ]]; then
        echo "  ✓ {{RAIZ}}/gatling (projeto Maven, $(grep -o '<gatling.version>[^<]*' {{RAIZ}}/gatling/pom.xml | cut -d'>' -f2))"
    else
        echo "  ✗ projeto de carga ausente em {{RAIZ}}/gatling"; ok=1
    fi
    echo "gerador de carga rápido:"
    command -v oha >/dev/null 2>&1 && echo "  ✓ oha $(oha --version | awk '{print $2}')" || { echo "  ✗ oha ausente (cargo install oha)"; ok=1; }
    echo "repo oficial:"
    [[ -d "{{OFICIAL}}" ]] && echo "  ✓ {{OFICIAL}}" || { echo "  ✗ ausente"; ok=1; }
    exit $ok

# remove containers e volumes órfãos do projeto
[group('setup')]
clean:
    docker ps -aq --filter "label=com.docker.compose.project" | xargs -r docker rm -f
    docker volume prune -f
