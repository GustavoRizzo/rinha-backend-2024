# Rinha de Backend 2024/Q1 — laboratório de estudo

Quatro implementações da [Rinha de Backend 2024/Q1](https://github.com/zanfranceschi/rinha-de-backend-2024-q1)
— **Django**, **FastAPI**, **Elixir** e **Go** — com **dezoito experimentos de
desempenho** medindo cada decisão de arquitetura sob as restrições da competição.

As quatro marcam a pontuação máxima. A comparação interessante não é essa: é o
**custo em CPU por requisição**, que a pontuação não enxerga porque satura.

A competição encerrou em março de 2024. **Este repositório não é uma submissão** —
é um laboratório para estudar teste de carga, controle de concorrência e
limitação de recursos, usando as regras da Rinha como especificação.

## Resultado

| | Django | FastAPI | Elixir | **Go** |
| - | - | - | - | - |
| Pontuação | **USD 100.000** (9 execuções) | **USD 100.000** | **USD 100.000** | **USD 100.000** (5 execuções) |
| Requisições abaixo de 250ms | 100% (SLA exige 98%) | 100% | 100% | 100% |
| p98 | 7ms (SLA exige < 250ms) | 5ms | 5ms | **4ms** |
| Máximo | 76–94ms | 246ms | **51ms** | 104–216ms |
| Inconsistências de saldo | zero em +550 mil requisições | zero | zero | zero |
| Subida da stack | ~20s (limite: 40s) | 7s | **4s** | 7–8s |
| Recursos | 1.50 CPU e 550MB | 1.50 CPU e 550MB | 1.50 CPU e 550MB | 1.50 CPU e 550MB |
| **CPU por requisição, escrita** | 856 µs | 512 µs | 444 µs | **323 µs** |
| **CPU por requisição, leitura** | 1224 µs | 257 µs | 158 µs | **105 µs** |
| **Vazão sem cota, escrita** | 928 rps | 2.211 | 2.762 | **3.589** |
| **Vazão sem cota, leitura** | 768 rps | 4.410 | 16.454 | **21.737** |
| **Linhas de código (app)** | **289** | 318 | 442 | 688 |

> As quatro colunas de CPU vêm de séries re-executadas **no mesmo commit, no
> mesmo dia e no mesmo host** (`2b408eb`) — 8 séries sob cota e 16 sem cota. Ver
> [`performance/go/03`](./.claude/docs/performance/go/03-quatro-stacks-quatro-linguagens.md)
> e [`go/04`](./.claude/docs/performance/go/04-sem-cota.md).

> A coluna do Elixir só chegou a esses números depois de um erro meu ser
> derrubado por medição. Por três experimentos ele apareceu como o **mais caro**
> dos três, e a causa era uma opção do driver que eu documentei sem conferir no
> fonte: cada statement era **replanejado a cada requisição**, e 62,2% do
> trabalho do banco era planejamento. Ver
> [`performance/elixir/04`](./.claude/docs/performance/elixir/04-o-statement-que-nao-era-reusado.md).

**A pontuação satura e as quatro colunas empatam nela.** Com 35x a 60x de folga
contra o SLA, toda configuração razoável marca o teto — não existe nota acima
de USD 100.000. O que separa as implementações é o custo por requisição: **2,65x
na escrita e 11,64x na leitura** entre Django e Go.

E a pergunta que o projeto acabou respondendo de brinde: *linguagem que ajuda
mais o programador tende a ser pior em desempenho?* A correlação aparece nas
pontas — o Django escreve 2,4x menos código e paga 2,65x mais CPU — **e some no
meio**: o FastAPI escreve menos que o Elixir e é quase tão rápido. Um quarto das
688 linhas do Go são blocos `if erro != nil`. Ver
[`go/03`, §5](./.claude/docs/performance/go/03-quatro-stacks-quatro-linguagens.md).

### A melhor execução

> **`resultados/fastapi/20260824T144338`** — FastAPI + uvicorn + asyncpg;
> nginx + 2 APIs + Postgres em **1.50 CPU e 550MB**, o orçamento inteiro.
>
> | | |
> | - | - |
> | Pontuação | **USD 100.000** (máxima) |
> | Requisições | 61.503 em 4 minutos |
> | Abaixo de 250ms | **100,000%** — nenhuma exceção |
> | p50 / p98 / p99 | **2ms / 5ms / 6ms** (SLA: p98 < 250ms) |
> | Máximo | 246 ms |
> | Inconsistências de saldo | **zero** |
> | Requisições com falha | **zero** |
> | Subida da stack | **7s** (limite: 40s) |

Quatro ressalvas que precisam andar junto com esses números:

1. **A pontuação satura** — a stack Django também marca USD 100.000. Com p98 de
   5ms contra um SLA de 250ms são **50x de folga**, e nesse regime qualquer
   implementação competente tira nota máxima. É por isso que aqui o `oha`
   compara e o Gatling só aprova.
2. **O máximo de 246ms encostou no limite** de 250ms — uma requisição passou a
   4ms de custar dinheiro. As execuções em Django tiveram máximos melhores
   (76ms e 94ms).
3. **A máquina é mais folgada que a oficial** (20 vCPU contra 4, e o gerador de
   carga não disputa CPU com a aplicação): **estes números não são comparáveis
   com o ranking oficial**.
4. **A competição encerrou em março de 2024.** Isto é um exercício de estudo.

Relatórios navegáveis do Gatling em [`resultados/`](./resultados/).

## O desafio, em uma tela

Uma API de créditos e débitos ("crébitos") com dois endpoints:

```
POST /clientes/{id}/transacoes   -> 200 {limite, saldo} | 422 | 404
GET  /clientes/{id}/extrato      -> 200 {saldo, ultimas_transacoes} | 404
```

| | |
| - | - |
| **Arquitetura** | Load balancer round-robin na porta 9999 + 2 instâncias de API + 1 banco persistente |
| **Recursos** | 1.5 CPU e 550MB somados entre **todos** os serviços |
| **Carga** | 4 minutos, 61.503 requisições, pico de ~340 req/s |
| **SLA** | 98% abaixo de 250ms — multa de `(98 − %sucesso) × USD 1.000` |
| **Consistência** | multa de `USD 803,01` por inconsistência de saldo |

Só existem **5 clientes**, o que concentra toda a carga em 5 linhas do banco. A
dificuldade não é vazão — é manter correção absoluta sob contenção máxima.

## Arquitetura e as decisões por trás dela

```
Gatling ──> nginx :9999 ──socket Unix──> api01 (Gunicorn sync, 1 worker) ──┐
                        └─socket Unix──> api02 (Gunicorn sync, 1 worker) ──┴──> Postgres 18
   0.10 CPU / 32MB          0.40 CPU / 100MB cada                              0.60 CPU / 318MB
```

Cada escolha tem um número que a sustenta:

| Decisão | Efeito medido | Experimento |
| - | - | - |
| `CONN_MAX_AGE` persistente | **4,75x** de vazão | [04](./.claude/docs/performance/django/04-postgres.md) |
| Socket Unix entre nginx e APIs | 2,9x; amplitude de 246% para 3,9% | [03](./.claude/docs/performance/django/03-nginx-e-socket-unix.md) |
| Worker `sync` em vez de `gthread` | 2,4x | [06](./.claude/docs/performance/django/06-tipos-de-worker.md) |
| Worker `sync` em vez de ASGI/uvicorn | 4,7x | [06](./.claude/docs/performance/django/06-tipos-de-worker.md) |
| Worker `sync` em vez de Django `async` de ponta a ponta | 2,5x na escrita, 1,5x na leitura | [08](./.claude/docs/performance/django/08-django-async.md) |
| Cota de CPU nas APIs, não no banco | p98 de 217ms para 7ms | [05](./.claude/docs/performance/django/05-stack-completa-gatling.md) |
| 1 worker por API em vez de 4 | 28% sob cota | [04](./.claude/docs/performance/django/04-postgres.md) |
| `DEBUG=False` | 4,1% | [01](./.claude/docs/performance/django/01-debug-vs-producao.md) |

A corretude vem de uma instrução só, que resolve leitura, validação e escrita
sem janela entre elas:

```sql
UPDATE crebitos_cliente SET saldo = saldo + %s
 WHERE id = %s AND saldo + %s >= -limite
RETURNING saldo, limite;
```

`READ COMMITTED` — o padrão do Postgres — **não** impede *lost update*. É a
estratégia que impede.

## Os estudos

Cada experimento tem documento próprio, com ressalvas metodológicas **antes** dos
números, o commit exato medido e os comandos para replicar.

| # | Experimento | Achado principal |
| - | - | - |
| [01](./.claude/docs/performance/django/01-debug-vs-producao.md) | `DEBUG` e `runserver` vs. Gunicorn | O `runserver` tem escalabilidade **negativa**: 646 rps com 1 conexão, 223 com 50 |
| [02](./.claude/docs/performance/django/02-container-e-cgroup.md) | Container e cgroup | Sob cota, 1 worker bate 4 por 37%; e o worker sync esgota as portas efêmeras do host |
| [03](./.claude/docs/performance/django/03-nginx-e-socket-unix.md) | nginx e socket Unix | Acrescentar um salto deixou o sistema **mais rápido**: a API parou de fazer trabalho de rede |
| [04](./.claude/docs/performance/django/04-postgres.md) | Postgres | O padrão do Django (`CONN_MAX_AGE=0`) custa 4,75x. Sob throttling, esperar I/O é de graça |
| [05](./.claude/docs/performance/django/05-stack-completa-gatling.md) | Stack completa + Gatling | A cauda era throttling, e a cota estava no serviço errado |
| [06](./.claude/docs/performance/django/06-tipos-de-worker.md) | Tipos de worker | O Gatling **satura**: `sync` e `gthread` tiram a mesma nota com 59% de diferença de vazão |
| [fastapi/01](./.claude/docs/performance/fastapi/01-fastapi-async.md) | FastAPI + asyncpg | A previsão acertou na escrita (1,73x) e **subestimou a leitura (4,00x)**: o ORM estava no caminho quente do extrato |
| [fastapi/02](./.claude/docs/performance/fastapi/02-onde-esta-o-gargalo.md) | Onde está o gargalo | Uma repartição **1,54x melhor na bancada** entregou cauda **pior** na prova oficial — a bancada mede saturação, a Rinha não satura |
| [fastapi/03](./.claude/docs/performance/fastapi/03-o-que-a-troca-de-framework-comprou.md) | O que a troca de framework comprou | Fechamento do projeto: o que foi medido, o que foi suposto, e o que a próxima linguagem precisa manter idêntico |
| [elixir/01](./.claude/docs/performance/elixir/01-a-beam-sob-cota.md) | A BEAM sob cota de cgroup | As duas armadilhas previstas **não aparecem**: o OTP 27 lê a cota e se dimensiona sozinho. Sem cota, elas custam **2,16x** |
| [elixir/02](./.claude/docs/performance/elixir/02-ocioso-na-carga-real.md) | Ocioso por serviço na carga real | Ninguém passa de 42% da própria cota: **não há o que redistribuir**, e a tensão que a bancada mostrava era artefato da saturação |
| [elixir/03](./.claude/docs/performance/elixir/03-sem-cota-varios-nucleos.md) | As três stacks sem limitação de hardware | 1 processo CPython satura **exatamente 1,01 núcleo** — o GIL, medido. Um nó da BEAM espalha por 5,8 sem configuração |
| [elixir/04](./.claude/docs/performance/elixir/04-o-statement-que-nao-era-reusado.md) | O statement que não era reusado | `plans = calls`: **62,2% do tempo de banco era planejamento**. Uma opção de uma linha inverteu a conclusão de três experimentos |
| [django/07](./.claude/docs/performance/django/07-o-django-tambem-nao-reusava.md) | O Django também não reusava | O **mesmo defeito** do elixir/04 — e custou **~0**, porque no Django o gargalo é a API e o banco está ocioso |
| [go/01](./.claude/docs/performance/go/01-a-aplicacao-sai-da-frente.md) | A aplicação sai da frente | Primeira stack do laboratório em que **o Postgres vira a parede**: API a 0,9% de saturação, banco a 92,7% |
| [go/02](./.claude/docs/performance/go/02-tirando-proveito-da-stack.md) | As variantes do Go, medidas | A bancada elege `GOMAXPROCS=1` (20% menos CPU) e **a prova oficial recusa** — folga é amortecedor de cauda |
| [go/03](./.claude/docs/performance/go/03-quatro-stacks-quatro-linguagens.md) | As quatro sob a cota da Rinha | Comparativo completo **+ linhas de código**: a correlação "mais ajuda, menos desempenho" só vale nas pontas |
| [django/08](./.claude/docs/performance/django/08-django-async.md) | Django `async` de ponta a ponta | Async **não compra vazão sem espera para sobrepor**: 2,51x pior que o worker síncrono — e a vantagem do FastAPI não era o async, era o tamanho do framework |
| [go/04](./.claude/docs/performance/go/04-sem-cota.md) | As quatro sem limitação | Go na frente nos quatro cenários; e **paralelismo não resolve serialização** — três das quatro pioram na escrita com a máquina inteira |
| [go/05](./.claude/docs/performance/go/05-bloco-b-estrategias-de-concorrencia.md) | **Bloco B**: estratégias de concorrência | `UPDATE ... RETURNING` vence — por **9% a 15%**, não "por larga margem". Contra a otimista, 3,57x |
| [fastapi/03](./.claude/docs/performance/fastapi/03-o-que-a-troca-de-framework-comprou.md) | Fechamento | O ganho que dá para atribuir ao framework é **1,73x**, não 4x: o resto era **ORM no caminho quente**, e isso o Django também poderia ter tirado |

Material de apoio em [`.claude/docs/`](./.claude/docs/):

| Doc | Conteúdo |
| - | - |
| [00 — Índice](./.claude/docs/00-indice.md) | Estado do projeto e referência rápida |
| [01 — Fundamentos](./.claude/docs/01-fundamentos.md) | Open/closed model, percentis, cgroups, controle de concorrência |
| [02 — Regras](./.claude/docs/02-regras.md) | Contrato HTTP, restrições, pontuação |
| [03 — Plano](./.claude/docs/03-plano-implementacao.md) | Matriz de variantes e metodologia de diagnóstico |
| [04 — Aprendizados](./.claude/docs/04-aprendizados.md) | Diário técnico, decisões e **erros cometidos** |
| [05 — Hacks da competição](./.claude/docs/05-hacks-da-competicao.md) | Atalhos que só se justificam por ser um desafio |
| [06 — A história do projeto](./.claude/docs/06-a-historia-do-projeto.md) | **Comece por aqui se quiser o percurso**: os quatro atos em ordem, com os erros |

## Como executar

### Requisitos

```bash
just doctor       # confere tudo de uma vez
```

- Docker Engine + Compose v2
- [`just`](https://github.com/casey/just), [`uv`](https://docs.astral.sh/uv/), JDK 17+
  (Erlang/Elixir e Go **não** são necessários: os projetos `elixir/` e `go/`
  compilam e testam em container)
- [`oha`](https://github.com/hatoo/oha) para os comparativos rápidos: `cargo install oha`
- O Gatling **não precisa ser instalado**: o projeto Maven em [`gatling/`](./gatling/) traz tudo

### O ciclo completo

```bash
just check django      # valida 1.5 CPU / 550MB a partir do compose resolvido
just up django         # sobe a stack e espera prontidão (limite de 40s)
just smoke django      # 13 verificações do contrato HTTP
just load django       # a simulação oficial do Gatling (4 minutos)
just score django/<timestamp>
just down django

just run django        # tudo acima, em sequência
```

### Comparativos rápidos com `oha`

O Gatling leva 4 minutos e sua pontuação **satura** — toda configuração razoável
marca 100.000. Para comparar configurações, o instrumento é o `oha` em
saturação, que mede **folga** em 10 segundos:

```bash
just bench-01     # DEBUG vs. produção, runserver vs. Gunicorn
just bench-02     # workers sob cota de cgroup
just bench-03     # socket Unix vs. TCP no salto nginx -> API
just bench-04     # Postgres vs. SQLite, leitura e escrita
just bench-06     # tipos de worker, com e sem cota
just bench-tabela # tabela comparativa de tudo que já rodou
```

Séries individuais:

```bash
just bench-servidor uvicorn 4 transacoes 0.40 10s 5
just bench-stack nginx-unix 0.45 1 10s 5
just bench-mem gunicorn-1w extrato 30      # crescimento de RSS sob carga
```

Toda execução grava o **hash do commit** junto do resultado, e os scripts
**abortam com a árvore suja** — um número cuja proveniência é falsa é pior que
número nenhum.

### Desenvolvimento

```bash
just dj-setup     # dependências, schema e os 5 clientes
just dj-test      # 64 testes
just dj-serve     # servidor de desenvolvimento
just gen-sql      # regenera infra/sql/ a partir do modelo e da fixture

just fa-test      # 50 testes do FastAPI
just ex-test      # 24 testes do Elixir (não exige Elixir instalado no host)
```

O projeto Elixir roda tudo em container, inclusive os testes: `just ex-test`
sobe um Postgres descartável e executa o ExUnit na **mesma imagem** que o
Dockerfile usa para compilar. Não é preciso instalar Erlang nem Elixir.

## Estrutura

```
.
├─ .claude/docs/              documentação de estudo
│  └─ performance/            um diretório por projeto, um arquivo por experimento
│     ├─ django/              experimentos 01 a 06
│     ├─ fastapi/             experimentos 01 a 03
│     └─ elixir/              experimentos 01 a 04
├─ django/                    implementação em Django + Gunicorn + psycopg
│  ├─ crebitos/               modelo, views, testes, hacks isolados
│  ├─ docker-compose.yml      a stack da competição
│  └─ compose.bench-*.yml     rigs de bancada
├─ fastapi/                   implementação em FastAPI + uvicorn + asyncpg
│  ├─ app/                    domínio, endpoints, pool, hacks isolados
│  └─ tests/                  contrato, concorrência e paridade entre variantes
├─ gatling/                   projeto Maven do teste de carga oficial
├─ infra/                     nginx, postgresql.conf e SQL de inicialização
├─ resultados/                relatórios do Gatling e séries do oha
├─ scripts/                   ciclo, bancada, pontuação, validação
│  └─ perfis/                 o que muda de projeto para projeto na bancada
└─ justfile                   todos os comandos
```

## Ressalvas

Os números foram medidos numa máquina local de 20 vCPUs, sobre Docker Desktop e
WSL2. O ambiente oficial tinha 4 vCPUs, e lá o Gatling disputava CPU com a
aplicação. **Estes resultados não se comparam com o ranking oficial** — servem
para comparar variantes entre si.

## Créditos

Desafio original por [@zanfranceschi](https://github.com/zanfranceschi).
