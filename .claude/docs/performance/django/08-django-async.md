# 08 — Django async de ponta a ponta: 2,5x pior que o worker síncrono

**Data**: 2026-08-27 · **Commit**: `e794251`
**Ferramenta**: `oha` 1.15.0 · **Banco**: Postgres 18

O experimento 06 terminou com uma ressalva grande: ele mediu *views síncronas
sob ASGI*, e não "async em Python". Este fecha a lacuna. As views são
`async def`, o banco é falado por `psycopg.AsyncConnectionPool`, e não há
`sync_to_async` em ponto algum do caminho quente.

**Resultado curto: o async triplica a vazão do ASGI do experimento 06 e ainda
assim perde de 2,5x para o Gunicorn síncrono.** Nenhuma das duas metades disso
estava na minha previsão com a magnitude certa.

---

## 1. Ressalvas metodológicas — leia antes dos números

**1. Não é o ORM assíncrono do Django, e isso é deliberado.** O `aget`/`acreate`
não são assíncronos: em `django/db/models/query.py:694`, `aget` é literalmente
`sync_to_async(self.get)`. Usá-los mediria o experimento 06 com outra sintaxe. O
caminho async aqui fala com o Postgres pelo pool do psycopg, direto.

**2. Uma variável escondida a favor do async: o `SELECT 1`.** O braço `sync`
roda com `CONN_HEALTH_CHECKS=1`, o padrão do projeto, que emite um `SELECT 1`
por requisição (medido em [`07`](./07-o-django-tambem-nao-reusava.md): 8 a 10%
de vazão). O caminho async não paga esse custo, porque não usa a conexão do
Django. Ou seja, **o `sync` está apanhando com um handicap de ~10% contra ele** —
e ganha assim mesmo. Corrigindo a mão, seriam ~795 µs contra 875, e a conclusão
não muda de sinal.

**3. Os controles foram remedidos, não copiados do 06.** Os números do
experimento 06 são de outra data. Um braço novo comparado contra número velho
mistura "async" com "o que mudou na máquina em cinco dias".

**4. Uma instância de API**, atrás do nginx, escrita concentrada no cliente 1 —
pior caso de contenção, igual a todos os experimentos desta série.

**5. Máquina local de 20 vCPUs, Docker Desktop sobre WSL2.**

---

## 2. Hipótese registrada ANTES de medir

Commitada em `3ad1c5f`, antes de existir uma linha de `views_async.py`:

> 1. **Bate o `uvicorn` do 06 com folga.** Chute: **1000–1500 µs/req** na
>    escrita, contra 4295 — algo como 3x.
> 2. **NÃO bate o `gunicorn sync` (862 µs).** Chute: **1,2x a 1,7x mais caro**.
> 3. **Fica pior que o FastAPI async** (499,7 µs, `fastapi/01`).
> 4. **Ganho estrutural real: conexões.** Com async de verdade o pool passa a ser
>    o único mecanismo de concorrência com o banco.

Placar: **(1) errada, (2) certa na direção e errada na magnitude, (3) certa,
(4) certa.** A seção 5 detalha.

---

## 3. Comandos para replicar

```bash
just bench-08                                  # experimento inteiro (6 séries)
just bench-async transacoes                    # só o braço async, escrita
VIEWS_ASYNC=1 API_SERVER=uvicorn just up django # stack completa no modo async
```

`VIEWS_ASYNC=1` sem `WEB_SERVER=uvicorn` **aborta** no entrypoint: sob WSGI o
Django envolveria as views `async def` em `async_to_sync` e a medição diria o
contrário do que pretende — mais um caso de configuração errada que produziria
número plausível em vez de erro.

---

## 4. Resultados sob a cota da Rinha (0.40 CPU por API)

Séries de 5 repetições de 10s, aquecimento descartado, concorrência 50, banco
recriado entre repetições nas séries de escrita. **Todas fecharam com 100% de
HTTP 200 e amplitude ≤ 4,1%.**

### Escrita — `POST /transacoes`, saturação

```
braço                                rps   ampl%    p99ms   API us/req   DB us/req   thr%
sync (WSGI)                        476.6     1.5    162.7          875         395   95.3
async ponta a ponta                193.4     2.2    388.1         2198         632   94.4
ASGI + views síncronas (exp. 06)   105.5     4.1    602.1         4160         908   94.5
```

### Leitura — `GET /extrato`, saturação

```
braço                                rps   ampl%    p99ms   API us/req   DB us/req   thr%
sync (WSGI)                        342.8     1.8    194.3         1221         338   96.2
async ponta a ponta                235.1     1.8    287.7         1806         278   94.5
ASGI + views síncronas (exp. 06)   117.9     1.7    504.9         3675         566   93.7
```

### As duas razões que importam

| | escrita | leitura |
| - | - | - |
| async **vs. ASGI síncrono** | **1,89x melhor** | **2,03x melhor** |
| async **vs. Gunicorn sync** | **2,51x pior** | **1,48x pior** |

---

## 5. Conclusões

### O async conserta o desastre do experimento 06 — pela metade

O `uvicorn` do 06 gastava 4160 µs por escrita. Tirando a thread por requisição,
o `ThreadSensitiveContext` por request e a conexão thread-local, sobram 2198 µs.
**A camada que o experimento 06 acusou custava metade do total, não dois terços
como previ** — eu chutei 1000–1500 µs e errei para menos.

Onde erra a previsão: eu tratei "sem thread pool" como se removesse todo o
excedente. Não remove. O que sobra depois é o event loop, a criação de corrotina
por requisição, e a pilha ASGI do `django/core/handlers/asgi.py`, que monta um
`HttpRequest` a partir do escopo ASGI e é mais cara que o caminho WSGI
equivalente.

### O worker síncrono continua ganhando, e por mais do que eu previ

Previ 1,2x–1,7x mais caro. Medi **2,51x na escrita** e 1,48x na leitura. A
previsão só acertou no endpoint de leitura.

A explicação de por que o async não compra nada aqui é a mesma do experimento
06, e vale repetir porque é o coração do assunto: **async compra sobreposição de
espera.** Neste sistema não há espera para sobrepor. O Postgres responde em
centenas de microssegundos, `synchronous_commit = off` (experimento 04) tirou o
disco do caminho crítico, e a cota de 0.40 CPU garante que o gargalo é CPU.
Sobrepor espera que não existe custa o preço do mecanismo e devolve zero.

Sob cota, **CPU por requisição é a moeda**, e a aritmética fecha de novo:
`0,40 CPU ÷ 2198 µs ≈ 182 req/s`, contra 193,4 medidos.

### Por que a escrita apanha mais que a leitura

2,51x na escrita contra 1,48x na leitura. A diferença está numa coluna que quase
não olhei nos experimentos anteriores: **a CPU do banco**.

| | API us/req | DB us/req |
| - | - | - |
| escrita, sync | 875 | 395 |
| escrita, async | 2198 | **632 (+60%)** |
| leitura, sync | 1221 | 338 |
| leitura, async | 1806 | **278 (−18%)** |

Na leitura o banco fica **mais barato** no async — e isso é o `SELECT 1` do
health check, que só o braço síncrono paga (ressalva 2). Na escrita, o async
gasta 60% mais CPU de banco **mesmo sem pagar o health check**, ou seja, o efeito
real é maior que os 60% aparentes.

O suspeito é o pool. O braço síncrono usa **uma** conexão persistente: um único
processo no Postgres, com seu cache de plano e suas páginas quentes. O async
espalha as escritas por **até oito** backends, e as 5 linhas quentes de
`crebitos_cliente` passam a ser disputadas entre processos diferentes — mais
buffers tocados, mais contenção de lock de linha. A leitura não sofre disso
porque não escreve.

> Isto é hipótese, não medição: eu não instrumentei `pg_stat_statements` por
> backend nesta série. Fica como o próximo experimento, e fica registrado aqui
> como hipótese para o placar continuar honesto.

### O ganho estrutural existe, e é real — só não é de vazão

A previsão 4 se confirmou inteira. O experimento 06 **precisou** de pool para
sequer completar uma série, porque as conexões do Django são thread-local e o
ASGI dava uma thread por requisição: 50 requisições em voo viravam 50 conexões
contra `max_connections = 20`, e o Postgres respondia `FATAL: sorry, too many
clients`.

No caminho async isso não pode acontecer por construção. Não existe thread por
requisição; o pool é o único mecanismo de concorrência, e `acquire()` **enfileira**
em vez de abrir conexão nova. É a mesma propriedade que o FastAPI tem em
`fastapi/01`, e é uma propriedade de segurança operacional, não de velocidade.

### Contra o FastAPI, a distância é o framework

| | escrita, API us/req |
| - | - |
| FastAPI async + asyncpg ([`fastapi/01`](../fastapi/01-fastapi-async.md)) | **499,7** |
| Django async + psycopg | 2198 |
| Django sync + psycopg | 875 |

**4,4x entre dois aplicativos assíncronos, no mesmo Python, com o mesmo SQL.**
Como o padrão de I/O e as queries são os mesmos, o que sobra é a pilha: Starlette
monta um escopo ASGI e chama a função; o Django monta `HttpRequest`,
`HttpResponse`, resolve URL pelo `URLResolver` e atravessa `BaseHandler`.

Isto responde uma pergunta que o experimento 06 deixou em aberto: a vantagem do
FastAPI **não** vinha de ser assíncrono. Vem de ser menor. Um Django assíncrono
não chega perto de um FastAPI assíncrono, e um Django síncrono ainda é 1,75x
melhor que o Django assíncrono.

### O que este experimento NÃO diz

Não diz que "async é inútil". Diz que async não compra vazão **num sistema
limitado por CPU cujo I/O é rápido e local**. Trocar o Postgres por um serviço
remoto de 50ms mudaria completamente a resposta: aí haveria espera de sobra para
sobrepor, e o worker síncrono — que processa uma requisição por vez — seria o
pior de todos os arranjos.

A regra que sobrevive é a de sempre: **a arquitetura certa depende de onde o
tempo é gasto**, e neste projeto o tempo é gasto em CPU de Python.

---

## 6. Ações decorrentes

- [x] `VIEWS_ASYNC=1` liga as views `async def` + pool assíncrono do psycopg.
- [x] Entrypoint aborta com `VIEWS_ASYNC=1` fora do uvicorn.
- [x] `crebitos/tests_async.py` prova que o SQL dos dois caminhos é o mesmo — e
      já pegou uma divergência real na primeira execução.
- [x] `just bench-08` reproduz o experimento inteiro, com os controles remedidos.
- [x] **Decisão: o worker sync continua sendo o padrão do projeto.** O caminho
      async fica versionado, medido e desligado.
- [ ] Hipótese aberta: medir `pg_stat_statements`/`pg_stat_activity` por backend
      para confirmar que o custo extra de banco na escrita async é espalhamento
      pelo pool.
- [ ] Não medido de propósito: o Gatling neste braço. A 193 rps por instância
      contra 170 exigidos, ele passaria raspando — o mesmo caso do `gthread` no
      experimento 06, em que a pontuação satura e não distingue.

---

## 7. Aprendizados transversais

- **Async compra sobreposição de espera; sem espera, é só custo.** Aqui custou
  2,51x na escrita.
- **Remover uma camada acusada não devolve o custo inteiro.** Tirar a thread por
  requisição recuperou metade dos 4160 µs, não tudo — o resto era a pilha ASGI
  do próprio Django.
- **A vantagem do FastAPI não era o async.** Era o tamanho do framework: 4,4x
  entre dois aplicativos assíncronos equivalentes.
- **Um pool maior pode encarecer o banco.** Uma conexão persistente concentra
  cache; oito espalham a escrita por oito backends nas mesmas 5 linhas quentes.
- **Handicap contra a própria hipótese preferida é barato e vale caro.** O
  braço síncrono venceu pagando um `SELECT 1` que o async não paga.
