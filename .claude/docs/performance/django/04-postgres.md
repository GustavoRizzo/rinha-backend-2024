# 04 — Postgres: leitura, escrita, e o parâmetro mais caro do Django

**Data**: 2026-08-21 · **Commit**: `ce6fbca` (árvore limpa)
**Ferramenta**: `oha` 1.15.0 · **Docker Desktop / WSL2**

Quarto degrau. Muda **uma** coisa em relação ao experimento 03: o banco. Mesma
API, mesmo nginx, mesmo socket Unix, mesmas cotas. E, pela primeira vez, o
endpoint de **escrita** entra na medição.

---

## 1. Ressalvas metodológicas — leia antes dos números

**1. Toda a carga de escrita vai para o MESMO cliente (id 1).** É o pior caso de
contenção: uma única linha recebendo todos os `UPDATE`. A Rinha espalha por 5
clientes, então a contenção real é ~5x menor. Escolhido de propósito, mas não
confunda com o cenário da competição.

**2. Uma instância de API, não duas.** A distribuição fica para o experimento 05.

**3. `synchronous_commit = off` está ligado.** É a decisão de durabilidade
descrita em `infra/postgres/postgresql.conf`: o Postgres confirma o COMMIT antes
de o WAL chegar ao disco. **Isso muda a natureza do gargalo** — a espera de disco
sai do caminho crítico. Legítimo num exercício de 4 minutos, inaceitável num
sistema real de pagamentos.

**4. O SQLite está com WAL e `transaction_mode=IMMEDIATE`.** Sem isso os POSTs
concorrentes viram `database is locked` em vez de fila, e a comparação seria
contra um espantalho.

**5. As cotas mudaram de contexto.** API 0.45 CPU / 150MB (igual aos
experimentos anteriores), nginx 0.15 / 32MB, Postgres 0.6 / 200MB. Soma: 1.2 CPU
e 382MB, dentro do orçamento de 1.5 / 550MB — sobra espaço para a segunda API.

**6. Docker Desktop**, com o proxy de porta embutido em tudo.

---

## 2. Metodologia

| Rig | Banco | Conexão |
| - | - | - |
| `nginx-unix` | SQLite (WAL) | arquivo local |
| `postgres` | Postgres 18 | `CONN_MAX_AGE=None` — persistente por worker |
| `postgres-sem-persistencia` | Postgres 18 | `CONN_MAX_AGE=0` — **o padrão do Django** |

Endpoints: `GET /clientes/1/extrato` (leitura) e `POST /clientes/1/transacoes`
com um débito de 1 centavo (escrita — o caminho que exercita a validação de
limite dentro do `UPDATE` condicional).

Séries de 5 repetições de 10s, aquecimento descartado. **Nas séries de escrita o
banco é recriado antes de cada repetição** (`preparar_bench`): sem isso o saldo
desce até bater no limite e tudo vira 422 — que responde rápido e infla o rps
com respostas falsas.

Todas as séries fecharam com **100% de HTTP 200**, sem erros de conexão.

---

## 3. Comandos para replicar

```bash
just bench-04                                              # experimento inteiro
just bench-stack postgres 0.45 1 10s 5                     # leitura
BENCH_ENDPOINT=transacoes just bench-stack postgres 0.45 1 10s 5   # escrita
just gen-sql                                               # regenera infra/sql/
```

---

## 4. Resultados

### Leitura — `GET /extrato`, saturação, 0.45 CPU, 1 worker

```
                          rps  ampl%   p50ms    p99ms  API us/req   thr%
SQLite (WAL)            384.7    1.8   114.5    184.2        1230   96.2
Postgres                387.4    2.2   117.0    175.7        1212   96.2
```

### Escrita — `POST /transacoes`, saturação, 0.45 CPU

```
              workers     rps  ampl%   p50ms    p99ms  API us/req   thr%
SQLite (WAL)        1   214.3    4.2   236.2    288.4        1306    0.0
SQLite (WAL)        4   421.4    4.8   106.6    205.9        1111   95.3
Postgres            1   528.4    6.1    96.1    139.4         880   95.2
Postgres            2   453.7    3.5   103.2    183.9        1035   95.3
Postgres            4   382.9    5.5   108.8    196.1        1232   96.2
```

### O custo de `CONN_MAX_AGE = 0` (o padrão do Django)

```
                                    rps   p50ms    p99ms  API us/req   thr%
Postgres, conexão persistente     528.4    96.1    139.4         880   95.2
Postgres, conexão por requisição  111.2   463.4    561.5        3688    1.9
```

### Escrita em taxa fixa de 170 rps (modelo aberto, `--latency-correction`)

```
                    rps   p50ms    p99ms  API us/req   thr%
Postgres, 1 worker 170.3     1.7      3.3        1179    0.0
Postgres, 2 workers 170.2    1.6      3.1        1206    0.0
```

---

## 5. Conclusões

### `CONN_MAX_AGE = 0` é o parâmetro mais caro que medimos até agora

**4,75x de vazão** (528,4 → 111,2 rps) e **4,2x de CPU por requisição**
(880 → 3688 µs). São ~2800 µs de CPU desperdiçados **por requisição**, só para
abrir e fechar uma conexão.

E esse é o **padrão do Django**. Uma aplicação Django+Postgres que ninguém
configurou está pagando isso.

A razão de ser tão caro é específica do Postgres: **cada conexão é um processo
do sistema operacional**, não uma thread. Abrir uma conexão significa um `fork`
no servidor, autenticação, criação de estrutura de sessão — e depois destruir
tudo. É o item nº 1 da lista de gargalos do doc 01, e agora tem número.

Detalhe revelador: nessa configuração o throttling caiu para **1,9%**. O sistema
nem chegava a esgotar a cota de CPU — estava lento demais para isso.

### Para leitura, Postgres e SQLite empatam — e o motivo é instrutivo

387,4 contra 384,7 rps. Diferença dentro do ruído.

Isso contraria a expectativa razoável de que uma ida à rede perderia para um
arquivo local. A explicação está na coluna do throttling: **96%**. A API está
congelada 96% dos períodos. Enquanto o worker espera a resposta do Postgres, ele
não estaria rodando de qualquer forma — a espera acontece durante um tempo que a
cota já havia confiscado.

> Sob throttling severo, **espera de I/O é de graça**. Ela só custa quando há
> CPU disponível sendo desperdiçada.

### Para escrita, Postgres ganha de 2,5x — e o número de workers inverte

Aqui está o resultado mais interessante do experimento:

| | 1 worker | 4 workers |
| - | - | - |
| SQLite | 214,3 rps · throttle **0%** | 421,4 rps · throttle 95% |
| Postgres | **528,4 rps** · throttle 95% | 382,9 rps · throttle 96% |

**Os dois bancos querem números de workers opostos.** SQLite quase dobra de 1
para 4; Postgres perde 28% no mesmo caminho.

A chave é a coluna do throttling do SQLite com 1 worker: **0%**. Ele não está
sem CPU — ele está **esperando disco**, dentro do próprio processo da API, e a
cota que sobra evapora sem ser usada. Adicionar workers dá a alguém o que fazer
enquanto um espera. É I/O-bound clássico.

O Postgres com 1 worker já throttla 95%: a escrita é **CPU-bound do lado da
API**. Como `synchronous_commit = off` tira a espera de disco do caminho
crítico, o que sobra para a API é só round-trip de rede curto e trabalho de
Python. Workers extras não têm espera para preencher — só somam overhead
(880 → 1232 µs/req).

**Eu errei uma previsão aqui, e vale registrar.** No fim do experimento 03 eu
disse que a conclusão "1 worker basta" provavelmente precisaria de revisão com o
Postgres, porque apareceria espera de I/O. O oposto aconteceu: com Postgres o
"1 worker" ficou **mais** verdadeiro, e quem precisava de mais workers era o
SQLite. Eu tinha localizado a espera de I/O no banco errado.

### Escrever é mais barato que ler

528,4 rps de escrita contra 387,4 de leitura, no mesmo banco. E o custo de CPU
explica: **880 µs/req contra 1212**.

Não é mágica. O `POST` faz um `UPDATE ... RETURNING` e um `INSERT`, e devolve
`{"limite":…, "saldo":…}` — dois números. O `GET` busca o cliente, busca 10
transações, e serializa 10 objetos com 4 campos cada. **O custo está na
serialização e no volume de dados, não na natureza de ler ou escrever.**

Isso tem consequência direta para a Rinha: a carga é de 330 transações/s contra
10 extratos/s. O endpoint raro é o caro.

### Sob a carga real, sobra folga

A 170 rps — a fatia de uma instância — a escrita entrega **p99 de 3,3ms com zero
throttling**. O SLA da competição é p98 abaixo de 250ms.

Com a ressalva de sempre: uma instância, um cliente só, sem a mistura de
endpoints da simulação, e sem o Gatling.

---

## 6. Ações decorrentes

- [x] `DATABASES` vem do ambiente; SQLite com WAL, Postgres com conexão persistente.
- [x] `CONN_MAX_AGE=None` como padrão do projeto — a diferença é de 4,75x.
- [x] `postgresql.conf` com `max_connections=20` e `synchronous_commit=off`,
      com o custo em durabilidade documentado no arquivo.
- [x] `infra/sql/{ddl,dml}.sql` gerados do schema real (`just gen-sql`), para
      que duas APIs subindo juntas não corram para criar as mesmas tabelas.
- [x] Healthcheck do Postgres com `-h 127.0.0.1` — sem isso ele aprova o
      servidor temporário da inicialização da imagem.
- [ ] Experimento 05: duas instâncias, orçamento completo e **Gatling**.
- [ ] Experimento 06: tipo de worker (`gthread`, ASGI/uvicorn) e async.
- [ ] Revisitar `synchronous_commit` como variável medida, não como decisão.

---

## 7. Aprendizados transversais

- **O padrão do framework não é o padrão razoável.** `CONN_MAX_AGE=0` custa 4,75x
  e vem ligado de fábrica.
- **Sob throttling, esperar I/O é de graça.** Isso inverte a intuição sobre o
  custo de trocar um banco local por um remoto.
- **O número ótimo de workers é propriedade do gargalo, não da aplicação.**
  I/O-bound quer mais workers; CPU-bound quer menos. O mesmo código mudou de
  categoria só ao trocar de banco.
- **Ler pode ser mais caro que escrever.** O que custa é o tamanho da resposta e
  a serialização, não o verbo HTTP.
