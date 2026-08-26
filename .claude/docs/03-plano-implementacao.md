# 03 — Plano de implementação e experimentação

Este é o documento de trabalho: o que vamos construir, em que ordem, e como
comparar os resultados.

---

## 1. Princípio organizador

Cada implementação é uma **variante** identificada por um slug, ex.:
`django-postgres-sync`. Todas as variantes:

- expõem o mesmo contrato HTTP (doc 02)
- respeitam os mesmos limites de recursos
- sobem com o mesmo comando (`just up <variante>`)
- são testadas com a mesma simulação
- gravam resultado em `resultados/<variante>/<timestamp>/`

Isso torna a comparação honesta: **uma variável por vez**.

---

## 2. Estrutura de diretórios

Repositório **único** na raiz `rinha-backend-2024/`. Justificativa em
`04-aprendizados.md`; em resumo: o valor do projeto está na comparação entre
variantes, e isso exige infra compartilhada e resultados lado a lado.

```
rinha-backend-2024/                  <- raiz do repositório git
├─ .claude/
│  ├─ docs/                          # estes documentos
│  └─ memory/                        # memória de trabalho do projeto
├─ rinha-de-backend-2024-q1/         # repo oficial — NO .gitignore, read-only
├─ infra/
│  ├─ nginx/nginx.conf               # LB compartilhado
│  └─ sql/postgres-init.sql          # DDL + seed dos 5 clientes
├─ rinha-back-2024-django/           # uma pasta por projeto/framework
│  ├─ docker-compose.yml
│  ├─ Dockerfile
│  └─ app/
├─ rinha-back-2024-fastapi/
├─ rinha-back-2024-go/
├─ resultados/
│  └─ <variante>/<timestamp>/        # relatório Gatling + metadata.json
├─ scripts/
│  ├─ smoke-test.sh                  # validação funcional rápida (segundos)
│  └─ coletar-metricas.sh
└─ justfile
```

### Projeto vs. variante

Um **projeto** é uma pasta de framework (`rinha-back-2024-django`). Uma
**variante** é uma configuração testável dentro dele — Django com ORM, Django com
SQL cru, Django com SQLite. Não faz sentido uma pasta inteira por variante:
mudam poucos arquivos entre elas.

Padrão sugerido: um `docker-compose.yml` base por projeto mais overrides:

```
rinha-back-2024-django/
├─ docker-compose.yml                # base: nginx + 2 apis + postgres
├─ compose.sqlite.yml                # override: troca o serviço de banco
├─ compose.raw-sql.yml               # override: variável de ambiente
└─ app/
```

E a variante é resolvida pelo justfile:
```
just run django              # base
just run django sqlite       # base + compose.sqlite.yml
just run django raw-sql
```

Slug da variante para efeito de resultados: `<projeto>-<override>` →
`django-sqlite`. Assim `resultados/` fica plano e comparável.

> **Regra**: nunca editar `rinha-de-backend-2024-q1/`. É a fonte da verdade e a
> simulação precisa permanecer intacta para os resultados serem comparáveis
> entre si.

## Estado do plano — o que foi feito e o que não foi

> **Este documento é o plano original, escrito antes da primeira medição.** O
> caminho real divergiu, e a tabela abaixo reconcilia os dois. Os experimentos
> executados estão em [`performance/`](./performance/00-indice.md), numerados
> cronologicamente.

| Bloco | Estado | Onde |
| - | - | - |
| **A1** ORM + `select_for_update` | **não feito** — fomos direto ao SQL cru | — |
| **A2** `UPDATE ... RETURNING` | feito, é a implementação do projeto | `crebitos/models.py` |
| **A3** Configuração tunada | feito | [04](./performance/django/04-postgres.md), [05](./performance/django/05-stack-completa-gatling.md) |
| **B** Estratégias de concorrência | **feito** em 2026-08-25, no projeto Go | [go/05](./performance/go/05-bloco-b-estrategias-de-concorrencia.md) |
| **C1/C2** Postgres vs. SQLite | feito | [04](./performance/django/04-postgres.md) |
| **C3/C4** MySQL, Mongo | não feito | — |
| **D1** FastAPI | feito | [fastapi/01](./performance/fastapi/01-fastapi-async.md) a [03](./performance/fastapi/03-o-que-a-troca-de-framework-comprou.md) |
| **D2** Django async | **não feito** — medido só como tipo de worker | [django/06](./performance/django/06-tipos-de-worker.md) |
| **D3** Go + pgx | feito, e é a stack mais barata das quatro | [go/01](./performance/go/01-a-aplicacao-sai-da-frente.md) a [05](./performance/go/05-bloco-b-estrategias-de-concorrencia.md) |
| **D4/D5** Rust, Node | não feitos — e o Go já responde "compilado sem VM" | — |
| **Elixir** (fora do plano original) | feito | [elixir/01](./performance/elixir/01-a-beam-sob-cota.md) a [04](./performance/elixir/04-o-statement-que-nao-era-reusado.md) |
| **E** Infraestrutura | feito em parte: nginx, socket Unix, distribuição de cota | [03](./performance/django/03-nginx-e-socket-unix.md), [05](./performance/django/05-stack-completa-gatling.md) |

**O Bloco B era a maior lacuna, e foi fechado em 2026-08-25** —
[go/05](./performance/go/05-bloco-b-estrategias-de-concorrencia.md). As quatro
estratégias foram implementadas no projeto Go (a stack mais barata, onde o custo
da estratégia aparece limpo), testadas contra as mesmas asserções de
concorrência e medidas sob contenção máxima.

**A hipótese estava certa na direção e errada no tamanho**: o `UPDATE` atômico
vence, mas por **9% a 15%** sobre `SELECT FOR UPDATE` e advisory lock — não "por
larga margem". A margem larga (3,57x) existe só contra a estratégia otimista, e
no pior caso possível para ela.

Duas coisas do plano que a prática mostrou estarem erradas:

- A ordem sugerida na seção 7 previa **instalar o Gatling primeiro** e validar o
  pipeline com uma API errada de propósito. Na prática o Gatling entrou só no
  quinto experimento, e o papel de "ver o relatório acusando falhas" acabou
  sendo cumprido de graça pelo colapso do uvicorn no experimento 06.
- O plano não previa um **segundo gerador de carga**. O `oha` acabou sendo o
  instrumento principal, porque a pontuação do Gatling satura e não compara.

---

## 3. Matriz de variantes

Ordem pensada para maximizar aprendizado, não para maximizar pontuação.

### Bloco A — Baseline e fundamentos

| # | Variante | O que isola |
| - | - | - |
| A1 | `django-postgres-orm` | Baseline honesto. Django "do jeito Django": ORM, `select_for_update`, gunicorn sync |
| A2 | `django-postgres-raw` | Mesma stack, `UPDATE ... RETURNING` em SQL cru. **Isola o custo do ORM** |
| A3 | `django-postgres-tuned` | A2 + pool (pgbouncer ou `CONN_MAX_AGE`), gunicorn tunado, Postgres tunado. **Isola o custo de configuração** |

> A1 → A2 → A3 é a espinha dorsal do aprendizado. Cada passo muda **uma** coisa.

### Bloco B — Estratégias de concorrência (fixando Django+Postgres)

| # | Variante | Estratégia |
| - | - | - |
| B1 | `conc-select-for-update` | Lock pessimista |
| B2 | `conc-update-returning` | Update atômico condicional |
| B3 | `conc-optimistic` | Coluna de versão + retry |
| B4 | `conc-advisory-lock` | `pg_advisory_xact_lock` por cliente |

Objetivo: medir o custo de cada estratégia sob contenção alta. Espero que B2
vença por larga margem — mas medir é diferente de supor.

### Bloco C — Banco de dados (fixando Django + melhor estratégia)

| # | Variante | Observação |
| - | - | - |
| C1 | `db-postgres` | Referência |
| C2 | `db-sqlite` | **Ver ressalva abaixo** |
| C3 | `db-mysql` / `mariadb` | Comparação relacional |
| C4 | `db-mongo` | Documento; transação atômica via `findAndModify` |

> **Ressalva sobre SQLite**: com 2 instâncias de API, o arquivo precisa estar num
> volume compartilhado, e o lock de escrita global do SQLite serializa toda a
> carga. Além disso é discutível se atende ao espírito da arquitetura mínima.
> **Vale rodar mesmo assim** — é um experimento pedagógico excelente sobre o custo
> de serialização total, e o relatório vai mostrar exatamente onde ele quebra.
> Só não espere um bom resultado. Usar WAL mode para não ser injusto.

### Bloco D — Frameworks / runtimes

| # | Variante | O que isola |
| - | - | - |
| D1 | `fastapi-postgres` | Python async vs. Django sync, mesma linguagem |
| D2 | `django-async` | ASGI + uvicorn, ainda Django |
| D3 | `go-postgres` | Runtime compilado, goroutines |
| D4 | `rust-axum-postgres` | Teto prático de performance |
| D5 | `node-fastify-postgres` | Event loop single-thread |

### Bloco E — Infraestrutura

| # | Experimento |
| - | - |
| E1 | nginx vs. HAProxy |
| E2 | rede `bridge` vs. `host` |
| E3 | Distribuição de CPU: API-pesada (0.6/0.6/0.15/0.15) vs. DB-pesada (0.4/0.4/0.15/0.55) |
| E4 | `synchronous_commit = off` no Postgres |
| E5 | Unix socket vs. TCP entre nginx e API |

---

## 4. Interface do justfile

Esboço da API de comandos. Implementação vem depois.

```just
# --- ciclo principal ---
build    <proj> [var]     # docker compose build
up       <proj> [var]     # sobe e espera prontidão (max 40s)
down     <proj> [var]     # derruba e limpa volumes (-v sempre)
smoke    <proj> [var]     # validação funcional rápida (~5s)
load     <proj> [var]     # roda Gatling e salva em resultados/
run      <proj> [var]     # up + smoke + load + down  (o comando do dia a dia)
logs     <proj> [var]

# --- análise ---
report   <variante>       # abre o último relatório HTML
score    <variante>       # calcula a pontuação da Rinha a partir do simulation.log
diag     <variante>       # diagnóstico: onde está a fraqueza?
compare  <v1> <v2> ...    # tabela comparativa
stats    <variante>       # docker stats + throttling do cgroup ao vivo

# --- utilitários ---
check    <variante>       # valida limites do compose (<=1.5 CPU, <=550MB)
clean                     # remove containers/volumes órfãos
```

Uso típico:
```
just run django raw-sql
just compare django-orm django-raw-sql django-sqlite
```

### Por que `smoke` antes de `load`

O teste do Gatling leva **4 minutos**. Rodá-lo para descobrir que a API retorna
201 em vez de 200 é desperdício. O `smoke` roda o checklist funcional do doc 02
com `curl` em segundos e falha rápido. **`just run` sempre executa smoke antes de
load**, e aborta se o smoke falhar.

---

## 5. Metodologia de diagnóstico

O ponto que você levantou — *"a fraqueza está na velocidade? na concorrência? na
consistência?"* — merece um procedimento explícito.

### As três perguntas, em ordem de prioridade

**Pergunta 1 — Está correto?**

Fonte: falhas em `validações` e `ConsistenciaSaldoLimite` no relatório.

| Sintoma | Diagnóstico |
| - | - |
| Saldo != -25 na fase de concorrência | **Lost update.** Read-modify-write não atômico |
| `ConsistenciaSaldoLimite` falha durante a carga | Validação de limite tem janela de corrida |
| Falha nos 5 GETs paralelos pós-POST | Falta read-your-writes: cache, réplica ou write-behind |
| Falha na ordem de `ultimas_transacoes` | `ORDER BY` errado, ou timestamps com resolução insuficiente para empatar |
| Falha nos payloads inválidos | Validação de entrada incompleta |

> Enquanto houver qualquer falha aqui, **não olhe para latência**. Uma
> implementação incorreta e rápida vale menos que uma correta e lenta.

**Pergunta 2 — É rápido o bastante?**

Fonte: distribuição de percentis por request no relatório Gatling.

| Sintoma | Diagnóstico provável |
| - | - |
| p50 alto e p99 proporcional (cauda "achatada") | Custo constante por requisição: overhead de framework, query ineficiente, falta de índice. **Otimize o caminho quente** |
| p50 baixo e p99 muito alto (cauda longa) | Fila. Contenção de lock, pool esgotado, ou throttling de CPU |
| Latência **cresce monotonicamente** ao longo do teste | **Saturação**: taxa de atendimento < taxa de chegada. Você não escoa a carga. Fatal no open model |
| Degrau abrupto ao atingir certo RPS | Achou o joelho da curva. Algum recurso saturou naquele ponto |
| Serrilhado periódico (~100ms) | **Throttling de cgroup.** Confirme com `nr_throttled` |
| Só `extratos` lento | Query de leitura cara. Falta índice em `(cliente_id, realizada_em DESC)` |
| Só `débitos` lento (créditos ok) | Contenção no caminho de validação de limite |

**Pergunta 3 — Onde está o recurso saturado?**

Método USE: para cada recurso, medir Utilização, Saturação e Erros.

| Recurso | Como medir | Sinal de saturação |
| - | - | - |
| CPU da API | `docker stats`, `cpu.stat` do cgroup | `nr_throttled` crescendo |
| CPU do banco | idem | idem |
| Memória | `docker stats`, `docker inspect` | `OOMKilled: true` |
| Pool de conexões | métricas da app / `pg_stat_activity` | Threads esperando conexão |
| Locks do banco | `pg_locks`, `pg_stat_activity` com `wait_event` | Muitos `Lock` waits |
| Rede | modo bridge vs. host | Ganho ao trocar para host |

### Regra de bissecção

Quando não souber onde está o problema, **remova componentes**:

1. Bata direto numa instância de API (bypass do nginx) → isola o LB
2. Substitua o handler por um retorno estático → isola o banco
3. Rode a query direto no `psql` sob carga → isola a aplicação
4. Suba um único container de API sem limite de CPU → isola o cgroup

Cada passo responde "o gargalo está antes ou depois daqui?".

---

## 6. Metadados de cada execução

Toda rodada grava `resultados/<variante>/<timestamp>/metadata.json`:

```json
{
  "variante": "django-postgres-raw",
  "timestamp": "2026-08-20T17:30:00-03:00",
  "git_commit": "abc1234",
  "descricao": "UPDATE ... RETURNING, gunicorn 4 workers sync",
  "recursos": { "api01": {"cpus": "0.45", "memory": "100MB"} },
  "host": { "cpus": 20, "memoria_gb": 31, "docker": "29.6.2" },
  "gatling": "3.15.1",
  "resultado": {
    "requisicoes_total": 61503,
    "pct_abaixo_250ms": 99.1,
    "inconsistencias": 0,
    "erros": 0,
    "p50_ms": 3, "p95_ms": 41, "p98_ms": 88, "p99_ms": 160,
    "multa_sla_usd": 0,
    "multa_consistencia_usd": 0,
    "pontuacao_usd": 100000
  }
}
```

Sem isso, em duas semanas você não lembra o que diferenciava a rodada 7 da 8.
Esse arquivo é o que alimenta `just compare`.

---

## 7. Ordem de trabalho sugerida

1. **Infra base**: `infra/nginx.conf`, `infra/sql/`, justfile esqueleto,
   `scripts/smoke-test.sh`. Nada específico de framework ainda.
2. **Instalar Gatling** e validar o pipeline com uma API trivialmente errada
   (só para ver o relatório acusando falhas — aprender a ler a saída).
3. **A1 `django-postgres-orm`**: baseline. Provavelmente vai pontuar mal. Tudo bem;
   é o ponto de partida.
4. **Ler o relatório com calma** aplicando a metodologia da seção 5. Registrar
   no doc 04.
5. **A2, A3**: uma mudança por vez, medindo cada uma.
6. Blocos B, C, D, E conforme o interesse.

---

## 8. Armadilhas conhecidas

- **Não confie no `deploy.resources.limits` sem verificar.** Confirme com
  `docker stats` que o limite está ativo.
- **Warm-up**: o script oficial faz 2 requisições antes de começar; runtimes com
  JIT (JVM, .NET) precisam de mais. O ramp de 2 minutos ajuda, mas registre se
  a variante for sensível a cold start.
- **Rode cada variante mais de uma vez.** Variação entre execuções na mesma
  máquina pode ser de 10-20%. Uma diferença de 5% entre variantes é ruído.
- **Feche coisas pesadas durante o teste** (navegador, IDE indexando). Você tem
  20 vCPUs, mas o Gatling é faminto.
- **Volumes de banco entre execuções**: sempre derrube com `-v`. Um banco com
  dados da execução anterior falsifica a fase de validação (saldo inicial != 0).
