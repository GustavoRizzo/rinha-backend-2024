# fastapi/03 — O que a troca de framework Python comprou, e o que não comprou

Documento de **fechamento** do projeto FastAPI. Não traz medição nova: consolida
os experimentos [01](./01-fastapi-async.md) e [02](./02-onde-esta-o-gargalo.md)
e responde de forma direta à pergunta que motivou tudo — *vale trocar de
framework dentro do Python?* — separando o que foi **medido** do que foi
**suposto**.

Serve também de ponto de partida para a próxima implementação, em outra
linguagem: a seção 6 registra o que precisa ser mantido idêntico para que a
comparação continue valendo, e a seção 7 deixa as previsões escritas **antes**
de existir código.

---

## 1. Ressalvas metodológicas

Todas as ressalvas dos documentos 01 e 02 continuam valendo aqui. As três que
mais limitam as conclusões deste fechamento:

1. **Não é "FastAPI vs. Django" puro.** A comparação trocou **framework e
   driver ao mesmo tempo** (Django+psycopg contra FastAPI+asyncpg), e no extrato
   trocou também **ORM por SQL cru**. São três variáveis num salto só, e a
   seção 4.1 mostra por que isso muda a leitura do resultado principal.
2. **A pontuação satura.** As duas implementações marcam USD 100.000 com 35x a
   50x de folga no SLA. Nada aqui melhora nota; o que muda é teto de vazão e
   custo por requisição.
3. **Uma máquina, um dia, um sistema operacional.** 20 vCPU sob WSL2, com o
   gerador de carga dividindo a máquina com a stack. Os *fatores* entre
   configurações são o que sobrevive; os valores absolutos, não.

---

## 2. Os números, num lugar só

Rig de bancada, API em 0.40 CPU com 1 worker, `oha` 10s × 5 repetições,
aquecimento descartado. A métrica é **µs de CPU por requisição** — sob cota,
vazão é consequência.

| | Django + Gunicorn + psycopg | FastAPI + uvicorn + asyncpg | fator |
| - | - | - | - |
| escrita (`POST transacoes`) | 862,4 µs | **499,7 µs** | **1,73x** |
| leitura (`GET extrato`) | 1257,9 µs | **314,3 µs** | **4,00x** |
| leitura, com query única | — | **250,7 µs** | **5,02x** |
| amplitude entre repetições | 4,8–5,3% | 1,3–2,1% | — |

Prova oficial (Gatling, stack completa em 1.50 CPU / 550MB):

| | Django | FastAPI |
| - | - | - |
| pontuação | USD 100.000 | USD 100.000 |
| abaixo de 250ms | 100% | 100% |
| p98 | 7 ms | 5 ms |
| subida da stack | ~20s | **7s** |
| inconsistências | zero | zero |

---

## 3. O que a troca COMPROU

### 3.1 Custo por requisição: 1,73x na escrita, 4,00x na leitura

É o resultado principal, e é real: mesma cota, mesmo schema, mesma estratégia de
concorrência, mesmo nginx, mesma bancada. Com a query única, a leitura chega a
**5,02x**.

Sob cota de cgroup isso vira teto de vazão diretamente: a mesma CPU atende ~1,7x
mais escritas e ~4x mais leituras.

### 3.2 O fim do "uma conexão de Postgres por requisição concorrente"

Este é o ganho **estrutural**, e não aparece em nenhuma tabela de vazão.

No Django sob ASGI, `django/core/handlers/asgi.py` cria um `ThreadSensitiveContext`
por requisição, cada um com seu executor de uma thread; as conexões do Django são
thread-local; logo, cada requisição concorrente virava **um processo no
Postgres**. Com `max_connections = 20`, 50 requisições em voo davam `FATAL: sorry,
too many clients`. A solução foi introduzir pool — uma peça a mais para resolver
um problema criado pela arquitetura.

Com `async` de verdade não existe thread por requisição. O pool do asyncpg é o
único mecanismo de concorrência com o banco, e `acquire()` enfileira em vez de
abrir conexão nova. **O problema deixou de existir em vez de ser gerenciado.**

### 3.3 Subida em 7s contra ~20s

Limite da competição: 40s. Nenhum dos dois chega perto de falhar, então isto
**não vale ponto** — mas 3x menos tempo de subida é 3x menos espera em cada
ciclo de teste, e este projeto rodou dezenas deles.

### 3.4 Previsibilidade: a amplitude caiu pela metade

De 4,8–5,3% para 1,3–2,1% entre repetições, no mesmo rig. **É observação, não
explicação** — a causa não foi investigada. A hipótese plausível é que um loop
de eventos único tenha escalonamento mais previsível que worker sync + kernel,
mas confirmá-la exigiria experimento próprio.

### 3.5 Memória: ~43MB por instância contra ~54MB

Medido com `docker stats` durante o smoke test, **não** sob carga controlada.
Vale como ordem de grandeza, não como número de documento. Num orçamento de
550MB somados, ~11MB por instância é espaço que poderia ir para o banco.

---

## 4. O que a troca NÃO comprou

### 4.1 Não comprou a atribuição do ganho ao framework

**Esta é a conclusão mais desconfortável do projeto, e a mais importante.**

O ganho de **4,00x na leitura** não é "FastAPI é 4x mais rápido que Django". A
troca mexeu em três coisas ao mesmo tempo:

| variável trocada | contribuição |
| - | - |
| framework (Django → Starlette/FastAPI) | não isolada |
| driver (psycopg → asyncpg) | não isolada |
| **ORM → SQL cru no extrato** | **não isolada, e provavelmente dominante** |

O `extrato` do Django instancia **11 objetos de modelo por requisição**
(`objects.get()` mais um queryset). O do FastAPI não instancia nenhum. Uma versão
Django com SQL cru no extrato — a mesma técnica que o projeto já usava na escrita
— **muito provavelmente fecharia boa parte dos 4,00x**, e isso **nunca foi
medido**.

A evidência indireta está na própria assimetria: onde os dois já usavam SQL cru
(escrita), o ganho foi **1,73x**; onde só o FastAPI usava (leitura), foi
**4,00x**. A diferença entre esses dois fatores é a melhor estimativa disponível
do peso do ORM — e ela sugere que o framework, sozinho, vale bem menos do que a
manchete.

**Conclusão honesta: o número que este projeto pode defender como "ganho de
framework + driver" é o 1,73x da escrita. O 4,00x da leitura é ganho de
*implementação*, e parte dele estava disponível sem trocar de framework.**

### 4.2 Não comprou pontuação

Zero. USD 100.000 antes, USD 100.000 depois. O SLA exige 98% abaixo de 250ms e o
p98 é de 5–7ms nos dois casos. **Não existe nota acima do teto**, e a previsão
registrada em [`django/06`](../django/06-tipos-de-worker.md) já dizia isso —
acertou.

### 4.3 Não comprou vazão utilizável

O pico da simulação é **~340 req/s**. A stack Django já entregava múltiplos
disso. Toda a vazão extra do FastAPI é folga que a competição nunca pede.

Ela só valeria se o requisito mudasse — e é exatamente aí que o ganho de custo
por requisição deixa de ser acadêmico.

### 4.4 Não comprou ganho com o pydantic

512,7 µs contra 499,7 µs da validação à mão: **2,6% pior, dentro do ruído**. O
núcleo em Rust ganha no parsing e devolve o ganho construindo o `BaseModel`, e o
payload da Rinha tem três campos. A ferramenta mais associada ao FastAPI foi a
única peça dele que **não** pagou aqui.

Ressalva: não é veredito sobre o pydantic em geral — com payloads maiores ou
tipos aninhados a conta muda, e este teste não diz nada sobre isso.

### 4.5 Não eliminou o gargalo, só o mudou de lugar

O experimento 02 mostrou que, com a API mais barata, **o banco vira a parede** na
escrita assim que a API tem cota suficiente. Barateamento da aplicação não é
solução permanente: é a transferência do problema para o próximo elo.

### 4.6 Não veio de graça

O que a troca custou, e que nenhuma tabela de vazão mostra:

- uma implementação nova inteira, com 50 testes próprios;
- ferramental de bancada parametrizado por projeto (perfis, cgroup do banco,
  soma de duas APIs, trava de orçamento);
- **dois bugs de ferramental** que produziram — ou quase produziram — números
  errados: `rodar-carga.sh` medindo a stack do Django com o slug do FastAPI, e o
  cgroup do banco nunca coletado por uma leitura fora de ordem;
- **três afirmações minhas derrubadas por medição**: "o ORM não está no caminho
  quente", "o nginx virou o gargalo da leitura", "mover cota para o banco
  melhora a stack".

---

## 5. Veredito

**Trocar de framework dentro do Python vale a pena quando o problema é custo de
CPU por requisição — e não vale por nenhum outro motivo neste projeto.**

| pergunta | resposta |
| - | - |
| Melhora a nota? | **Não.** Satura nos dois. |
| Reduz custo por requisição? | **Sim**, 1,73x na escrita com atribuição limpa. |
| Os 4,00x da leitura são do framework? | **Não sabemos.** Provavelmente em boa parte é o ORM, e isso não foi isolado. |
| Resolve algum problema estrutural? | **Sim**: acaba com a conexão de banco por requisição concorrente. |
| Elimina o gargalo? | **Não**, transfere para o banco. |
| O ecossistema (pydantic) ajudou? | **Não** neste payload. |

E a lição que atravessa os três experimentos, que vale mais que qualquer fator
medido: **uma otimização de 1,54x na bancada entregou cauda pior na prova
oficial**. As duas ferramentas respondem perguntas diferentes — o `oha` responde
*quanto cabe*, o Gatling responde *como se comporta no que chega* — e quem
decide é a segunda.

---

## 6. Para a próxima implementação, em outra linguagem

O que **precisa ser mantido idêntico** para que a comparação continue valendo —
foi assim que o FastAPI virou comparável ao Django:

| item | onde |
| - | - |
| schema e carga inicial | `infra/sql/ddl.sql` e `dml.sql` — as mesmas tabelas `crebitos_*` |
| estratégia de concorrência | `UPDATE ... WHERE saldo + $1 >= -limite RETURNING` |
| load balancer | `infra/nginx/nginx-rinha.conf`, socket Unix, round-robin |
| configuração do banco | `infra/postgres/postgresql.conf` |
| repartição da cota | nginx 0.10, API 0.40 × 2, banco 0.60 — **a que a prova oficial preferiu** |
| bancada | `oha`, 10s, 5 repetições, aquecimento descartado, concorrência 50 |
| estado inicial | 50 transações por cliente (`preparar_bench`) |
| hacks | os mesmos, isolados num módulo só |

O que **precisa ser criado** para a nova stack entrar na comparação:

1. `<linguagem>/docker-compose.yml` (stack da competição, somando 1.50/550MB) e
   `compose.bench-postgres.yml` (rig de bancada, 1 API).
2. `scripts/perfis/<linguagem>.sh` — nomes de container, rigs disponíveis, como
   repor o estado, como o slug identifica a configuração.
3. Um equivalente de `preparar_bench` que produza **estado idêntico**: 50
   transações por cliente, mesmos valores, mesma ordem de inserção.
4. Testes cobrindo, no mínimo: 25 débitos simultâneos → saldo exatamente −25; o
   caso adversarial de 100 débitos contra limite 80.000; read-your-writes.
5. Documento `performance/<linguagem>/01-*.md`, com as previsões registradas
   **antes** de medir.

Armadilhas já pagas por este projeto, que valem para qualquer linguagem:

- **O container não sabe que tem 0.40 CPU.** `os.cpu_count()` devolve 20 lá
  dentro. Todo runtime que se dimensiona por número de núcleos cai nisso —
  `GOMAXPROCS` no Go, `+S` na BEAM, `worker_processes` no nginx.
- **Cada conexão no Postgres é um processo.** `max_connections = 20` para duas
  APIs, num orçamento de 550MB.
- **Sob cgroup, esperar I/O é de graça**; queimar CPU não é.
- **`MB` no Docker é MiB**, e o critério da competição é a unidade declarada.

---

## 7. Previsões registradas ANTES da próxima implementação

Copiadas de [`django/06`, seção 8](../django/06-tipos-de-worker.md), escritas em
2026-08-22. **Não editar** — o valor delas está em poder estar erradas, e a do
FastAPI já mostrou como isso funciona (certa na escrita, subestimada na leitura,
e pelo motivo errado).

| | CPU/req previsto | vs. Django | pontuação prevista |
| - | - | - | - |
| Django + Gunicorn sync (**medido**) | **862 µs** | — | 100.000 |
| FastAPI async + asyncpg (**medido**) | **499,7 µs** | **1,73x** | 100.000 ✓ |
| Go + pgx (previsto) | 50–100 µs | 8–17x | 100.000 |
| Elixir/Phoenix (previsto) | 150–400 µs | 2–6x | 100.000 |

Previsão específica e testável já registrada para o Go: *uma porta sem
`GOMAXPROCS` ajustado teria cauda pior que o Django atual*, mesmo sendo muito
mais rápida por requisição, porque o runtime subiria 20 threads disputando 0.40
CPU.

E a previsão que este documento acrescenta, com base no que o FastAPI ensinou:

> **A comparação com o Go vai sofrer do mesmo problema de atribuição da seção
> 4.1**, e em dose maior — muda linguagem, runtime, driver e modelo de
> concorrência de uma vez. O número honesto continuará sendo o do endpoint em
> que as duas implementações usam a mesma técnica de acesso a dados.

> **A pontuação continuará em USD 100.000**, e continuará não significando nada.
