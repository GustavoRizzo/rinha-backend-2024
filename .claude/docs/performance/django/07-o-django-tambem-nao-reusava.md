# django/07 — O Django também não reusava statements. E não fez diferença.

Este experimento fecha a última ação decorrente aberta em
[`elixir/04`](../elixir/04-o-statement-que-nao-era-reusado.md): *"rodar
`just diag-prepared django` — o Django usa psycopg com SQL cru, e ninguém
conferiu se ele reusa statements. Se não reusar, parte dos 862 µs da escrita e
dos 1258 µs da leitura é o mesmo problema."*

**Não reusava. E ao contrário do Elixir, isso não custava praticamente nada.**

O motivo dessa diferença é o resultado que vale ser lido: o mesmo defeito custa
3,97x numa stack e ~0 na outra, porque o gargalo delas está em lugares
diferentes.

---

## 1. Ressalvas metodológicas

1. **O diagnóstico não é benchmark.** `pg_stat_statements` roda com uma
   configuração de Postgres que nenhuma stack usa, e a extensão tem custo
   próprio. Os números de `calls` e `plans` valem como **razão**, nunca como
   vazão.
2. **A linha de base foi re-executada hoje** para a comparação ser do mesmo dia
   e do mesmo commit. Ela deu **894,5 µs** na escrita contra os **862,4 µs**
   publicados em [`06`](./06-tipos-de-worker.md) — 3,7% de diferença entre dias,
   com amplitude interna de 2,3%. É o tamanho da variação dia-a-dia deste host,
   e vale como aviso para todas as comparações entre documentos deste
   repositório.
3. **Três braços, uma variável por vez — quase.** O terceiro braço muda *duas*
   coisas em relação à base (prepared + health check), de propósito: ele existe
   para separar o efeito do `SELECT 1`, e é comparado com o segundo, não com o
   primeiro.
4. **Sem prova oficial.** O Gatling não foi re-executado: nenhum dos ganhos
   medidos aqui muda a pontuação, que já satura.

---

## 2. Ambiente e commit

| | |
| - | - |
| commit | `592feea` (variantes) |
| Django / psycopg | 6.1 / **3.3.4** |
| rig | `django/compose.bench-postgres.yml`, API 0.40 CPU, banco 0.60 |
| instrumento novo | `django/compose.bench-diag.yml` |
| variantes novas | `DB_PREPARED`, `DB_HEALTH_CHECKS` |

---

## 3. Comandos para replicar

```bash
just diag-prepared django extrato
just diag-prepared django transacoes
DB_PREPARED=1 just diag-prepared django extrato

for e in transacoes extrato; do
  BENCH_PROJETO=django BENCH_SERVER=gunicorn-sync BENCH_ENDPOINT=$e \
    bash scripts/bench-stack.sh postgres 0.40 1 10s 5
  BENCH_PROJETO=django BENCH_SERVER=gunicorn-sync BENCH_ENDPOINT=$e DB_PREPARED=1 \
    bash scripts/bench-stack.sh postgres 0.40 1 10s 5
  BENCH_PROJETO=django BENCH_SERVER=gunicorn-sync BENCH_ENDPOINT=$e DB_PREPARED=1 DB_HEALTH_CHECKS=0 \
    bash scripts/bench-stack.sh postgres 0.40 1 10s 5
done
```

---

## 4. O diagnóstico

### 4.1 `plans = calls`, exatamente, nos dois endpoints

**Extrato**, 10 segundos de carga:

| query | `calls` | `plans` | ms planejando | ms executando | **% planejando** |
| - | - | - | - | - | - |
| `SELECT ... crebitos_transacao ...` | 3.910 | **3.910** | 100,7 | 110,0 | **47,8%** |
| `SELECT ... crebitos_cliente ...` | 3.909 | **3.909** | 81,5 | 75,0 | **52,1%** |
| `SELECT $1` | 3.910 | **3.910** | 24,9 | 8,9 | 73,6% |

**Transações**:

| query | `calls` | `plans` | **% planejando** |
| - | - | - | - |
| `UPDATE crebitos_cliente ...` | 4.997 | **4.997** | **54,4%** |
| `INSERT INTO crebitos_transacao ...` | 4.998 | **4.998** | **44,3%** |
| `SELECT $1` | 4.997 | **4.997** | 73,5% |
| `COMMIT` / `BEGIN` | 4.998 / 4.997 | 0 | — |

`1.000` plano por chamada. **Quase metade do trabalho do banco era
planejamento** — a mesma assinatura que o Elixir tinha antes da correção
(9.122 planos para 9.122 chamadas, 62,2%).

### 4.2 A causa, conferida no fonte — e são DUAS

**Primeira**: o Django desliga prepared statements de propósito.
`django/db/backends/postgresql/base.py:310-314`:

```python
if is_psycopg3:
    ...
    # Disable prepared statements by default to keep connection poolers
    # working. Can be reenabled via OPTIONS in the settings dict.
    conn_params["prepare_threshold"] = conn_params.pop("prepare_threshold", None)
```

`prepare_threshold=None` desliga o preparo automático do psycopg3. **É decisão
deliberada e defensável**: um pgbouncer em modo *transaction* quebra com
statements nomeados, porque a conexão que preparou não é a que executa. O Django
escolhe o padrão que não quebra ninguém.

**Segunda, e sem ela a primeira não basta**: o cursor padrão é o `ClientCursor`
(mesma função, linhas 289-296), que **interpola os parâmetros no texto do SQL**
antes de enviá-lo. Um SQL cujo texto muda a cada requisição nunca vira statement
reusável, com ou sem `prepare_threshold`. É preciso `server_side_binding: True`
para trocar o cursor.

Ligando as duas (`DB_PREPARED=1`), o mesmo diagnóstico marca **`plans = 0`**.

### 4.3 O achado lateral: um `SELECT 1` por requisição

O `SELECT $1` das tabelas acima tem **exatamente uma chamada por requisição do
endpoint**, e não estava previsto em lugar nenhum. É o `CONN_HEALTH_CHECKS: True`
de `kernel/settings.py`: com conexão persistente, o Django valida a conexão no
início de cada requisição.

Não é gratuito — é um round-trip inteiro por requisição, pago pela **API**, que
é onde o Django tem o gargalo.

---

## 5. O efeito, medido

API 0.40 CPU, banco 0.60, `oha` 10s × 5 repetições, aquecimento descartado.

### Escrita — `POST /clientes/1/transacoes`

| variante | rps | CPU da API | **CPU do banco** | API congelada | banco congelado |
| - | - | - | - | - | - |
| linha de base | 468,0 | 894,5 µs | 411,3 µs | 94,4% | **0,0%** |
| `DB_PREPARED=1` | 478,4 (1,02x) | 876,4 µs | **289,5 µs (1,42x)** | 96,2% | 0,0% |
| `+ DB_HEALTH_CHECKS=0` | **515,0 (1,10x)** | **808,1 µs (1,11x)** | **254,3 µs (1,62x)** | 95,3% | 0,0% |

### Leitura — `GET /clientes/1/extrato`

| variante | rps | CPU da API | **CPU do banco** | API congelada | banco congelado |
| - | - | - | - | - | - |
| linha de base | 340,3 | 1243,7 µs | 359,0 µs | 95,3% | **0,0%** |
| `DB_PREPARED=1` | 342,8 (1,01x) | 1239,4 µs | **257,3 µs (1,40x)** | 96,2% | 0,0% |
| `+ DB_HEALTH_CHECKS=0` | **367,4 (1,08x)** | **1141,6 µs (1,09x)** | **218,1 µs (1,65x)** | 96,2% | 0,0% |

---

## 6. Conclusões

### 6.1 Reusar statements deixou o banco 1,4x mais barato e a vazão igual

**1 a 2% de vazão, com amplitude de 2,3% a 4,0%: não é atribuível.** O que mudou
de verdade foi a CPU do **banco** — 1,42x na escrita e 1,40x na leitura.

E o banco do Django está **ocioso**: 0,0% de períodos congelados nas seis
séries, contra 94–96% da API. Baratear quem não é a parede não move a parede.

### 6.2 Por que o mesmo defeito custou 3,97x ao Elixir e ~0 ao Django

Este é o resultado que vale o experimento.

| | Elixir (antes da correção) | Django |
| - | - | - |
| `plans / calls` | 1,000 | 1,000 |
| % do tempo de banco planejando | 62,2% | 44–54% |
| **quem estava congelado** | **o banco, 94,4%** | **a API, 94–96%** |
| ganho ao corrigir | **2,02x de vazão** | 1,01–1,02x |

**O mesmo bug, com a mesma assinatura, na mesma ferramenta de diagnóstico.** O
que muda é onde estava o gargalo: o Elixir tinha uma aplicação barata e um banco
saturado, então devolver 62% do trabalho do banco virou vazão direta; o Django
tem uma aplicação cara e um banco folgado, e devolver 48% do trabalho de um
recurso ocioso não muda nada.

**Regra derivada**: *o valor de uma correção não é o tamanho do desperdício que
ela elimina — é o quanto o recurso liberado era escasso.* O desperdício do
Django é maior em números absolutos de µs do que era o do Elixir na escrita, e
vale menos.

### 6.3 O `SELECT 1` vale mais que os prepared statements

8 a 10% de vazão e ~1,1x de CPU da API, contra 1-2% dos statements. Porque ele é
pago **na API**, que é o recurso escasso desta stack — a mesma lógica de 6.2, no
sentido inverso.

**Não vira padrão**, e a razão não é desempenho: `CONN_HEALTH_CHECKS` existe para
que uma conexão persistente derrubada pelo servidor seja descoberta antes da
query, e não durante. Trocar isso por 10% num teste de 4 minutos seria vender uma
garantia de produção por um número de bancada. Fica como variante documentada.

### 6.4 Os números publicados do Django continuam válidos

Os 862 µs da escrita e os 1258 µs da leitura, citados em
[`06`](./06-tipos-de-worker.md), [`fastapi/03`](../fastapi/03-o-que-a-troca-de-framework-comprou.md)
e [`go/03`](../go/03-quatro-stacks-quatro-linguagens.md), **não mudam**: o
defeito estava no banco, e o que aqueles documentos publicam é CPU da API.

O que muda é uma nota de rodapé honesta: nas tabelas comparativas, a CPU do
banco do Django estava 1,4x inflada por um padrão do framework — e ninguém tinha
percebido porque a série do Django é antiga demais para ter coletado o cgroup do
banco.

---

## 7. Ações decorrentes

- [x] `DB_PREPARED` e `DB_HEALTH_CHECKS` como variantes, com o padrão preservando
      o comportamento das séries publicadas.
- [x] `django/compose.bench-diag.yml`, que faltava — o Django era o único
      projeto sem rig de diagnóstico.
- [ ] Decidir se `DB_PREPARED=1` vira padrão. A favor: 1,4x de CPU de banco de
      graça, e esta stack não tem pgbouncer. Contra: muda a stack que todas as
      séries publicadas mediram, e o ganho é em recurso ocioso. **Se virar
      padrão, o marcador `-prep` precisa entrar no slug SEMPRE** — a lição do
      perfil do FastAPI com `EXTRATO_QUERY`.
- [ ] Conferir o mesmo no FastAPI: `asyncpg` prepara por padrão, e o
      [`elixir/04`](../elixir/04-o-statement-que-nao-era-reusado.md) mediu
      `plans = 0` para ele — mas ninguém conferiu se há um health check
      equivalente ao `SELECT 1` no caminho quente.
