# go/02 — Tirando proveito da stack: as variantes, medidas

Este documento mede as quatro variantes do projeto Go, decide a configuração
padrão e consolida o que se aprendeu sobre **como esta stack se comporta sob
cota**. O experimento [`01`](./01-a-aplicacao-sai-da-frente.md) mediu a
configuração padrão contra as outras três linguagens; aqui a comparação é do Go
contra ele mesmo.

O resultado principal é desconfortável e tem precedente: **a bancada elege uma
configuração que a prova oficial recusa** — exatamente o que aconteceu em
[`fastapi/02`, §5.4](../fastapi/02-onde-esta-o-gargalo.md) com a repartição de
cota.

---

## 1. Ressalvas metodológicas

1. **As séries de leitura sob 0.60 CPU de banco são diagnóstico, não medida.** O
   banco satura (24,8% a 93,6% de períodos congelados) e a amplitude entre
   repetições vai de 35% a 44%. Por isso as variantes foram comparadas num rig
   com **o banco em 2 CPU** (`BENCH_TAG=db2`), onde a aplicação é o que varia.
2. **`DB_CPUS` não entra no slug** — só o `BENCH_TAG` que eu passei à mão.
   Esquecer a tag sobrescreve a série anterior, e foi o que aconteceu uma vez
   ([`01`](./01-a-aplicacao-sai-da-frente.md), ressalva 2).
3. **A comparação `SERIALIZACAO=manual|stdlib` é estreita por construção.** Na
   variante padrão (`EXTRATO_QUERY=unica`) o corpo do extrato é concatenado a
   partir do JSON que o Postgres já montou, em qualquer um dos dois modos — o
   serializador só decide a resposta do POST e o caminho `duas`. Medi as duas no
   caminho `duas`, que é onde a diferença pode existir.
4. **Onze execuções da prova oficial, num único dia e num único host**, com o
   Gatling disputando a máquina com a stack. Dois braços de cinco e seis
   execuções não são amostra grande para conclusões sobre cauda.
5. **Uma variante não foi medida**: `EXTRATO_QUERY=duas` na prova oficial. Ela
   perde na bancada e não havia motivo para gastar 4 minutos com ela.

---

## 2. Ambiente e commits

| | |
| - | - |
| commits | `3d54a24` (variantes), `875022d` (execuções oficiais de `auto`) |
| rig da bancada | `go/compose.bench-postgres.yml`, API 0.40 CPU |
| rig das variantes de leitura | o mesmo, com `DB_CPUS=2` e `BENCH_TAG=db2` |
| prova oficial | stack completa, 1.50 CPU / 550MB |

---

## 3. Comandos para replicar

```bash
# escrita: o braço em que a API é a parede
GOMAXPROCS=1 just bench-go transacoes 0.40

# leitura: banco folgado, para medir a APLICAÇÃO e não a saturação do Postgres
for p in auto 1; do GOMAXPROCS=$p DB_CPUS=2 BENCH_TAG=db2 just bench-go extrato 0.40; done
EXTRATO_QUERY=duas                     DB_CPUS=2 BENCH_TAG=db2 just bench-go extrato 0.40
EXTRATO_QUERY=duas SERIALIZACAO=stdlib DB_CPUS=2 BENCH_TAG=db2 just bench-go extrato 0.40
GOMAXPROCS=1 GOMEMLIMIT=80MiB just bench-go transacoes 0.40

# a decisão: prova oficial nos dois braços de GOMAXPROCS
GOMAXPROCS=1 just run go
just run go
```

---

## 4. `GOMAXPROCS`: o piso de 2 custa CPU e compra rajada

A pergunta central do projeto, registrada em
[`00`, §7.1](./00-indice.md): o Go 1.27 lê a cota do cgroup mas **arredonda para
cima até 2** (`runtime/cgroup_linux.go:85-92`), enquanto o OTP 27 desce a 1 sob a
mesma cota. O piso ajuda ou atrapalha?

### 4.1 Na bancada: `1` é claramente melhor

**Escrita** (API 0.40, banco 0.60 — o regime da competição):

| `GOMAXPROCS` | rps | CPU da API | **API congelada** | CPU do banco | banco congelado |
| - | - | - | - | - | - |
| `auto` (=2) | **1342,3** | 302,9 µs | **91,5%** | 461,4 µs | 89,8% |
| `1` | 1239,2 | **241,5 µs** | **0,0%** | 496,9 µs | 93,5% |

**20,3% menos CPU por requisição**, e a API **deixa de saturar a própria cota** —
de 91,5% de períodos congelados para zero. A vazão cai 7,7% porque o gargalo
passou inteiro para o banco.

**Leitura**, com o banco em 2 CPU para isolar a aplicação:

| `GOMAXPROCS` | rps | CPU da API | API congelada | **amplitude** |
| - | - | - | - | - |
| `auto` (=2) | **3638,2** | 95,9 µs | 17,0% | **25,0%** |
| `1` | 2806,6 | **81,5 µs** | **0,0%** | **1,7%** |

**15,0% menos CPU por requisição**, e a amplitude entre repetições cai de 25,0%
para **1,7%** — a série mais estável de todo o projeto Go.

O mecanismo é o mesmo que [`django/04`](../django/04-postgres.md) mediu com
workers de Gunicorn: **sob cota fracionária, paralelismo custa CPU sem ter onde
ser gasto**. Duas threads disputando 0,40 de uma CPU pagam sincronização,
migração entre núcleos e trocas de contexto que uma thread não paga. A diferença
é que aqui não são processos com pool próprio, são duas threads do mesmo
scheduler — e ainda assim custa 15% a 20%.

**A previsão nº 5 de [`00`, §6](./00-indice.md) está errada.** Ela dizia que
`GOMAXPROCS=2` *"não vai perder para 1 de forma mensurável"*, apostando contra o
histórico do laboratório. Perde de forma bem mensurável, e o histórico estava
certo de novo.

### 4.2 Na prova oficial: `auto` é melhor, e é o que vale

| `GOMAXPROCS` | execuções | abaixo de 250ms | p98 por execução | máximo por execução |
| - | - | - | - | - |
| `auto` | 6 | **100% em todas** | 4, 4, 4, 5, 4, 51* | 216, 207, 104, 197, 149, 960* |
| `1` | 5 | 100%, 100%, 100%, 100%, **99,61%** | 4, 5, 5, **37**, **68** | 89, 63, 58, 240, 389 |

\* a execução de 51ms/960ms é a **primeira de todas**, a rodada de aquecimento
([`00`, §7.5](./00-indice.md)).

Descartada aquela, `auto` deu **p98 de 4 a 5ms em cinco execuções seguidas**,
enquanto `1` produziu duas execuções ruins em cinco — uma delas abaixo de 100%
dentro do SLA, a única de todo o projeto Go.

Na carga real a API consome, por requisição:

| `GOMAXPROCS` | CPU da API na carga real | execuções |
| - | - | - |
| `auto` | 224,7 / 228,6 / 226,9 / 231,8 / 230,6 µs | estável (±1,6%) |
| `1` | 164,7 / 168,3 / 175,2 / 190,7 / 214,9 µs | **21% mais barato, e disperso (±26%)** |

**`1` é mais barato e mais irregular; `auto` é mais caro e previsível.** Sob 340
req/s nada satura — a stack usa ~13% do orçamento — e aí a segunda thread deixa
de ser desperdício e passa a ser o que absorve as rajadas do modelo aberto.

É a mesma conclusão de [`fastapi/02`, §5.4](../fastapi/02-onde-esta-o-gargalo.md),
com outro botão: *otimização medida em saturação não se transfere para a carga
real; se o sistema não satura no uso previsto, a folga não é desperdício, é o
amortecedor da cauda.*

**Decisão: o padrão fica `GOMAXPROCS=auto`.** O braço `1` fica documentado como
a escolha certa para quem for limitado por **custo de CPU** — que a Rinha não é.

---

## 5. As outras três variantes

### 5.1 `EXTRATO_QUERY`: a query única paga 1,25x

Leitura, `GOMAXPROCS=1`, banco em 2 CPU:

| variante | rps | CPU da API | amplitude |
| - | - | - | - |
| `unica` | 2806,6 | **81,5 µs** | 1,7% |
| `duas` | 2709,8 | 101,9 µs | 12,0% |

**1,25x**, e o número é bonito de propósito: é o **mesmo 1,25x** que
[`fastapi/01`](../fastapi/01-fastapi-async.md) mediu na mesma variante, com outra
linguagem e outro driver. Duas implementações independentes chegando ao mesmo
fator é a melhor evidência disponível de que o ganho é da **técnica** (deixar o
Postgres montar o array e não desserializar para re-serializar), não da stack.

Confirma a escolha herdada, e ela continua padrão.

### 5.2 `SERIALIZACAO`: montar JSON à mão **não paga**

Mesmo rig, caminho `duas` (o único em que o serializador decide o array):

| variante | CPU da API | amplitude |
| - | - | - |
| `manual` (concatenação em `[]byte`) | 101,9 µs | 12,0% |
| `stdlib` (`encoding/json`) | 100,5 µs | 23,2% |

**1,4% de diferença, com amplitudes de 12% e 23%: não é atribuível.** O
`encoding/json` custa o mesmo que montar os bytes à mão.

Isto contraria a intuição comum sobre reflexão em Go, e é o terceiro resultado
desta família no projeto: o pydantic não pagou no FastAPI
([`fastapi/03`, §4.4](../fastapi/03-o-que-a-troca-de-framework-comprou.md)), as
duas bibliotecas de JSON empataram no Elixir, e agora a serialização manual
empata com a padrão no Go. **Em payloads pequenos, o serializador não é o
gargalo em lugar nenhum.**

Consequência prática, e ela é sobre código e não sobre desempenho: as ~40 linhas
de `marshalExtratoManual` e `respostaTransacao` existem hoje **como braço de
experimento, não como otimização**. Num projeto real elas seriam código a menos.

### 5.3 `GOMEMLIMIT`: sem efeito, como previsto

Escrita, `GOMAXPROCS=1`:

| variante | rps | CPU da API |
| - | - | - |
| sem `GOMEMLIMIT` | 1239,2 | 241,5 µs |
| `GOMEMLIMIT=80MiB` | 1297,6 | 234,5 µs |

2,9% com amplitudes de 4,3% e 5,3% — ruído. Era o esperado: a armadilha nº 3 de
[`00`, §5](./00-indice.md) pressupõe um heap que cresce até perto do teto, e este
processo usa **2,6 MB de 100 MB** ocioso e não passa disso sob carga. `GOMEMLIMIT`
é o botão certo para o problema errado nesta stack.

---

## 6. A configuração eleita

```
GOMAXPROCS=auto      # o piso de 2 custa 15-20% de CPU e compra cauda estável
EXTRATO_QUERY=unica  # 1,25x, o mesmo fator que o FastAPI mediu
SERIALIZACAO=manual  # empata com stdlib; fica por ser o braço de controle
DB_POOL_MAX=8        # 2 APIs x 8 + folga <= max_connections = 20
GOMEMLIMIT=          # vazio: não há pressão de memória para administrar
```

É a configuração que já era padrão. **Duas das quatro variantes não mudam nada
de forma atribuível**, uma confirma a escolha herdada, e a única que muda muito
(`GOMAXPROCS`) foi decidida contra a bancada e a favor da prova oficial.

---

## 7. O que se aprendeu sobre a stack Go

Consolidação — cada item com o número que o sustenta.

**1. `GOMAXPROCS` é o único botão que importa sob cota, e o padrão do 1.27 já
está certo para esta carga.** Não porque a armadilha não exista, mas porque o
runtime aprendeu a ler o cgroup e o piso de 2 é bom para cauda. Nada de
`automaxprocs`, que a previsão de `django/06` recomendava e que hoje seria
redundante.

**2. `runtime.NumCPU()` continua mentindo — 20 dentro de 0.40 CPU.** É a
armadilha de `django/02` intacta. Nesta aplicação nada se dimensiona por ele, e
isso é decisão consciente, não sorte: pool, acceptors e workers são todos
constantes ou vêm do ambiente.

**3. O pool do `pgxpool` precisa de vida FINITA e longa, nunca zero.** Zero é
"vencida ao nascer" (`pool.go:463`), não "sem limite" — o oposto do asyncpg. Ver
[`00`, §7.3](./00-indice.md).

**4. O `pgx` reusa prepared statements por padrão**, e isso foi **medido**, não
lido: 48 planos para 36.014 chamadas
([`01`, §4](./01-a-aplicacao-sai-da-frente.md)).

**5. A biblioteca padrão bastou.** `net/http` com `ServeMux` de método e
wildcard, `encoding/json`, `testing`. Nenhum framework, nenhum roteador de
terceiros, nenhuma biblioteca de JSON alternativa — e a stack é a mais barata
das quatro nos dois endpoints.

**6. Otimização manual de serialização é código morto aqui** (§5.2). O mesmo
vale, por extensão, para o instinto de trocar `encoding/json` por uma biblioteca
"rápida" antes de medir.

**7. O socket Unix funciona sem cerimônia**: `net.Listen("unix", ...)`, remover o
arquivo antes e `umask 0` no entrypoint. Mesmo trio das outras três stacks.

**8. O custo do Go não é desempenho, é linha de código.** 688 linhas de
aplicação contra 442 do Elixir, 318 do FastAPI e 289 do Django (com framework).
**156 delas — 23% — são blocos `if erro != nil`.** É o assunto do
[`03`](./03-quatro-stacks-quatro-linguagens.md).

---

## 8. Ações decorrentes

- [x] Todas as variantes medidas; padrão confirmado.
- [ ] Considerar **remover** `SERIALIZACAO=manual` do código de produção e
      manter só `stdlib`: são ~40 linhas que não compram desempenho. Fica como
      proposta, não como mudança — remover um braço de experimento depois de
      medi-lo é diferente de nunca tê-lo tido.
- [ ] Repetir a prova oficial do braço `GOMAXPROCS=1` mais vezes: duas execuções
      ruins em cinco é o tipo de coisa que 15 execuções esclarecem e 5 não.
- [ ] Medir memória **sob carga** — todo número de memória deste projeto é de
      stack ociosa.
