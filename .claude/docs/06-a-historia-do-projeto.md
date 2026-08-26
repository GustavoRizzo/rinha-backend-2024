# 06 — A história do projeto, em ordem

Os documentos de experimento são precisos e fragmentados: cada um responde uma
pergunta e registra as ressalvas dela. Este aqui é o oposto — conta a **história
inteira em ordem cronológica**, com os erros no lugar em que aconteceram, para
quem quer entender o percurso e não consultar um número.

É também o documento que resume o que este laboratório descobriu que vale além
da Rinha.

---

## O exercício

A [Rinha de Backend 2024/Q1](https://github.com/zanfranceschi/rinha-de-backend-2024-q1)
foi uma competição brasileira encerrada em março de 2024. As regras: uma API de
créditos e débitos com dois endpoints, um load balancer e duas instâncias de
aplicação e um banco de dados, tudo somando **1,5 CPU e 550MB de memória**. Uma
simulação de 4 minutos aplica 61.503 requisições com pico de ~340 por segundo, e
cobra multa por lentidão e por inconsistência de saldo.

A competição acabou. Este repositório usa as regras dela como **especificação de
um exercício** sobre teste de carga, concorrência e limitação de recursos — e a
regra que atravessa tudo é uma só: **medir antes de afirmar**.

O detalhe que faz o problema ser difícil: existem **cinco clientes**. Toda a
carga bate em cinco linhas do banco. A dificuldade não é vazão — é manter
correção absoluta sob contenção máxima.

---

## Ato 1 — Django, e as três primeiras afirmações erradas

A primeira implementação foi Django com Gunicorn e Postgres. Seis experimentos,
e o valor deles não está nos números: está em três frases que eu escrevi com
confiança e que a medição derrubou.

**"`DEBUG=True` vaza memória sob WSGI."** Falso. `reset_queries` está ligado ao
sinal `request_started` (`django/db/__init__.py:52`), então a lista de queries
zera a cada requisição. O vazamento só existe fora do ciclo de request.

**"O Gunicorn ganha do `runserver` por causa de keep-alive."** Falso: o
`runserver` também fala HTTP/1.1. A causa real é contenção de GIL, porque ele
cria uma thread por conexão sem limite — e isso produz **escalabilidade
negativa**: 646 requisições por segundo com uma conexão, 223 com cinquenta.

**"Com Postgres, mais workers vão ajudar por causa da espera de I/O."** O
oposto: com `synchronous_commit = off`, a escrita virou CPU-bound e quatro
workers perderam 28% para um. Quem precisava de mais workers era o SQLite.

Foi aqui que nasceu a seção **"Erros cometidos"** do diário — mantida de
propósito, porque erro custa caro e é a parte que menos aparece em relatório
técnico.

Dois achados que sobreviveram a tudo o que veio depois: **conexão persistente
vale 4,75x** (o padrão do Django abre uma conexão nova por requisição, e cada
conexão no Postgres é um processo do sistema operacional), e **acrescentar um
salto de rede deixou o sistema mais rápido** — o nginx na frente, falando por
socket Unix, rendeu 2,9x, porque a API parou de fazer trabalho de rede.

E a lição de instrumentação: a pontuação da competição **satura**. Com p98 de
7ms contra um SLA de 250ms, toda configuração competente tira nota máxima. A
partir dali o projeto passou a usar duas ferramentas com papéis separados —
`oha` para **comparar** em 10 segundos, Gatling para **aprovar** em 4 minutos —
e nunca comparar números entre as duas.

---

## Ato 2 — FastAPI, e a conclusão mais desconfortável

A segunda implementação trocou o framework dentro da mesma linguagem: FastAPI,
uvicorn, asyncpg. A previsão dizia 1,73x na escrita. Acertou. Na leitura, previa
o mesmo e mediu **4,00x**.

E aí veio a parte incômoda: **os 4,00x não são do framework**. A troca mexeu em
três coisas ao mesmo tempo — framework, driver e, no extrato, ORM por SQL cru. O
extrato do Django instanciava **onze objetos de modelo por requisição**; o do
FastAPI, nenhum. A evidência está na própria assimetria: onde as duas stacks já
usavam SQL cru, o ganho foi 1,73x; onde só uma usava, foi 4,00x.

> **O número que este projeto pode defender como ganho de framework é o 1,73x. O
> resto era ORM no caminho quente — e o Django também poderia tê-lo tirado.**

O segundo experimento do FastAPI produziu a regra mais útil do repositório
inteiro. Uma redistribuição de cota que rendia **1,54x na bancada** entregou
**cauda pior** na prova oficial, com 24 requisições acima do SLA — o mesmo
número nas duas execuções, o que aponta causa sistemática, não dispersão.

> **Otimização medida em saturação não se transfere para a carga real. Se o
> sistema não satura no uso previsto, a folga não é desperdício: é o amortecedor
> da cauda.**

E um erro de diagnóstico que virou regra: eu vi o nginx congelado em 87–93% dos
períodos e afirmei que o gargalo tinha migrado para ele. Soltar a cota dele
rendeu 2,6% — ruído. **Throttling alto diz que um serviço satura a própria cota,
não que ele seja o limite do sistema.** A prova é operacional: solte a cota e
veja se a vazão sobe.

---

## Ato 3 — Elixir, e o erro que custou três experimentos

A terceira implementação saiu do Python: Elixir, Bandit, Postgrex. Duas
armadilhas estavam previstas para a BEAM sob cgroup, e **nenhuma das duas
existia**: o OTP 27 lê a cota do cgroup e se dimensiona sozinho.

O que existia era outra coisa, e eu levei três experimentos para encontrar.

O Elixir gastava de 1,36x a 3,97x mais CPU **de banco** que o FastAPI, com SQL
idêntico. Eu concluí que a BEAM era mais cara. Depois corrigi para "o Postgrex
faz o Postgres trabalhar mais". As duas conclusões estavam erradas.

A causa estava num comentário que eu mesmo tinha escrito em `config.ex`:

> `prepare: :named` (padrão do Postgrex) mantém os statements preparados em
> cache por conexão.

A primeira metade é verdade e a segunda não decorre dela. `Postgrex.query/4` sem
`cache_statement` monta um statement **sem nome**, que o Postgres prepara,
executa e descarta. O diagnóstico levou **dois comandos e cinco minutos**:
`pg_stat_statements` comparando `plans` com `calls`.

**9.122 planos para 9.122 chamadas. 62,2% do tempo de banco era planejamento.**

Corrigido com uma opção de uma linha, o Elixir virou a implementação mais barata
das três, o throttling do banco caiu de 94,4% para 0,0%, e uma amplitude de
28,8% entre repetições — que eu vinha tratando como ruído — desapareceu.

Três lições ficaram:

- **Um comentário de código com um número dentro não é uma medição.** Aquele
  comentário sobreviveu a três experimentos porque *parecia* verificado.
- **Custo que não aparece no seu processo ainda é seu.** O trabalho extra estava
  no cgroup do Postgres, e a aplicação parecia inocente em toda tabela que
  olhasse só a API.
- **Quando a hipótese vier com o método ao lado, execute o método.** A hipótese
  certa estava escrita desde o primeiro experimento, com a ferramenta indicada
  ao lado, e eu segui medindo outras coisas antes.

---

## Ato 4 — Go, e a aplicação que sai da frente

A quarta implementação foi Go 1.27 com a biblioteca padrão e `pgx`. Sem
framework web, sem ORM — o par honesto das outras três.

Duas armadilhas previstas morreram antes da primeira medição. A previsão dizia
que um Go ingênuo subiria vinte threads disputando 0,40 de CPU; o **Go 1.27 lê a
cota do cgroup** (`runtime/cgroup_linux.go:85-92`) e sobe duas. É a segunda vez
que uma armadilha de runtime é neutralizada por evolução do runtime — a primeira
foi a da BEAM.

> **Verificar a versão do runtime é parte da metodologia.** Uma armadilha real
> pode já ter sido resolvida na versão que está rodando. O que continua
> verdadeiro: `runtime.NumCPU()` ainda devolve 20 dentro de um container com
> 0,40 CPU, e qualquer código que se dimensione por ele continua caindo nela.

O resultado: **a stack mais barata das quatro**, 323 µs por escrita e 105 µs por
leitura, contra 856 e 1224 do Django. E a primeira em que **a aplicação sai da
frente**: sob a cota da competição, quem satura é o Postgres, com a API em 0,9%
na leitura. Baratear a aplicação não eliminou o gargalo — transferiu-o, como o
documento de fechamento do FastAPI tinha previsto.

Um erro meu aqui também, e este durou pouco porque a medição foi barata. A
primeira execução da prova oficial deu 98,57% dentro do SLA e eu escrevi que o Go
tinha "a pior cauda das quatro". Era a **primeira execução daquela stack na
máquina** — a rodada de aquecimento que a metodologia do projeto manda
descartar, e que eu descarto religiosamente na bancada e não descartei na prova
oficial, porque ela custa quatro minutos e convida a rodar uma vez só. Três
execuções depois: 100%, 100%, com p98 de **4ms** — o melhor das quatro.

---

## O epílogo — as quatro perguntas que ficaram respondidas

### Qual linguagem é mais rápida?

Sob a cota da competição, por CPU por requisição:

| | escrita | leitura |
| - | - | - |
| Django + Gunicorn + psycopg | 856 µs | 1224 µs |
| FastAPI + uvicorn + asyncpg | 512 µs | 257 µs |
| Elixir + Bandit + Postgrex | 444 µs | 158 µs |
| **Go + net/http + pgx** | **323 µs** | **105 µs** |

Sem cota nenhuma, em 20 núcleos, a distância cresce: o Go entrega 21.737
leituras por segundo contra 768 do Django — **28x**.

**E nada disso muda a nota.** As quatro marcam USD 100.000 com 100% das
requisições dentro do SLA. O pico da competição é 340 requisições por segundo, e
a mais lenta das quatro já entrega 486 com uma única instância sob 0,40 de CPU.
Toda a vantagem medida é folga que o teste nunca pede.

### Qual estratégia de concorrência é a certa?

A pergunta ficou aberta desde o primeiro dia, sustentada por uma hipótese:
*"espero que o `UPDATE` atômico vença por larga margem"*. Medida sob contenção
máxima, com as quatro estratégias passando os mesmos testes de correção:

| estratégia | vazão relativa |
| - | - |
| `UPDATE ... WHERE ... RETURNING` | 1,00 |
| `SELECT ... FOR UPDATE` | 0,91 |
| `pg_advisory_xact_lock` | 0,85 |
| otimista (compare-and-swap com retry) | **0,28** |

**Certa na direção, errada no tamanho**: 9% a 15% sobre os locks pessimistas, e
não "larga margem". A margem larga existe contra a otimista — e no pior caso
possível para ela, com todas as requisições disputando uma linha só.

O detalhe contraintuitivo: o `UPDATE` atômico é a **única** estratégia em que o
banco está saturado, e ganha assim. As com lock explícito deixam o Postgres
ocioso e perdem, porque a aplicação passa o tempo **esperando** — e esperar não
aparece como CPU em lugar nenhum.

### Linguagem que ajuda mais o programador é pior em desempenho?

| | linhas de código | CPU/req |
| - | - | - |
| Django | **289** | 856 µs |
| FastAPI | 318 | 512 µs |
| Elixir | 442 | 444 µs |
| Go | **688** | **323 µs** |

**A correlação aparece nas pontas e some no meio.** O FastAPI escreve menos que
o Elixir *e* é quase tão rápido. Três razões para não levar a régua a sério: o
Django é pequeno por ser *Django*, não por ser Python — o ORM existe, custa CPU e
foi escrito por outra pessoa; **156 das 688 linhas do Go, 23%, são blocos
`if erro != nil`**, cerimônia e não complexidade; e o que custa CPU não é o que
custa linha — as quarenta linhas de serialização manual do Go compraram 1,4% de
desempenho, dentro do ruído.

> **Não é a linguagem que ajuda o programador que custa desempenho — é a
> abstração que ele não escreveu.**

### O que vale além da Rinha?

As regras que este laboratório derivou, cada uma paga com um erro:

1. **Medir antes de afirmar.** Cinco afirmações minhas foram derrubadas por
   medição, e três delas estavam em comentários de código.
2. **Registrar a hipótese antes de medir**, para o placar ficar honesto.
3. **Descartar a rodada de aquecimento** — e isso vale para a medição cara
   também, não só para a barata.
4. **Amplitude alta não é ruído a mediar: é mecanismo pedindo para ser
   encontrado.** Duas vezes ela apontou um bug real.
5. **Throttling alto diz que um serviço satura a própria cota, não que ele seja
   o limite do sistema.** A prova é operacional.
6. **O valor de uma correção é a escassez do recurso que ela libera**, não o
   tamanho do desperdício que elimina. O mesmo defeito rendeu 2,02x numa stack e
   1,01x em outra.
7. **Otimização medida em saturação não se transfere para a carga real.**
8. **Todo instrumento de medição deve abortar quando não reconhecer o que está
   lendo.** Quatro bugs deste repositório produziram números plausíveis em vez
   de erro — e um deles estava no próprio guarda contra números plausíveis.

---

## Como ler o resto da documentação

| Se você quer | Leia |
| - | - |
| a teoria (open model, percentis, cgroups, concorrência) | [01 — Fundamentos](./01-fundamentos.md) |
| o contrato e as regras da competição | [02 — Regras](./02-regras.md) |
| o diário técnico, com os erros | [04 — Aprendizados](./04-aprendizados.md) |
| os atalhos que só existem por ser competição | [05 — Hacks](./05-hacks-da-competicao.md) |
| um experimento específico | [performance/](./performance/00-indice.md) |
| a comparação final das quatro stacks | [go/03](./performance/go/03-quatro-stacks-quatro-linguagens.md) e [go/04](./performance/go/04-sem-cota.md) |
