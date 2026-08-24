# fastapi/01 — FastAPI + asyncpg: async de ponta a ponta

Fecha a pendência aberta em [`django/06`, seção 9](../django/06-tipos-de-worker.md):
*"FastAPI com views `async` e `asyncpg` — async de ponta a ponta, que é o teste
que este experimento não fez"*.

---

## 1. Ressalvas metodológicas

**O que este teste mede.** O custo em CPU de uma requisição, sob cota de cgroup,
com a aplicação saturada. A métrica principal é **µs de CPU por requisição**
(`cpu.stat` do cgroup ÷ respostas), não rps: sob cota, vazão é consequência —
cota ÷ custo.

**O que este teste NÃO mede.**

- **Não mede pontuação.** A stack Django já marca USD 100.000 com p98 de 7ms
  contra um SLA de 250ms — 35x de folga. Não existe nota acima do teto, e
  nenhum número aqui pode melhorá-la. A prova oficial (Gatling) roda no fim
  apenas para confirmar que a implementação é **correta**, não para comparar.
- **Não isola o driver.** A comparação é Django+psycopg contra
  FastAPI+asyncpg — dois frameworks e dois drivers de uma vez. É uma violação
  consciente do "uma variável por vez": medir FastAPI+psycopg custaria uma
  terceira implementação, e a pergunta que interessa é sobre a *pilha*, não
  sobre o driver isolado. Onde isso importa para a conclusão, está dito.
- **Não é o ambiente da competição.** 20 vCPU e 31GB, contra 4 vCPU no servidor
  oficial, e o gerador de carga não disputa CPU com a aplicação aqui.
- **`oha` não é o Gatling.** Números destas duas ferramentas **nunca** devem ser
  comparados entre si. Ver `04-aprendizados.md`.
- **Rig de uma instância.** O rig de bancada tem UMA API, não duas. Mede custo
  por requisição, não a stack de produção.

**O que foi mantido idêntico ao Django**, para que a diferença seja atribuível:
mesmo schema (`infra/sql/ddl.sql`), mesmo `postgresql.conf`, mesmo nginx e mesmo
socket Unix, mesma cota (0.40 CPU na API), mesmo endpoint, mesma duração, mesma
concorrência, mesmo estado inicial (50 transações por cliente) e a mesma
estratégia de concorrência — o `UPDATE` atômico condicional com `RETURNING`.

---

## 2. Ambiente e commit

| Item | Valor |
| - | - |
| Commit (FastAPI) | `2df750f` |
| Commit (Django, séries de referência) | `762808f` |
| Host | 20 vCPU, 31GB, kernel 6.6.87.2-microsoft-standard-WSL2 |
| Docker | 29.6.2 |
| Gerador de carga | `oha` 1.15.0 |
| Python | 3.14.6 nos dois projetos |
| Django | 6.1 + gunicorn sync + psycopg 3.3.4 |
| FastAPI | 0.141.1 + uvicorn 0.52.4 (uvloop 0.22.1, httptools 0.8.0) + asyncpg 0.31.0 |
| Postgres | 18-alpine, `synchronous_commit = off`, `max_connections = 20` |

Rig: nginx (0.15 CPU) + 1 API (0.40 CPU) + Postgres (0.6 CPU), socket Unix entre
nginx e API. 10s por repetição, 5 repetições, aquecimento descartado,
concorrência 50, modelo fechado (saturação).

---

## 3. Comandos para replicar

```bash
# linha de base do FastAPI (escrita e leitura)
just bench-fa transacoes
just bench-fa extrato

# as variantes, uma por vez
BENCH_PROJETO=fastapi VALIDACAO=pydantic BENCH_ENDPOINT=transacoes \
    bash scripts/bench-stack.sh postgres 0.40 1 10s 5
BENCH_PROJETO=fastapi EXTRATO_QUERY=unica BENCH_ENDPOINT=extrato \
    bash scripts/bench-stack.sh postgres 0.40 1 10s 5

# o experimento inteiro
just bench-fa-01

# a série de referência do Django, no MESMO rig e na MESMA cota
BENCH_ENDPOINT=transacoes bash scripts/bench-stack.sh postgres 0.40 1 10s 5
```

---

## 4. Resultados

Todas as séries: `oha` 1.15.0, 10s por repetição, 5 repetições, aquecimento
descartado, concorrência 50, modelo fechado (saturação), API em 0.40 CPU com 1
worker. "ampl%" é a amplitude entre as repetições — abaixo de ~3% é ruído.

### 4.1 Escrita — `POST /clientes/1/transacoes`

| configuração | µs CPU/req | ampl% | rps | p50 ms | p99 ms | períodos throttlados |
| - | - | - | - | - | - | - |
| Django, gunicorn sync | 862,4 | 5,3 | 483,9 | 102,2 | 166,3 | 95,3% |
| **FastAPI, validação manual** | **499,7** | 2,1 | 822,6 | 80,7 | 177,8 | 94,3% |
| FastAPI, validação pydantic | 512,7 | 3,7 | 807,7 | 82,0 | 184,3 | 92,6% |

### 4.2 Leitura — `GET /clientes/1/extrato` (10 transações no corpo)

| configuração | µs CPU/req | ampl% | rps | p50 ms | p99 ms | períodos throttlados |
| - | - | - | - | - | - | - |
| Django, gunicorn sync | 1257,9 | 5,0 | 334,9 | 173,0 | 194,8 | 95,3% |
| **FastAPI, 2 queries, orjson** | **314,3** | 1,8 | 1303,1 | 14,4 | 182,0 | 94,3% |
| FastAPI, 2 queries, `json` da stdlib | 341,0 | 3,9 | 1202,4 | — | — | — |
| FastAPI, query única, orjson | 250,7 | 1,3 | 1638,3 | 9,8 | 181,9 | 93,4% |

### 4.3 As razões que interessam

| comparação | fator |
| - | - |
| FastAPI vs. Django, **escrita** | **1,73x** |
| FastAPI vs. Django, **leitura** | **4,00x** |
| FastAPI query única vs. Django, leitura | 5,02x |
| query única vs. duas queries (FastAPI) | 1,25x |
| orjson vs. `json` da stdlib (FastAPI, leitura) | 1,09x |
| pydantic vs. validação manual (FastAPI, escrita) | **0,97x** (pior) |

---

## 5. Conclusões

### 5.1 A previsão acertou na escrita e errou na leitura

A previsão registrada em [`django/06`, seção 8](../django/06-tipos-de-worker.md),
escrita antes de existir uma linha de código deste projeto, era **300–500 µs/req
e um ganho de 1,7x a 2,9x**.

| | previsto | medido | veredito |
| - | - | - | - |
| escrita | 300–500 µs | **499,7 µs** | dentro da faixa, encostado no teto |
| escrita | 1,7–2,9x | **1,73x** | no piso do intervalo |
| leitura | 1,7–2,9x | **4,00x** | **fora da faixa, subestimado** |

**O erro não foi de calibragem, foi de raciocínio.** A previsão dizia, com todas
as letras: *"o que não se ganharia tanto quanto se imagina: nosso caminho quente
já usa SQL cru, então o custo do ORM do Django já não está sendo pago"*.

Isso é verdade para a **escrita** — `Cliente._aplicar_delta` executa
`connection.cursor()` com SQL cru — e falso para a **leitura**:
`Cliente.extrato` faz `cls.objects.get(pk=...)` seguido de
`list(cliente.transacoes.all()[:10])`, ou seja, **11 instâncias de modelo do
Django construídas por requisição**
(`django/crebitos/models.py`, método `extrato`).

O ORM estava no caminho quente o tempo todo — só que no endpoint que eu não
olhei quando escrevi a previsão. E a assimetria dos resultados (1,73x contra
4,00x) é exatamente o tamanho dessa diferença.

**Aprendizado transversal**: "o caminho quente" não é um lugar só. Este sistema
tem dois endpoints com perfis de custo opostos, e uma afirmação verificada em um
deles foi generalizada para o outro sem verificação.

### 5.2 O pydantic não paga, e a hipótese registrada estava certa

512,7 µs contra 499,7 µs: o pydantic ficou **2,6% pior**, o que está dentro do
limiar de ruído de ~3% deste projeto. A leitura honesta é **"sem diferença
mensurável"**, não "o pydantic perde".

O comentário em `fastapi/app/config.py` registrava a hipótese antes da medição:
*"para 3 campos, o custo de construir o modelo pode comer o ganho do parser"*.
Foi o que aconteceu. O núcleo em Rust do pydantic-core ganha no parsing e
devolve o ganho na construção do `BaseModel` — e o payload da Rinha tem três
campos.

**Decisão: a validação manual fica como padrão.** Não por ser mais rápida (não
é, dentro do ruído), mas porque é a que espelha o Django, e trocar sem ganho
mensurável introduziria uma variável a mais na comparação.

Ressalva: isto **não** é um veredito sobre o pydantic em geral. Com payloads
maiores, tipos aninhados ou muitos campos, a conta muda de lado — e este teste
não diz nada sobre esse caso.

### 5.3 As duas otimizações que valem, e por quê

**Query única no extrato: 1,25x** (314,3 → 250,7 µs). O ganho tem duas fontes:
um round-trip a menos e, sobretudo, as 10 transações voltando do Postgres como
texto JSON já pronto, concatenado direto na resposta em vez de virar 10 dicts
Python e depois bytes.

**orjson: 1,09x** no extrato (314,3 → 341,0 com a stdlib). Acima do ruído, e o
número faz sentido: o corpo do extrato tem 10 objetos, e é aí que um
serializador em Rust tem o que fazer. No POST, cujo corpo tem dois inteiros, o
ganho seria irrelevante — não foi medido de propósito.

Somadas, as duas põem o extrato em **250,7 µs contra 1257,9 µs do Django —
5,02x**.

### 5.4 A amplitude caiu pela metade

| | amplitude entre repetições |
| - | - |
| Django (sync) | 4,8–5,3% |
| FastAPI (uvicorn/uvloop) | 1,3–2,1% |

Mesmo rig, mesma cota, mesmo host. **Isto é uma observação, não uma explicação**
— a causa não foi investigada. A hipótese óbvia é que um único loop de eventos
tem escalonamento mais previsível que worker sync + kernel; confirmá-la exigiria
um experimento próprio.

### 5.5 Prova oficial: USD 100.000, e o que ela não diz

Stack completa (nginx + 2 APIs + Postgres, 1.50 CPU e 550MB), simulação oficial
do Gatling 3.15.1, 61.503 requisições em 4 minutos:

| | FastAPI | Django (`django/05`) |
| - | - | - |
| Pontuação | **USD 100.000** | USD 100.000 |
| Requisições abaixo de 250ms | **100%** (61.503/61.503) | 100% |
| Inconsistências de saldo | **zero** | zero |
| Requisições com falha | zero | zero |
| p50 | 2 ms | — |
| p98 | **5 ms** | 7 ms |
| p99 | 6 ms | — |
| máximo | 246 ms | — |
| Subida da stack | 7s (limite: 40s) | ~20s |

Resultado em `resultados/fastapi/20260824T144338/`.

**O que este número NÃO prova.** Que o FastAPI é melhor. A pontuação satura: as
duas implementações marcam o teto porque **as duas têm ~35x a 50x de folga** no
SLA. A diferença entre p98 de 5ms e de 7ms é irrelevante contra um limite de
250ms — está no ruído de um sistema que nem chegou perto de ser exigido. Foi
exatamente por isso que este projeto adotou o `oha` para comparar e o Gatling
para aprovar.

O que a prova oficial diz, e é o que se pediu dela: a implementação está
**correta** sob a carga real, incluindo as fases de concorrência e de
read-your-writes.

### 5.6 O que NÃO mudou: a pontuação

A previsão também dizia que **nenhuma dessas trocas mudaria a pontuação**, e
isso continua valendo. A stack Django já entrega p98 de 7ms contra um SLA de
250ms — 35x de folga — e não existe nota acima do teto de USD 100.000.

O que estes números compram é **teto de vazão**: sob a mesma cota de 0.40 CPU
por instância, o FastAPI sustenta ~1,7x mais escritas e ~4x mais leituras.

### 5.7 Onde o gargalo vai aparecer agora

Os períodos throttlados contam a história: a API continua congelando em **92–94%
dos períodos**, praticamente o mesmo que o Django (95%). **A aplicação continua
sendo o gargalo** — ela ficou mais barata por requisição, mas ainda satura sua
cota antes de qualquer outro serviço.

A previsão de que "o gargalo migraria para o Postgres" **ainda não se
confirmou**, e não podia mesmo: com a cota da API fixa em 0.40, o teto de vazão
subiu proporcionalmente ao barateamento, mas o banco recebeu proporcionalmente
mais trabalho na mesma cota de 0.6. O teste que responderia isso é
redistribuir a cota — tirar da API e dar ao banco — e ainda não foi feito.

---

## 6. Ações decorrentes

- [x] `BENCH_PROJETO` parametriza a bancada; perfis em `scripts/perfis/`.
- [x] Padrão do projeto: validação manual, extrato em duas queries, orjson.
- [ ] **Promover a query única a padrão** — 1,25x, com testes provando bytes
      idênticos. Falta rodar a prova oficial com ela ligada.
- [x] Prova oficial (Gatling) da stack completa: USD 100.000, zero
      inconsistências, p98 de 5ms, subida em 7s.
- [ ] Redistribuir a cota (API ↔ banco) agora que a API ficou mais barata:
      é o experimento que responde se o gargalo migrou.
- [ ] Corrigir a generalização em `django/06`, seção 8: o custo do ORM **estava**
      no caminho quente de leitura.
