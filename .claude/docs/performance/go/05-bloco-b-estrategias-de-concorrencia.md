# go/05 — Bloco B: as quatro estratégias de concorrência, finalmente medidas

Este experimento fecha a **maior lacuna do projeto**, aberta no
[plano](../../03-plano-implementacao.md) antes da primeira linha de código:

> A implementação usa o `UPDATE` atômico condicional e ele entregou zero
> inconsistências em 553.527 requisições — mas **nunca foi comparado** com
> `SELECT FOR UPDATE`. A hipótese de que vence "por larga margem" continua sendo
> hipótese.

Vence. **Mas por 9% a 15%, não por larga margem** — e a "larga margem" existe
contra uma estratégia só, a otimista, que colapsa em 3,6x.

---

## 1. Ressalvas metodológicas

1. **A bancada escreve sempre no MESMO cliente.** É o pior caso possível de
   contenção — 50 requisições concorrentes disputando uma linha — e é
   deliberado: é o regime em que estratégias de concorrência se distinguem. A
   carga real da Rinha espalha por 5 clientes, então **todos os fatores aqui são
   tetos superiores da diferença**, não o que a competição veria.
2. **Uma linguagem só.** As quatro estratégias foram medidas em Go, e o custo
   relativo delas pode não se transferir para stacks cuja aplicação é 3x mais
   cara — num Django de 862 µs por requisição, 40 µs de diferença entre
   estratégias somem no ruído.
3. **A série do braço B2 do commit anterior foi perdida.** O bloco de
   arquivamento que este mesmo dia introduziu tinha um caminho errado e não
   arquivava nada, em silêncio (seção 6.4). O número antigo (1342,3 rps,
   `1e9f7e6`) sobrevive no texto de [`01`](./01-a-aplicacao-sai-da-frente.md) e
   [`03`](./03-quatro-stacks-quatro-linguagens.md).
4. **B2 medido hoje deu 1256,5 rps contra 1342,3 de três dias atrás** — 6,4% de
   diferença entre dias, na mesma configuração. É a mesma ordem de variação que
   [`django/07`](../django/07-o-django-tambem-nao-reusava.md) registrou (3,7%), e
   é o motivo de as comparações **dentro** desta tabela valerem e as comparações
   com outros documentos precisarem de cuidado.
5. **Só escrita.** As estratégias só afetam `POST /transacoes`; o extrato é o
   mesmo código nas quatro.

---

## 2. Ambiente e commit

| | |
| - | - |
| commit | `a3be216` |
| implementação | `go/concorrencia.go` |
| rig | `go/compose.bench-postgres.yml`, API 0.40 CPU, banco 0.60 |
| ferramenta | `oha` 1.15.0, 10s, concorrência 50, 5 repetições, aquecimento descartado |

---

## 3. Comandos para replicar

```bash
just go-test -run TodasAsEstrategias   # as quatro passam a suíte de concorrência
for est in update-returning select-for-update advisory-lock otimista; do
  ESTRATEGIA=$est BENCH_PROJETO=go BENCH_ENDPOINT=transacoes \
    bash scripts/bench-stack.sh postgres 0.40 1 10s 5
done
```

---

## 4. As quatro implementações

| # | `ESTRATEGIA` | como resolve a corrida | round-trips |
| - | - | - | - |
| B1 | `select-for-update` | trava a linha, lê, decide na aplicação, grava | 3 + commit |
| B2 | `update-returning` | um `UPDATE` com a condição de limite no `WHERE` | 2 + commit |
| B3 | `advisory-lock` | `pg_advisory_xact_lock(id)`, lê, decide, grava | 4 + commit |
| B4 | `otimista` | lê **sem travar**, `UPDATE ... WHERE saldo = <lido>`, repete se falhar | 2 + commit, **× tentativas** |

Duas decisões de implementação que mudam a leitura:

**A otimista faz CAS sobre o próprio saldo, não sobre coluna de versão.** O
plano previa "coluna de versão + retry", mas acrescentar coluna mudaria
`infra/sql/ddl.sql` — compartilhado pelas quatro stacks — e a comparação entre
linguagens passaria a ter schemas diferentes. O efeito é equivalente; a única
perda é o problema ABA, inofensivo aqui porque o saldo *é* o valor, e dois
créditos e um débito que o devolvem ao número original produzem o mesmo estado.

**As quatro passam os três testes de concorrência**, contra as mesmas asserções:
25 débitos simultâneos → saldo exatamente −25; 100 débitos contra limite 80.000 →
exatamente 80 aceitos; toda transação confirmada com lastro no extrato. Isso é o
que autoriza compará-las — *uma estratégia que perde escritas é mais rápida por
não fazer o trabalho, e o número dela seria mentira*.

---

## 5. Os números

Escrita, todas as requisições no **mesmo cliente**, API 0.40 CPU / banco 0.60:

| estratégia | rps | vs. B2 | amplitude | CPU da API | **API congelada** | CPU do banco | **banco congelado** | p99 |
| - | - | - | - | - | - | - | - | - |
| **B2 `update-returning`** | **1256,5** | — | 4,6% | **322,0 µs** | 76,4% | 494,7 µs | **93,5%** | 99,6 ms |
| B1 `select-for-update` | 1137,5 | **0,91x** | 0,9% | 361,1 µs | 93,4% | 455,7 µs | 9,3% | 172,2 ms |
| B3 `advisory-lock` | 1072,7 | **0,85x** | 7,6% | 382,3 µs | 94,3% | **299,4 µs** | 0,9% | **85,4 ms** |
| B4 `otimista` | 351,7 | **0,28x** | 4,9% | **1169,4 µs** | 88,7% | **1773,7 µs** | 88,0% | 291,2 ms |

---

## 6. Conclusões

### 6.1 A hipótese de 2026-08-20 estava certa na direção e errada no tamanho

*"Espero que B2 vença por larga margem."* Vence — e a margem sobre os dois locks
pessimistas é de **9% e 15%**, com amplitudes de 0,9% a 7,6%. É real, é
atribuível, e é **muito menor do que "larga margem"** sugere.

Onde a margem é larga é contra a otimista: **3,57x**.

A explicação do tamanho modesto está nos round-trips: B2 economiza **um**
round-trip contra B1 e **dois** contra B3, e sob esta cota cada round-trip vale
cerca de 20 a 30 µs de CPU da aplicação. O ganho de B2 não é mágico — é
aritmética de ida e volta ao banco.

### 6.2 O mais interessante da tabela: B2 tem o banco saturado e ainda ganha

Repare no par de colunas de throttling:

| | API congelada | banco congelado |
| - | - | - |
| B2 | 76,4% | **93,5%** |
| B1 | 93,4% | 9,3% |
| B3 | 94,3% | **0,9%** |

**B2 é a única em que o gargalo está no banco.** As duas com lock explícito
deixam o Postgres quase ocioso — e mesmo assim entregam menos, porque a
aplicação passa o tempo **esperando** o lock, e esperar não aparece como CPU em
lugar nenhum.

É a leitura que o `CLAUDE.md` já exigia (*"olhar `nr_throttled` por serviço antes
de culpar a aplicação"*) chegando a uma conclusão contraintuitiva: **o braço com
o recurso mais saturado é o melhor**. Saturar o banco aqui significa usá-lo, não
sofrer com ele.

### 6.3 O advisory lock é o mais barato para o banco e o segundo pior no total

299,4 µs de CPU de banco contra 494,7 de B2 — **1,65x mais barato**, fazendo
*mais* statements (quatro contra dois). O mecanismo provável, e é hipótese, não
medição: a serialização total elimina o trabalho concorrente desperdiçado no
Postgres — conflitos de lock de linha, retentativas internas, contenção de
buffer. O banco faz menos porque não faz nada ao mesmo tempo.

E é exatamente por isso que ele perde: o que ele economiza no banco, paga em
espera na aplicação (94,3% de API congelada, a maior das quatro).

**Se o banco fosse o recurso escasso da stack, esta linha mudaria de posição.**
Vale registrar como pergunta aberta, com o método ao lado: repetir a tabela com
o banco em 0.30 CPU e a API em 0.70.

### 6.4 A otimista colapsa, e o motivo é o desenho da bancada

0,28x, com CPU de banco **3,6x maior** que B2 e API **3,6x mais cara**. Cada
falha de CAS descarta uma leitura, uma transação aberta e um `UPDATE` — trabalho
inteiro jogado fora — e sob 50 requisições concorrentes na mesma linha a taxa de
falha é altíssima por construção.

**Isto não é um veredito sobre concorrência otimista.** É o veredito sobre
concorrência otimista *no pior caso possível para ela*: contenção máxima numa
única linha. Numa carga espalhada por muitas linhas — que é onde a estratégia é
normalmente recomendada — a conta seria outra, e este experimento **não a mede**.

A ressalva 1 vale para todas as linhas, mas para esta ela é a conclusão.

### 6.5 Nada disso muda a decisão do projeto

B2 já era a estratégia das quatro stacks, continua sendo, e agora **por medição
em vez de hipótese**. A diferença prática na competição é nula: o pico é 340
req/s espalhados por 5 clientes, e a pior das quatro estratégias entrega 351,7
rps concentrados numa linha só.

---

## 7. O bug que este experimento encontrou no próprio ferramental

O arquivamento de séries introduzido hoje (para resolver a perda de dados de
[`elixir/04`](../elixir/04-o-statement-que-nao-era-reusado.md) e
[`go/01`](./01-a-aplicacao-sai-da-frente.md)) procurava
`${config}-${ENDPOINT}.serie.json`. O nome real é `${config}.serie.json` — o
endpoint já está dentro de `$config`. Ele não achava nada e **não arquivava
nada, em silêncio**.

Custou a série do braço B2 no commit anterior, que era exatamente o tipo de
arquivo que ele existe para proteger.

**O guarda contra falha silenciosa tinha uma falha silenciosa.** Corrigido e
**verificado re-rodando uma série e vendo o arquivo aparecer** — que é o passo
que faltou quando eu o escrevi.

---

## 8. Ações decorrentes

- [x] Bloco B fechado: as quatro estratégias implementadas, testadas contra as
      mesmas asserções e medidas.
- [x] Arquivamento de séries corrigido e verificado.
- [ ] **Repetir com o banco escasso** (banco 0.30, API 0.70): a seção 6.3 prevê
      que o advisory-lock melhore de posição, e a previsão está registrada antes
      da medição.
- [ ] Medir a otimista com a carga **espalhada** entre os 5 clientes. Hoje a
      bancada bate sempre no cliente 1, e é o pior caso possível para ela.
- [ ] As estratégias existem só no Go. Portá-las ao FastAPI diria se os fatores
      se mantêm quando a aplicação é 1,65x mais cara.
