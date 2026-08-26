# Testes de performance — Go

Índice geral em [../00-indice.md](../00-indice.md). A numeração reinicia aqui: o
experimento 01 do Go **não** é continuação do 04 do Elixir.

| # | Experimento | Data | Estado |
| - | - | - | - |
| [01](./01-a-aplicacao-sai-da-frente.md) | A aplicação sai da frente: **a mais barata das quatro** nos dois endpoints, e na leitura **o banco vira a parede** (93,5% de throttling) | 2026-08-25 | **concluído** |
| [02](./02-tirando-proveito-da-stack.md) | As variantes, medidas: a bancada elege `GOMAXPROCS=1` e **a prova oficial recusa** | 2026-08-25 | **concluído** |
| [03](./03-quatro-stacks-quatro-linguagens.md) | As quatro stacks sob a cota da Rinha, **e quanto código cada uma custou** | 2026-08-25 | **concluído** |
| [04](./04-sem-cota.md) | As quatro sem limitação de hardware, em 20 vCPU | 2026-08-25 | **concluído** |
| [05](./05-bloco-b-estrategias-de-concorrencia.md) | **Bloco B**: as quatro estratégias de concorrência. B2 vence — por 9% a 15%, não "por larga margem" | 2026-08-25 | **concluído** |

A prova oficial marcou USD 100.000 com zero inconsistências em quatro execuções.
As duas limpas e aquecidas deram **100% abaixo de 250ms e p98 de 4ms** — o melhor
das quatro stacks. A afirmação anterior, de que a cauda era a pior, vinha de uma
única execução, que era a primeira (seção 7.5).

Este arquivo é o documento de abertura do projeto. Ele registra o que se pretende
construir, as previsões **antes** de existir implementação, e as poucas medições
que já foram feitas — todas sobre o runtime cru, nenhuma sobre a aplicação.

---

## 1. Por que este projeto existe

Ele fecha a última pendência de linguagem registrada em
[`django/06`, seção 8](../django/06-tipos-de-worker.md). Eram três perguntas
naquela seção; duas já foram respondidas:

| pergunta | resposta | onde |
| - | - | - |
| trocar de framework **dentro** do Python? | 1,73x na escrita, 4,00x na leitura — e a maior parte da leitura era o ORM, não o framework | [fastapi/03](../fastapi/03-o-que-a-troca-de-framework-comprou.md) |
| trocar de linguagem **e** de máquina virtual? | o Elixir é o mais barato dos três, mas só depois que um bug meu foi corrigido | [elixir/04](../elixir/04-o-statement-que-nao-era-reusado.md) |
| **e uma linguagem compilada, sem VM?** | **este projeto** | — |

O Go é o único dos quatro que **não tem máquina virtual**: o runtime é ligado
dentro do binário, não é um interpretador. É a diferença que a tabela da seção 2
de [elixir/00](../elixir/00-indice.md) já antecipava, e que aqui vira medição.

---

## 2. Vocabulário: quem é quem no Go

Mesma tabela de mapeamento que o projeto Elixir abriu, pelo mesmo motivo — o
autor deste repositório vem de Python, e cada peça precisa achar seu par no que
já está medido.

| Camada | Python (medido) | Elixir (medido) | **Go** | O que faz |
| - | - | - | - | - |
| Driver do banco | `asyncpg` | Postgrex | **`pgx/v5`** | Protocolo binário do Postgres |
| ORM | Django ORM | Ecto | GORM, `sqlc`, `ent` | **não usado aqui** |
| Servidor HTTP | uvicorn | Bandit | **`net/http`** (biblioteca padrão) | Aceita TCP, faz parsing de HTTP |
| Contrato servidor↔app | ASGI/WSGI | Plug | **`http.Handler`** | Uma interface de um método |
| Framework completo | Django/FastAPI | Phoenix | Gin, Echo, Fiber, Chi | **não usado aqui** |
| Roteamento | `APIRouter` | `Plug.Router` | **`http.ServeMux`** com padrões de método e wildcard | `POST /clientes/{id}/transacoes` |
| Gerenciador de pacotes | `uv`/`pip` | Hex | **módulos** (`go.mod`, `go.sum`) | Baixa e trava versões |
| Ferramenta de projeto | `manage.py`, `uv run` | Mix | **`go`** (`build`, `test`, `vet`) | Vem na distribuição |
| Framework de teste | pytest | ExUnit | **`testing`** | Também na biblioteca padrão |
| Gerenciador de versão | pyenv | mise/asdf | `mise`, ou nenhum | Aqui: **nenhum** — só container |

### As três decisões de escopo, e por quê

**Sem framework web.** O par estrutural do FastAPI (casca fina sobre Starlette) e
do `Plug.Router` sobre Bandit é a **biblioteca padrão**. Desde o Go 1.22 o
`http.ServeMux` entende método e variável de caminho (`POST /clientes/{id}/...`),
que é tudo o que dois endpoints precisam. Escolher Fiber traria o `fasthttp`
junto — outro servidor HTTP, que nem sequer implementa `net/http` — e a
diferença medida deixaria de ser atribuível à linguagem. Se um dia a pergunta
for *"quanto custa o fasthttp"*, ele entra como variante própria, com o número
da stdlib do lado.

**Sem ORM, e sem `database/sql`.** O `pgx` é o par honesto de `asyncpg` e
`Postgrex`. Usá-lo através de `database/sql` seria pior que neutro: aquela
camada desliga o protocolo binário e o cache de statements do pgx — exatamente o
mecanismo que custou 3,97x de CPU de banco ao Elixir em
[`04`](../elixir/04-o-statement-que-nao-era-reusado.md). Reintroduzi-lo por
camada de compatibilidade seria repetir o mesmo erro com outro nome.

**Sem Go instalado no host.** Não há `go` no PATH desta máquina e não vai haver:
compilação e testes rodam na mesma imagem que o `Dockerfile` usa, via
`just go ...`, do mesmo jeito que `just ex` roda Mix sem exigir Elixir local.

---

## 3. A versão: Go 1.27.0

Decisão do dono do projeto, registrada porque **muda o experimento**: usar a
estável mais recente, e não a versão que a previsão de 2026-08-22 tinha em mente.
*"Não adianta estudar algo que não vai estar na evolução da linguagem daqui para
frente."*

Consequência direta: a armadilha nº 1 da seção 5 **não existe mais na forma
prevista**, e isso já está medido na seção 7. É a mesma coisa que aconteceu com o
Elixir — a previsão sobre `+S` foi neutralizada pelo OTP 27 antes de a primeira
série rodar — e as duas ficam registradas como estão. Um documento que só tem
acertos não é um diário.

| | versão | por quê |
| - | - | - |
| Go | **1.27.0** | estável mais recente em 2026-08-25 |
| `pgx` | **v5.10.0** | estável mais recente |
| imagem de build | `golang:1.27-alpine` | mesma base Alpine das outras três stacks |
| imagem final | `alpine:3.21` | idêntica à do Elixir, de propósito |

---

## 4. O binário não precisa de runtime — e o que isso muda no Dockerfile

A tabela da seção 2 de [elixir/00](../elixir/00-indice.md) previa esta linha; aqui
ela é a nossa:

| Linguagem | O que sobra no estágio final | Ganho do multi-stage |
| - | - | - |
| **Go** | **um binário estático** | **enorme** — a imagem poderia ser `scratch` |
| Elixir | bytecode `.beam` + ERTS (~15–25MB) | grande |
| Python | interpretador + dependências | modesto |

Duas notas sobre isso, e as duas são ressalvas, não vantagens:

1. **A imagem não conta no orçamento de 550MB.** O que conta é a memória
   residente e o tempo de subida (limite de 40s). Um binário menor não vale
   ponto — vale espera menor em cada um dos dezenas de ciclos de teste.
2. **O estágio final será `alpine:3.21`, não `scratch`.** Poderia ser `scratch`,
   e não vai ser: as outras três stacks rodam em Alpine, com usuário 10001 e
   `/sockets` pré-criado. Trocar a base junto com a linguagem colocaria libc e
   imagem no meio de uma comparação que quer medir linguagem. `CGO_ENABLED=0`
   garante que o binário não dependa da libc de qualquer forma — a base vira só
   um lugar para o entrypoint e o usuário morarem.

---

## 5. As armadilhas do Go sob cgroup

Três, e todas com precedente medido neste laboratório.

**1. `GOMAXPROCS` por núcleo visível.** É a previsão explícita de
[`django/06`, seção 8](../django/06-tipos-de-worker.md): *"o runtime do Go define
`GOMAXPROCS` pelo número de núcleos visíveis, então uma porta ingênua subiria 20
threads disputando 0.40 CPU"*. O mecanismo é real e está medido —
[`django/02`](../django/02-container-e-cgroup.md) viu `os.cpu_count() = 20`
dentro de 0.40 CPU, e [`django/04`](../django/04-postgres.md) mediu 4 workers de
Gunicorn perdendo para 1. **A seção 7.1 mostra que o Go 1.27 não cai mais nela —
mas também não faz o que a BEAM faz.**

**2. Statement replanejado a cada chamada.** A armadilha mais cara já encontrada
aqui, e ela não estava em previsão nenhuma:
[`elixir/04`](../elixir/04-o-statement-que-nao-era-reusado.md) mediu `plans =
calls` e **62,2% do tempo de banco planejando**, por uma opção de driver que eu
supus em vez de conferir. A seção 7.2 confere o padrão do `pgx` **no fonte** —
mas a conferência no fonte **não substitui** `just diag-prepared go`, que é o
primeiro comando a rodar quando a stack subir. A lição do elixir/04 não é
"conheça o driver": é *quando a hipótese vier com o método ao lado, execute o
método*.

**3. O GC não sabe do limite de memória do cgroup.** Mesmo mecanismo da armadilha
1, aplicado a outro recurso: o runtime dimensiona o *heap alvo* por `GOGC`
(padrão 100%, ou seja, coleta quando o heap dobra) sem saber que o teto é 100MB.
`GOMEMLIMIT` é o botão que informa o teto ao runtime. O precedente é a seção 7.2
de [elixir/00](../elixir/00-indice.md): a BEAM bateu no teto do cgroup 566 vezes
ao subir, tudo *page cache*, sem uma morte por OOM. Aqui a previsão é que sobre
folga — mas *"a memória é o risco real"* já foi escrito uma vez neste
laboratório e estava errado, então fica como ponto a vigiar, não como certeza.

Uma quarta, herdada e resolvida: **o socket Unix**.
[`django/03`](../django/03-nginx-e-socket-unix.md) mediu 2,9x em vazão alta e a
amplitude caindo de 246% para 3,9% no salto nginx→API. No Go é
`net.Listen("unix", caminho)`, com duas obrigações que já custaram tempo nas
outras stacks: **remover o arquivo antes** (um socket é um arquivo; se sobrar de
um container anterior, o `bind` falha com "address already in use", que não tem
nada a ver com porta ocupada) e **`umask 0`** no entrypoint, porque o nginx roda
com outro usuário.

---

## 6. Previsões registradas ANTES de medir

Copiadas de [`django/06`, seção 8](../django/06-tipos-de-worker.md), escritas em
2026-08-22. **Não editar.** O valor delas está em poder estarem erradas, e as
duas linhas medidas mostram como isso funciona: a do FastAPI acertou na escrita e
subestimou a leitura pelo motivo errado; a do Elixir foi declarada errada por
excesso e depois, corrigido o bug, revelou-se mais acertada do que o meu erro
deixava parecer.

| | CPU/req | vs. Django | pontuação |
| - | - | - | - |
| Django + Gunicorn sync (**medido**) | **862,4 µs** | — | 100.000 |
| FastAPI + uvicorn + asyncpg (**medido**) | **499,7 µs** | 1,73x | 100.000 |
| Elixir + Bandit + Postgrex (**medido**) | **462,5 µs** | 1,86x | 100.000 |
| **Go + pgx (previsto)** | **50–100 µs** | **8–17x** | 100.000 |

A previsão específica e testável, na íntegra:

> **Uma porta Go sem `GOMAXPROCS` ajustado teria cauda pior que o Django atual**,
> mesmo sendo muito mais rápida por requisição. Com `GOMAXPROCS=1` (ou
> `automaxprocs`), aí sim os 8-15x apareceriam.

E a de memória, da mesma seção:

> Ganho colateral: memória. O container Python usa ~54MB; um binário Go usaria
> 10-20MB, liberando ~70MB por instância para o Postgres dentro do orçamento de
> 550MB.

Acrescento, antes de existir código, as que este projeto pode desmentir sozinho:

1. **A pontuação continua em USD 100.000**, e continua não significando nada. É a
   quarta vez que isto é previsto e a quarta vez que não custa nada prever.
2. **A previsão de 50–100 µs vai errar por baixo na escrita.** O custo de banco
   da escrita é ~485 µs *no Postgres* nas duas stacks que já reusam statements
   ([elixir/04, §5.2](../elixir/04-o-statement-que-nao-era-reusado.md)), e o
   `INSERT` mais o `UPDATE` dentro de uma transação não ficam mais baratos por a
   aplicação ser compilada. Os 50–100 µs, se aparecerem, aparecem no **extrato**.
3. **A atribuição vai ser o problema de sempre, na dose máxima.** Mudam
   linguagem, runtime, modelo de concorrência, driver e servidor HTTP de uma vez
   — é o que a seção 4.1 de [fastapi/03](../fastapi/03-o-que-a-troca-de-framework-comprou.md)
   chamou de conclusão mais desconfortável do projeto, e a previsão daquele
   documento sobre o Go dizia exatamente isto.
4. **O nginx vira o serviço proporcionalmente mais carregado da stack.** Ele já
   é, no Elixir, com 43,3% da cota contra ~19% das APIs
   ([elixir/04, §5.4](../elixir/04-o-statement-que-nao-era-reusado.md)). Uma API
   mais barata só empurra mais a proporção — e nada nesta stack torna o nginx
   mais rápido.
5. **`GOMAXPROCS=2` (o padrão do 1.27 sob 0.40 CPU) não vai perder para
   `GOMAXPROCS=1`** de forma mensurável. Aposta própria, e contra o histórico do
   laboratório: 4 workers perderam para 1 no Gunicorn, mas ali eram *processos*
   com pool de conexões próprio; aqui são duas threads de um scheduler que
   compartilha tudo. Se eu estiver errado, é o achado mais interessante do
   projeto.

---

## 7. Medições feitas antes de existir código

Não são experimento: são o runtime cru, medido para saber que perguntas fazer.
Mesmo papel da seção 7 de [elixir/00](../elixir/00-indice.md) — e, como lá, **uma
delas já derruba uma previsão**.

### 7.1 O Go 1.27 lê a cota do cgroup, com piso de 2

```bash
docker run --rm --cpus=0.4 -v "$PWD":/src -w /src golang:1.27-alpine go run .
# main.go: fmt.Printf("GOMAXPROCS=%d NumCPU=%d\n", runtime.GOMAXPROCS(0), runtime.NumCPU())
```

| cota do container | `GOMAXPROCS` | `NumCPU()` |
| - | - | - |
| sem cota | 20 | 20 |
| 0.40 CPU | **2** | 20 |
| 1 CPU | **2** | 20 |
| 2 CPU | 2 | 20 |
| 4 CPU | 4 | 20 |

A regra está no fonte, em `runtime/cgroup_linux.go:85-92`:

> GOMAXPROCS is the minimum of: 1. Total number of logical CPUs available from
> `sched_getaffinity`. 2. The average CPU cgroup throughput limit (average
> throughput = quota/period). **A limit less than 2 is rounded up to 2**, and any
> fractional component is rounded up.

Três leituras, em ordem de importância:

1. **A previsão de `django/06` está morta como estava escrita.** Não existem "20
   threads disputando 0.40 CPU": o runtime enxerga 20 núcleos (`NumCPU` continua
   20, exatamente como `os.cpu_count()` do Python) mas se dimensiona pela cota.
   O `automaxprocs` que a previsão sugeria virou desnecessário.
2. **O Go não faz o que a BEAM faz.** Sob 0.40 CPU o OTP 27 sobe **1** scheduler
   ([elixir/00, §7.1](../elixir/00-indice.md)); o Go 1.27 insiste em **2**, por
   piso explícito. Sob a cota da competição, portanto, existem duas threads
   disputando 0,40 de uma CPU — pouco, mas não uma. A variante `GOMAXPROCS=1`
   deixa de ser "a correção da armadilha" e passa a ser **o experimento**: o piso
   de 2 ajuda ou atrapalha sob cota? A previsão nº 5 da seção 6 aposta que não
   muda nada mensurável.
3. **`NumCPU()` continua mentindo.** Qualquer código que dimensione pool ou
   worker por `runtime.NumCPU()` — e é idioma comum em Go — cai na armadilha
   original, mesmo com o `GOMAXPROCS` corrigido. A aplicação não vai usar
   `NumCPU()` em lugar nenhum, e isso precisa ficar escrito no código.

### 7.2 O `pgx` reusa statements por padrão — conferido no fonte

A regra do `CLAUDE.md` que o elixir/04 escreveu com sangue: **verificar no fonte
antes de afirmar comportamento de biblioteca, citando arquivo e linha.**

Em `pgx@v5.10.0/conn.go:191`:

```go
defaultQueryExecMode := QueryExecModeCacheStatement
```

e em `conn.go:288`, na abertura de cada conexão:

```go
if c.config.StatementCacheCapacity > 0 {
    c.statementCache = stmtcache.NewLRUCache(c.config.StatementCacheCapacity)
}
```

`QueryExecModeCacheStatement` (`conn.go:537-543`) procura o SQL no cache LRU da
conexão e só chama `Prepare` quando não acha. Ou seja: **o padrão do `pgx` é o
comportamento que o Postgrex só teve depois de `cache_statement:` explícito**, e
o equivalente do bug do elixir/04 exigiria escolher ativamente
`QueryExecModeExec` ou `QueryExecModeSimpleProtocol`.

**Isto não fecha a questão.** É a conferência no fonte, que é metade da regra; a
outra metade é a medição, e ela é `just diag-prepared go` com a stack de pé,
esperando `plans = 0`. O elixir/04 é claro sobre a ordem que custou dois
documentos: a hipótese vinha com o método ao lado e eu medi outras coisas antes.

### 7.3 O zero do `pgxpool` não é "sem limite" — e a stack não subia

Achado da primeira subida, e é da mesma família do erro do
[`elixir/04`](../elixir/04-o-statement-que-nao-era-reusado.md): uma opção de
driver copiada de outra stack, cuja semântica eu supus em vez de conferir.

O FastAPI passa `max_inactive_connection_lifetime=0` ao asyncpg, e ali zero
significa **nunca recicle a conexão** — a decisão que `django/04` sustenta com
4,75x entre conexão persistente e conexão nova por requisição. Traduzi para
`MaxConnLifetime = 0` no pgx, e a API morria na subida:

```
erro: banco: pgxpool: too many failed attempts acquiring connection;
      likely bug in PrepareConn, BeforeAcquire, or ShouldPing hook
```

A mensagem aponta para hooks que este código não usa. A causa está em
`pgxpool/pool.go:463`:

```go
func (p *Pool) isExpired(res *puddle.Resource[*connResource]) bool {
	return time.Now().After(res.Value().maxAgeTime)
}
```

`maxAgeTime` é o instante de criação **mais** `MaxConnLifetime`. Com zero, toda
conexão nasce vencida e é destruída no primeiro `Acquire` (`pool.go:624`), num
laço que desiste depois de algumas tentativas. Os padrões do pgx são finitos —
uma hora de vida e trinta minutos de ociosidade (`pool.go:22-23`) — e a forma de
dizer "nunca recicle" a esta API é um valor grande e finito.

**A falha foi barulhenta, e é o único motivo de ela ter custado dez minutos em
vez de três experimentos.** Se o zero tivesse significado "recicle a cada
requisição" em vez de "destrua imediatamente", a stack teria subido, respondido
tudo corretamente, e cada requisição teria pago uma conexão nova — os mesmos
4,75x de `django/04`, silenciosamente, dentro de um número plausível.

### 7.4 Observações da subida

Não são resultado de experimento: são o que a stack mostrou ao subir pela
primeira vez, com os 13 testes do `smoke` passando.

| | Go | Elixir | FastAPI | Django |
| - | - | - | - | - |
| subida da stack | **4s** | 4–7s | 7s | ~20s |
| memória por API, ociosa | **2,6 MB** | ~38 MB | ~43 MB | ~54 MB |
| `memory.events` do cgroup | **tudo zero** | `max 566` | — | — |
| imagem da API | **42 MB** | 81 MB | 251 MB |  — |

Três leituras:

1. **A previsão de memória de `django/06` errou por excesso, e para o lado bom.**
   Ela dizia "10-20MB contra os ~54MB do Python"; são **2,6 MB** com a stack
   ociosa. Sob carga isso muda — o heap cresce com as requisições em voo — e é
   por isso que a linha fica como observação, não como conclusão.
2. **Nenhum evento de pressão de memória no cgroup.** O Elixir bateu no teto 566
   vezes só para subir (§7.2 de [elixir/00](../elixir/00-indice.md)); aqui os
   contadores estão todos em zero. Um binário estático de 42MB não paga o custo
   de page cache que ler um release inteiro do disco paga.
3. **O `GOMAXPROCS=2` da seção 7.1 aparece no log da API**, junto com
   `NumCPU=20`. A linha é impressa de propósito em toda subida: é o que permite
   conferir, depois, com que dimensionamento cada série rodou.

### 7.5 A prova oficial, quatro execuções — e a correção da primeira

**A conclusão anterior desta seção estava errada, e o erro foi meu.** Ela dizia,
com base numa única execução, que o Go entregava *"a pior cauda das quatro
stacks"*. Era a **primeira execução da configuração** — exatamente o que a regra
do projeto manda descartar, e que eu aplico religiosamente na bancada e não
apliquei aqui.

| execução | instrumentada? | abaixo de 250ms | acima de 250ms | p98 | p99 | máximo |
| - | - | - | - | - | - | - |
| `20260825T173713` (**a 1ª de todas**) | não | 98,566% | **882** | 51 ms | 443 ms | 960 ms |
| `20260825T191408` | **sim** (ver 7.6) | 99,946% | 33 | 5 ms | 147 ms | 296 ms |
| `20260825T191953` | não | **100,000%** | **0** | **4 ms** | **5 ms** | 216 ms |
| `20260825T192431` | não | **100,000%** | **0** | **4 ms** | **5 ms** | 207 ms |

As duas execuções limpas e aquecidas dão **100% abaixo de 250ms com p98 de 4ms**
— o melhor resultado das quatro stacks, não o pior:

| | Django | FastAPI | Elixir | **Go** |
| - | - | - | - | - |
| abaixo de 250ms | 100% | 100% | ~100% | **100%** |
| p98 | 7 ms | 5 ms | 5 ms | **4 ms** |
| máximo | 76–94 ms | 246 ms | 51–101 ms | **207–216 ms** |
| subida | ~20 s | 7 s | 7 s | **7–8 s** |
| pontuação | 100.000 | 100.000 | 100.000 | **100.000** |
| inconsistências | 0 | 0 | 0 | **0** |

**O que a primeira execução tinha de diferente**, e por que o padrão dela (240
segundos limpos seguidos de 4 segundos catastróficos) não voltou em nenhuma
outra: era a primeira vez que aquele volume Docker existia, aquele banco
escrevia, e aquele binário rodava naquela máquina. O laboratório já tinha a
regra escrita — *"a primeira execução de qualquer configuração é
sistematicamente mais lenta"* — e ela vale para a prova oficial tanto quanto
para o `oha`.

**Ressalva que fica**: o pico continua sem explicação mecânica. Ele não voltou
em três execuções, mas "não reproduziu" não é o mesmo que "sei o que foi". As
hipóteses da versão anterior desta seção — checkpoint do Postgres, GC, aquecimento
de page cache — continuam abertas, e agora com a informação de que o fenômeno é
de **primeira execução**, o que joga a suspeita para o lado do que só acontece
uma vez.

Consumo por serviço na carga real, nas duas execuções limpas:

| serviço | Elixir | **Go** (`191953` / `192431`) | % da cota | throttling |
| - | - | - | - | - |
| api01 | 297,3 µs | **224,4 / 228,0 µs** | ~14% | 0,0% |
| api02 | 300,8 µs | **224,9 / 229,1 µs** | ~14% | 0,0% |
| db | 316,8 µs | **298,3 / 302,8 µs** | ~12% | 0,1% |
| nginx | 168,4 µs | 174,7 / 178,2 µs | ~44% | 0,1% |

A stack inteira usa ~13% do orçamento de 1.5 CPU na carga que a competição
aplica, e — como no Elixir — **o nginx é o serviço proporcionalmente mais
carregado**, com o triplo da ocupação de qualquer outro.

### 7.6 O instrumento entrou na conta: `docker exec` roda dentro do cgroup medido

A execução `20260825T191408` rodou com `scripts/cgroup-serie.sh` amostrando
`cpu.stat` de todos os serviços a cada segundo. O efeito dele apareceu no
próprio resultado:

| serviço | sem instrumento | **com instrumento** | inflação |
| - | - | - | - |
| api01 | 224,4 µs | 266,4 µs | +19% |
| db | 298,3 µs | 414,7 µs | **+39%** |
| nginx | 174,7 µs | 234,1 µs | +34% |
| nginx congelado | 0,1% | **20,6%** | — |

**`docker exec` cria o processo dentro do cgroup do container alvo.** Cada
amostra, portanto, gasta a cota *do serviço medido* — e o serviço mais afetado é
o de menor cota, o nginx com 0.10 CPU, que passou de 0,1% para 20,6% de períodos
congelados só por ser observado.

Consequências práticas, e nenhuma delas é "jogar o instrumento fora":

- A série por segundo serve para achar **quando** algo acontece, jamais para
  medir **quanto** custa. Está escrito no cabeçalho do script, e agora com
  número.
- Para serviços de cota pequena ela é inutilizável mesmo qualitativamente: os
  33% de "períodos congelados" que ela mostrou no nginx durante a stack
  **ociosa** eram o próprio `docker exec`.
- O `cgroup-snapshot.sh` (duas fotos, antes e depois) não tem esse problema, e é
  por isso que ele é quem alimenta `resultados/`.

### 7.7 O que ainda não foi medido

Custo por requisição **na bancada** (o número comparável entre projetos),
comportamento sob saturação, memória sob carga, e as variantes `GOMAXPROCS`,
`EXTRATO_QUERY`, `SERIALIZACAO` e `GOMEMLIMIT` — nenhuma foi exercitada em série
ainda. E, antes de qualquer uma delas, `just diag-prepared go`.

---

## 8. O que se mantém idêntico (uma variável por vez)

Lista herdada da seção 6 de [fastapi/03](../fastapi/03-o-que-a-troca-de-framework-comprou.md)
e da seção 5 de [elixir/00](../elixir/00-indice.md). Sem isto a comparação não
vale:

- schema e carga inicial: `infra/sql/ddl.sql` e `dml.sql`, tabelas `crebitos_*`,
  índice `idx_transacao_extrato` — inclusive a tabela `django_migrations`, peso
  morto mantido de propósito
- estratégia de concorrência: `UPDATE ... WHERE saldo + $1 >= -limite RETURNING`,
  com o `INSERT` na mesma transação
- SQL do extrato: o mesmo texto, **produzindo os mesmos bytes de resposta** —
  há teste para isso nas outras stacks e haverá aqui
- load balancer: `infra/nginx/nginx-rinha.conf`, socket Unix, round-robin
- configuração do banco: `infra/postgres/postgresql.conf`, `max_connections = 20`
- repartição da cota: nginx 0.10, API 0.40 × 2, banco 0.60
- bancada: `oha`, 10s, 5 repetições, aquecimento descartado, concorrência 50
- estado inicial: 50 transações por cliente, mesmos valores, mesma ordem
- hacks: os mesmos, isolados num arquivo só (`hacks.go`)

---

## 9. As variantes deste projeto

Variáveis de ambiente, não branches — convenção do `CLAUDE.md`. **Toda opção
desconhecida aborta a subida**, porque três bugs deste repositório produziram
números plausíveis em vez de erro.

| Variável | Valores | O que isola |
| - | - | - |
| `GOMAXPROCS` | `auto` (padrão, = 2 sob cota) / `1` | o piso de 2 do runtime, seção 7.1 |
| `EXTRATO_QUERY` | `unica` (padrão) / `duas` | a mesma variante que rendeu 1,25x no FastAPI |
| `SERIALIZACAO` | `manual` (padrão) / `stdlib` | `encoding/json` contra concatenação à mão, paralelo do `SERIALIZACAO` do FastAPI e do `JSON_LIB` do Elixir |
| `DB_POOL_MAX` | `8` (padrão) | teto por instância: 2 APIs × 8 + folga ≤ 20 conexões |
| `GOMEMLIMIT` | vazio (padrão) / ex. `80MiB` | armadilha nº 3: o GC contra o teto do cgroup |

`GOMAXPROCS` e `EXTRATO_QUERY` entram no slug **sempre**, e não só quando diferem
do padrão: um slug que omite o valor padrão passa a significar coisas diferentes
se o padrão mudar, com o mesmo nome de arquivo. Foi o erro que o perfil do
FastAPI teve de corrigir.

---

## 10. Perspectivas: o que este projeto abre, e o que fica para depois

O documento de fechamento (o equivalente do
[fastapi/03](../fastapi/03-o-que-a-troca-de-framework-comprou.md)) vai responder
"o que a troca de linguagem compilada comprou". Mas há perguntas que o Go traz e
que nenhuma das outras três podia trazer:

**1. O piso de 2 do `GOMAXPROCS` sob cota fracionária.** Ninguém neste
laboratório tinha um runtime que *lesse* a cota e ainda assim recusasse
dimensionar-se abaixo de 2. É a pergunta mais própria deste projeto.

**2. O fim da conversa sobre "modelo de concorrência".** As quatro stacks passam
a cobrir os quatro modelos: processos com threads bloqueantes (Gunicorn sync),
loop de eventos cooperativo (uvicorn/asyncio), processos leves preemptivos
(BEAM), e goroutines com scheduler roubador de trabalho (Go). O mesmo problema,
a mesma cota, o mesmo SQL. É o comparativo que justifica o repositório inteiro
ser um monorepo.

**3. O gargalo que já mudou de lugar.** A seção 4.5 de fastapi/03 registrou que
baratear a aplicação transfere o problema para o próximo elo, e o elixir/04
mostrou o nginx assumindo 43,3% da cota enquanto as APIs ficavam em 19%. Com uma
API compilada, **a pergunta interessante deixa de ser a aplicação**: passa a ser
se vale mover cota do banco e das APIs para o load balancer — e aí `E1` do
[plano](../../03-plano-implementacao.md) (nginx vs. HAProxy) deixa de ser
curiosidade e vira o experimento óbvio.

**4. O bloco B, que continua não feito.** A maior lacuna do plano é que
`UPDATE ... RETURNING` **nunca foi comparado** com `SELECT FOR UPDATE`,
`advisory lock` ou versão otimista. É uma pergunta de banco, não de linguagem — e
o Go, sendo a implementação mais barata do lado da aplicação, é a melhor bancada
possível para ela: quanto menos a aplicação custa, mais limpo fica o custo da
estratégia de concorrência.

O que **não** está no horizonte, e por quê: Rust (`D4` do plano) mediria de novo
"compilado sem VM", que é o que este projeto passa a cobrir; e frameworks Go
(Fiber, Echo) só entram como variante depois que a stdlib tiver número.

---

## 11. Ordem de trabalho

1. ~~**Aplicação e testes**, sem medir nada.~~ **FEITO** — `go/` com `main.go`, `config.go`
   (opção desconhecida aborta), `db.go` (pool + verificação da carga inicial),
   `dominio.go` (SQL idêntico), `hacks.go`, `router.go`, `preparar_bench.go`,
   `Dockerfile` multi-stage, `docker-entrypoint.sh`. Testes cobrindo o mínimo da
   seção 6 de fastapi/03: 25 débitos simultâneos → saldo exatamente −25; 100
   débitos contra limite 80.000; read-your-writes; os payloads inválidos; e a
   prova de que `EXTRATO_QUERY=unica|duas` produzem bytes idênticos.
2. ~~**Ferramental**~~ **FEITO**: composes (produção, bancada, sem-limite, diagnóstico),
   `scripts/perfis/go.sh`, receitas no `justfile`, `just check go` fechando em
   1.5 CPU / 550MB.
3. **`just diag-prepared go`** — antes de qualquer bancada. É a lição do
   elixir/04 aplicada na ordem certa.
4. **Medir**: bancada sob cota, prova oficial, e só então sem cota. Um documento
   por experimento, ressalvas antes dos números.
