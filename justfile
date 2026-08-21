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
GATLING_HOME := env_var_or_default("GATLING_HOME", home_directory() / "gatling")

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
    @bash {{RAIZ}}/scripts/rodar-carga.sh "$(just _slug {{proj}} {{var}})"

# o comando do dia a dia: up -> smoke -> load -> down
[group('ciclo')]
run proj var="":
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'just down {{proj}} {{var}}' EXIT
    just up {{proj}} {{var}}
    just smoke {{proj}} {{var}}
    just load {{proj}} {{var}}

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
    if [[ -x "{{GATLING_HOME}}/bin/gatling.sh" ]]; then
        echo "  ✓ {{GATLING_HOME}}"
    else
        echo "  ✗ não encontrado em {{GATLING_HOME}} (defina GATLING_HOME)"; ok=1
    fi
    echo "repo oficial:"
    [[ -d "{{OFICIAL}}" ]] && echo "  ✓ {{OFICIAL}}" || { echo "  ✗ ausente"; ok=1; }
    exit $ok

# remove containers e volumes órfãos do projeto
[group('setup')]
clean:
    docker ps -aq --filter "label=com.docker.compose.project" | xargs -r docker rm -f
    docker volume prune -f
