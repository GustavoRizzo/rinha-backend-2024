# elixir/04 — O statement que não era reusado

Este documento fecha o achado que ficou aberto em
[`01`](./01-a-beam-sob-cota.md), seção 5.4, e **derruba a conclusão principal
dos três experimentos anteriores do projeto Elixir**.

O Elixir gastava de 1,36x a 3,97x mais CPU de Postgres que o FastAPI com SQL
idêntico. A causa não era a BEAM, nem o driver ser lento: era **uma opção de
configuração que eu supus, escrevi num comentário como se fosse fato, e não
conferi no fonte**. Corrigida, o Elixir passa a ser a implementação mais barata
das três em ambos os endpoints.

---

## 1. Ressalvas metodológicas

1. **As séries deste documento substituíram arquivos em `resultados/bench/`.**
   O slug não codifica o commit, então re-rodar a mesma configuração sobrescreve
   o JSON anterior. Os números de antes sobrevivem **apenas** no texto dos
   documentos [`01`](./01-a-beam-sob-cota.md) e
   [`03`](./03-sem-cota-varios-nucleos.md), onde estão com o commit `9674520` e
   `ad1bd39` ao lado. É uma limitação real do ferramental, registrada nas ações.
2. **As séries do Django e do FastAPI não foram re-rodadas.** Elas continuam nos
   commits em que foram medidas. O rig, a cota, o endpoint e a duração são os
   mesmos, que é o critério do projeto para comparar entre projetos — mas o
   hardware é o mesmo host num dia diferente.
3. **O diagnóstico do `pg_stat_statements` não é benchmark.** Ele roda com uma
   configuração de Postgres que nenhuma stack usa, e a extensão tem custo
   próprio. Os números de `calls` e `plans` valem como **razão**, nunca como
   vazão.
4. **Uma execução da prova oficial.** O máximo de 51ms é ótimo demais para ser
   afirmado como propriedade da stack sem repetição.

---

## 2. Ambiente e commit

| | |
| - | - |
| commit da correção | `cc193cf` |
| commit anterior (números "antes") | `9674520` (sob cota), `ad1bd39` (sem cota) |
| instrumento novo | `scripts/diag-prepared.sh`, `infra/postgres/postgresql-diag.conf` |
| prova oficial | `resultados/elixir/20260825T162834` |

---

## 3. Comandos para replicar

```bash
just diag-prepared elixir extrato      # o diagnóstico que decidiu a hipótese
just diag-prepared fastapi extrato     # o controle
just diag-prepared elixir transacoes

just bench-ex extrato 0.40             # o efeito, sob cota
just bench-ex transacoes 0.40
just run elixir                        # a prova oficial
```

---

## 4. O diagnóstico

### 4.1 `plans` contra `calls`

`pg_stat_statements` conta, para cada statement, quantas vezes ele foi
**executado** (`calls`) e quantas vezes foi **planejado** (`plans`). Se os dois
números forem iguais, o Postgres refaz o plano em toda requisição.

Endpoint `extrato`, 10 segundos de carga, banco idêntico:

| | `calls` | `plans` | ms planejando | ms executando | **% do tempo planejando** |
| - | - | - | - | - | - |
| **Elixir + Postgrex** | 9.122 | **9.122** | 1704,2 | 1035,4 | **62,2%** |
| FastAPI + asyncpg | 18.928 | **0** | 0,0 | 905,0 | **0,0%** |

`plans = calls`, exatamente. **Quase dois terços do trabalho do banco era
planejamento**, e nenhum deles aparecia como trabalho da aplicação — por isso o
custo só era visível no cgroup do Postgres, e não no da API.

Normalizando por chamada: o banco gastava **300,3 µs** por requisição do Elixir
contra **47,8 µs** por requisição do FastAPI. E o tempo de **execução** puro
(sem planejamento) era 113,5 µs contra 47,8 µs — ou seja, mesmo executando o
statement descartável saía mais caro.

### 4.2 A causa, conferida no fonte

`Postgrex.query/4` sem a opção `:cache_statement` cai neste caminho
(`deps/postgrex/lib/postgrex.ex:339`):

```elixir
query_prepare_execute(conn, %Query{name: "", statement: statement}, params, opts)
```

`name: ""` é um **statement sem nome**: o Postgres o prepara, executa e
descarta. Não há cache entre chamadas.

**O erro foi meu, e está registrado no comentário que eu escrevi em
`lib/rinha/config.ex`:**

> `prepare: :named` (padrão do Postgrex) mantém os statements preparados em
> cache por conexão: as 5 queries deste projeto são preparadas uma vez e
> reexecutadas, sem pagar parse+plan por requisição.

A primeira metade é verdade e a segunda não decorre dela. A opção `:prepare`
decide se queries preparadas por `Postgrex.prepare/4` **ganham nome**; ela não
faz `Postgrex.query/4` reusar nada. Escrevi a frase com a confiança de quem
conferiu, e não tinha conferido — exatamente o que o `CLAUDE.md` proíbe, na
regra "verificar no fonte antes de afirmar comportamento de biblioteca".

### 4.3 A correção

Um nome de cache por statement, em `lib/rinha/dominio.ex`:

```elixir
Postgrex.query!(pool, @sql_extrato_unico, [id], cache_statement: "extrato_unico")
```

Nomes **distintos** para crédito e débito: são statements diferentes, e um nome
só faria o segundo reusar o plano do primeiro — com a cláusula de limite errada,
e em silêncio.

Depois da correção, os dois endpoints marcam `plans = 0`, e o mesmo intervalo de
10 segundos do rig de diagnóstico passou de **9.122 para 30.240** chamadas no
extrato.

---

## 5. O efeito

### 5.1 Sob cota (API 0.40, banco 0.60) — o regime da competição

| | antes (`9674520`) | depois (`cc193cf`) | ganho |
| - | - | - | - |
| **leitura** — rps | 1290,7 | **2610,4** | **2,02x** |
| CPU da API | 246,7 µs | **157,9 µs** | 1,56x |
| CPU do banco | 479,4 µs | **120,7 µs** | **3,97x** |
| amplitude | **28,8%** | **3,7%** | — |
| throttling do banco | **94,4%** | **0,0%** | — |
| **escrita** — rps | 753,3 | **892,9** | 1,19x |
| CPU da API | 548,5 µs | **462,5 µs** | 1,19x |
| CPU do banco | 659,1 µs | **484,7 µs** | 1,36x |

Dois detalhes que confirmam o mecanismo, e não só o resultado:

- **A amplitude de 28,8% desapareceu.** Ela estava nas ações do experimento 01
  como "mecanismo a encontrar, não ruído a mediar". Era o planejamento variando
  entre repetições. A regra do projeto se pagou.
- **O gargalo da leitura voltou para a API.** O banco saía de 94,4% de períodos
  congelados para **0,0%**: aquele "o gargalo migrou para o Postgres" do
  experimento 01 não era uma propriedade da stack, era o sintoma do bug.

### 5.2 A comparação entre as três, refeita

Mesmo rig, mesma cota, mesmo endpoint. **Escrita:**

| | CPU da API | CPU do banco | rps |
| - | - | - | - |
| Django + Gunicorn + psycopg | 862,4 µs | — | 483,9 |
| FastAPI + uvicorn + asyncpg | 498,9 µs | 485,2 µs | 826,0 |
| **Elixir + Bandit + Postgrex** | **462,5 µs** | **484,7 µs** | **892,9** |

**O custo de banco ficou idêntico: 484,7 contra 485,2 µs.** É o que se espera de
dois drivers executando o mesmo SQL preparado no mesmo Postgres — e é a
confirmação mais limpa de que o excesso era o planejamento, e nada mais.

**Leitura** (CPU da API, que é onde está o gargalo dos dois):

| | CPU da API | rps |
| - | - | - |
| Django (ORM) | 1257,9 µs | 334,9 |
| FastAPI | 256,1 µs | 1601,9 |
| **Elixir** | **157,9 µs** | **2610,4** |

O Elixir passa a ser **1,08x mais barato que o FastAPI na escrita e 1,62x na
leitura** — e 1,86x / 7,97x mais barato que o Django.

### 5.3 Sem cota, em 20 núcleos — o estudo do documento 03, refeito

| braço | endpoint | rps antes | rps depois | FastAPI | **Elixir vs FastAPI** |
| - | - | - | - | - | - |
| A (1 processo) | escrita | 1955,0 | **2827,5** | 2204,8 | **1,28x** |
| A (1 processo) | leitura | 9383,5 | **18294,7** | 4546,5 | **4,02x** |
| B (máquina inteira) | escrita | 1743,0 | **2595,9** | 2245,3 | **1,16x** |
| B (máquina inteira) | leitura | 11756,1 | **19379,9** | 13710,4 | **1,41x** |

**A inversão do braço B sumiu.** O documento 03 concluía que "dando processos ao
Python a vantagem inverte"; com o statement reusado, o Elixir ganha nos
**quatro** cenários, incluindo a escrita sob contenção de linha única.

E a amplitude de 45,2% da leitura do braço B — a ressalva que aquele documento
não conseguiu eliminar — caiu para **5,5%**. Mesmo mecanismo, mesma cura.

### 5.4 Prova oficial

`resultados/elixir/20260825T162834`, commit `cc193cf`.

| | Django | FastAPI | Elixir antes | **Elixir agora** |
| - | - | - | - | - |
| pontuação | 100.000 | 100.000 | 100.000 | **100.000** |
| p50 | — | — | 2 ms | **1 ms** |
| p98 | 7 ms | 5 ms | 5–6 ms | **5 ms** |
| **máximo** | 76–94 ms | 246 ms | 91–101 ms | **51 ms** |
| subida | ~20 s | 7 s | 4–7 s | 7 s |

Consumo por serviço na carga real, com o instrumento de
[`02`](./02-ocioso-na-carga-real.md):

| serviço | µs/req antes | **µs/req agora** | % da cota |
| - | - | - | - |
| api01 | 360,2 | **297,3** | 19,0% |
| api02 | 363,0 | **300,8** | 19,2% |
| **db** | 485,1 | **316,8** | **13,4%** |
| nginx | 162,1 | 168,4 | 43,3% |

A stack inteira passou a usar ~17% do orçamento de 1.5 CPU, e o nginx — que não
mudou — é agora, com folga, o serviço proporcionalmente mais carregado.

---

## 6. Conclusões

### 6.1 A conclusão do experimento 01 estava medindo um bug meu

O documento 01 concluiu que "para este trabalho, o custo por requisição de
CPython com uvloop e asyncpg é menor que o de Elixir com Bandit e Postgrex", e
depois, na correção, que "a BEAM está competitiva; o que está caro é o que o
Postgrex faz o Postgres trabalhar".

**As duas estão erradas, e a segunda menos.** O Postgrex não faz o Postgres
trabalhar mais; **a minha chamada** fazia. Com uma opção de uma linha, o custo
de banco das duas implementações fica indistinguível e o Elixir passa a ser o
mais barato dos três em ambos os endpoints.

A previsão original de `django/06`, seção 8 — *150 a 400 µs por requisição* —
que o experimento 01 declarou errada por excesso (548,5 µs), fica **certa na
leitura** (157,9 µs) e ainda um pouco alta na escrita (462,5 µs). Ela era mais
acertada do que o meu erro deixou parecer.

### 6.2 O que o "throttling do banco" estava dizendo, e o que eu li nele

O experimento 01 viu o banco congelado em 94,4% na leitura e concluiu que *"pela
primeira vez neste laboratório o Postgres é o gargalo"*, ligando isso à previsão
de [`fastapi/03`](../fastapi/03-o-que-a-troca-de-framework-comprou.md) de que a
troca de linguagem moveria o gargalo para o banco.

A previsão pode até vir a se confirmar um dia, mas **não foi isso que aconteceu
ali**. O banco estava saturado porque estava fazendo trabalho desnecessário. O
laboratório já tinha essa regra escrita — *throttling alto não prova gargalo* —
e eu a apliquei ao nginx no `fastapi/02` e deixei de aplicar ao Postgres aqui.

### 6.3 O diagnóstico custou menos que a especulação

Entre o achado ser registrado e ser resolvido, houve dois documentos e nove
séries de bancada apoiadas numa conclusão errada. O `pg_stat_statements` levou
**dois comandos e cinco minutos**, e deu uma resposta binária.

Não era falta de instrumento: era a ordem em que eu escolhi usá-lo. A hipótese
estava escrita desde o experimento 01, com o método correto ao lado
(*"`pg_stat_statements` comparando `plans` com `calls`"*), e eu segui medindo
outras coisas antes.

---

## 7. Ações decorrentes

- [x] `cache_statement` em todas as queries do caminho quente, com nomes
      distintos por statement.
- [x] Instrumento permanente: `just diag-prepared <projeto> [endpoint]`.
- [x] Séries do Elixir refeitas, sob cota e sem cota, e prova oficial repetida.
- [x] Documentos 01, 02 e 03 marcados com o aviso de que seus números são
      anteriores à correção.
- [ ] **O slug das séries não codifica o commit**, e re-rodar sobrescreve o JSON
      anterior (ressalva 1). Ou o slug passa a incluir o hash, ou
      `bench-tabela.py` precisa avisar quando duas linhas comparadas vêm de
      commits diferentes de forma mais visível que hoje.
- [ ] Rodar `just diag-prepared django` — o Django usa psycopg com SQL cru, e
      ninguém conferiu se ele reusa statements. Se não reusar, parte dos 862 µs
      da escrita e dos 1258 µs da leitura é o mesmo problema.
- [ ] Repetir a prova oficial mais duas vezes: o máximo de 51ms é bom demais
      para ser afirmado sem repetição.

---

## 8. Aprendizados transversais

- **Um comentário de código com um número dentro não é uma medição.** O
  comentário errado de `config.ex` descrevia um comportamento plausível, citava
  a opção certa e concluía o oposto do que ela faz. Ele sobreviveu a três
  experimentos porque *parecia* verificado.
- **Custo que não aparece no seu processo ainda é seu.** O trabalho extra estava
  no cgroup do Postgres, e a aplicação parecia inocente em toda tabela que
  olhasse só a API. Foi separar os cgroups que apontou o dedo para o lugar
  certo — e ainda assim para o componente errado (o driver, não a chamada).
- **Quando a hipótese vier com o método ao lado, execute o método.** O custo de
  decidir foi cinco minutos; o custo de adiar foram dois documentos com a
  conclusão invertida.
