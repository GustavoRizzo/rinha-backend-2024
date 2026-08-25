# elixir/01 — A BEAM sob cota de cgroup

Primeiro experimento do projeto Elixir, e o primeiro do laboratório fora do
Python. Mede o custo de CPU por requisição da stack Elixir + Bandit + Postgrex
contra as duas implementações já medidas, e testa as **duas armadilhas da BEAM**
registradas em [`00-indice.md`](./00-indice.md), seção 3.

Resposta curta: as duas armadilhas **não aparecem sob cota**, o Elixir ficou
**mais caro que o FastAPI** ao contrário do previsto, e apareceu um mecanismo
não previsto — a leitura com query única sai **limitada pelo banco**, gastando
2,7x mais CPU de Postgres que o FastAPI para o SQL idêntico.

---

## 1. Ressalvas metodológicas

Antes de qualquer número, o que este teste **não** mede.

1. **Não é "Elixir vs. Python" puro.** Mudam linguagem, máquina virtual,
   servidor HTTP e driver de banco de uma vez — quatro variáveis num salto. É a
   mesma limitação que [`fastapi/03`, seção 4.1](../fastapi/03-o-que-a-troca-de-framework-comprou.md)
   identificou na comparação Django↔FastAPI, e ela foi **prevista** para este
   experimento (previsão nº 5 do índice). O número mais honesto é o do endpoint
   em que as duas implementações usam a mesma técnica de acesso a dados e o
   mesmo gargalo — aqui, a **escrita** e a **leitura em duas queries**.
2. **A comparação da leitura com query única não vale como medida de
   aplicação.** Nesse braço o Elixir tem a API praticamente ociosa e o banco
   saturado: o número descreve o teto do Postgres a 0.60 CPU, não o custo da
   aplicação. A seção 5.4 trata disso como achado, não como comparação.
3. **A pontuação satura.** As três implementações marcam USD 100.000 com 40x a
   50x de folga contra o SLA. Nada aqui melhora nota.
4. **Uma máquina, um dia, um sistema operacional.** 20 vCPU sob WSL2, com o
   gerador de carga dividindo a máquina com a stack. O ambiente oficial tinha 4
   vCPU. **Estes números não se comparam com o ranking oficial** — servem para
   comparar variantes entre si.
5. **A série `sem-limite` está fora do regulamento de propósito.** Serve para
   responder "quanto a cota está custando", e nada mais.
6. **Amplitude alta num braço.** A leitura com query única variou 28,8% entre
   repetições. Pela regra do projeto, isso não é ruído a mediar: é mecanismo a
   encontrar, e está registrado nas ações.

---

## 2. Ambiente e commit

| | |
| - | - |
| commit medido | `9674520` (árvore limpa em todas as séries do Elixir) |
| host | 20 vCPU, WSL2, kernel 6.6.87.2-microsoft-standard-WSL2 |
| Docker | Engine 29.6.2 |
| Elixir / OTP | 1.18.4 / 27.3.4, Alpine 3.21 |
| bibliotecas | bandit 1.12.5, plug 1.20.3, postgrex 0.22.4, jason 1.4.5 |
| Postgres | 18-alpine, `infra/postgres/postgresql.conf` |
| bancada | `oha` 1.15.0, 10s, concorrência 50, **5 repetições + aquecimento descartado** |
| prova oficial | Gatling 3.15.1, simulação oficial intacta |
| rig | `postgres`: nginx + **1** API + banco, API em 0.40 CPU, banco em 0.60 |

O rig, a cota, o endpoint e a duração são os mesmos das séries de
[`django/06`](../django/06-tipos-de-worker.md) e
[`fastapi/01`](../fastapi/01-fastapi-async.md) — é isso que autoriza comparar as
três colunas.

---

## 3. Comandos para replicar

```bash
just ex-test                 # 24 testes; verde é pré-requisito para medir
just bench-ex-01             # as 9 séries desta página
just bench-tabela            # a tabela comparativa com os outros projetos

just check elixir            # 1.50 CPU / 550MB
just run elixir              # up + smoke + Gatling + down
just score elixir/<timestamp>
```

---

## 4. Números crus

### 4.1 Escrita (`POST /clientes/:id/transacoes`), API em 0.40 CPU

Os quatro braços do teste das armadilhas. A métrica é **µs de CPU por
requisição**; sob cota, vazão é consequência (cota ÷ custo).

| `SCHEDULERS` | `BUSY_WAIT` | rps | **µs/req** | ampl% | thr% API | µs/req banco | thr% banco | p99 ms |
| - | - | - | - | - | - | - | - | - |
| 1 (padrão) | none (padrão) | 753,3 | **548,5** | 6,9 | 94,3 | 659,1 | 5,6 | 107,6 |
| 1 | default | 746,4 | 550,8 | 3,5 | 94,3 | 646,0 | 5,5 | 108,0 |
| auto | none | 739,3 | 560,7 | 3,3 | 95,3 | 659,8 | 5,6 | 110,4 |
| auto | default | 737,5 | 560,3 | 4,8 | 94,3 | 649,0 | 4,7 | 108,1 |

Amplitude entre o melhor e o pior braço: **2,2%**. O piso de ruído do projeto é
~3%.

### 4.2 Escrita SEM cota de CPU (fora do regulamento)

| `SCHEDULERS` | rps | **µs/req** | ampl% | µs/req banco | p99 ms |
| - | - | - | - | - | - |
| 1 | 1800,5 | **502,7** | 0,7 | 579,9 | 47,8 |
| auto (20 schedulers) | 1880,0 | **1087,8** | 4,8 | 637,6 | 47,0 |

**2,16x mais CPU por requisição para 4,4% mais vazão.**

### 4.3 Leitura (`GET /clientes/:id/extrato`), API em 0.40 CPU

| variante | rps | **µs/req** | ampl% | thr% API | µs/req banco | thr% banco | p99 ms |
| - | - | - | - | - | - | - | - |
| `EXTRATO_QUERY=unica` (padrão) | 1290,7 | **246,7** | **28,8** | **1,9** | **479,4** | **94,4** | 95,7 |
| `unica` + `JSON_LIB=otp` | 1310,2 | 247,9 | 8,9 | 0,9 | 467,5 | 93,5 | 99,8 |
| `EXTRATO_QUERY=duas` | 1052,4 | **394,6** | 1,7 | **94,3** | 329,4 | 1,9 | 88,5 |

Repare na inversão das colunas de throttling entre a primeira linha e a
terceira: são gargalos **diferentes**, e por isso as duas não se comparam
diretamente.

### 4.4 As três implementações, lado a lado

Mesmo rig, mesma cota, mesmo endpoint, mesma bancada.

| escrita | rps | **µs/req** | vs. Django |
| - | - | - | - |
| Django + Gunicorn sync + psycopg | 483,9 | 862,4 | — |
| **Elixir + Bandit + Postgrex** | 753,3 | **548,5** | **1,57x** |
| FastAPI + uvicorn + asyncpg | 822,6 | **499,7** | **1,73x** |

| leitura, duas queries | rps | **µs/req** | vs. Django |
| - | - | - | - |
| Django (ORM) | 334,9 | 1257,9 | — |
| **Elixir** | 1052,4 | **394,6** | 3,19x |
| FastAPI | 1303,1 | **314,3** | 4,00x |

### 4.5 Prova oficial (Gatling, stack completa em 1.50 CPU / 550MB)

`resultados/elixir/20260825T130143`, commit `9674520`.

| | |
| - | - |
| Pontuação | **USD 100.000** (máxima) |
| Requisições | 61.503 em 4 minutos |
| Abaixo de 250ms | **100,000%** — nenhuma exceção |
| p50 / p75 / p98 / p99 | **2ms / 3ms / 6ms / 9ms** (SLA: p98 < 250ms) |
| Máximo | **101 ms** |
| Inconsistências de saldo | **zero** |
| Requisições com falha | **zero** |
| Subida da stack | **4s** (limite: 40s) |

| | Django | FastAPI | **Elixir** |
| - | - | - | - |
| pontuação | 100.000 | 100.000 | **100.000** |
| p98 | 7 ms | 5 ms | 6 ms |
| máximo | 76–94 ms | **246 ms** | **101 ms** |
| subida | ~20s | 7s | **4s** |

---

## 5. Conclusões

### 5.1 As duas armadilhas não existem sob cota — e a previsão própria caiu

Os quatro braços da seção 4.1 cabem em 2,2%, abaixo do piso de ruído. Nem
`SCHEDULERS`, nem `BUSY_WAIT`, nem os dois juntos mudaram o custo por
requisição de forma mensurável.

A causa está na observação 7.1 do índice, feita antes de medir: **o OTP 27 lê a
cota do cgroup e dimensiona os schedulers por ela**. Sob 0.40 CPU, `auto` *é* 1.
Os dois braços "com armadilha" estavam medindo a mesma configuração que os
outros dois.

Duas previsões caem junto:

- **Previsão nº 2** (`SCHEDULERS=auto` teria cauda pior que o Django) — errada
  sob cota, pelo motivo acima. O p99 dos quatro braços difere em 2,6%.
- **Previsão nº 3** (`BUSY_WAIT=default` custaria mais que `SCHEDULERS=auto`) —
  **errada**, e era a aposta própria deste experimento, a única que não vinha
  copiada de `django/06`. Custou 0,4%: ruído.

O erro da nº 3 tem uma lição além de si mesma. O raciocínio era "spin queima
cota, e sob cgroup queimar não é de graça" — correto em tese, e irrelevante na
prática porque **com 1 scheduler não há para quem esperar**: o busy-wait só tem
o que desperdiçar quando existem vários schedulers ociosos, e a própria BEAM já
tinha eliminado isso ao ler a cota.

### 5.2 A armadilha é real — onde não há cota para ler

Sem limite de CPU, `SCHEDULERS=auto` custa **2,16x** mais CPU por requisição e
entrega 4,4% mais vazão (seção 4.2). Vinte schedulers disputando o mesmo
trabalho gastam mais do que fazem.

Ou seja: o mecanismo previsto em `django/06` **existe**. O que a previsão não
sabia é que o OTP 27 já se protege dele exatamente no caso que a Rinha impõe. A
frase honesta é: *a cota, que é a restrição do desafio, é também o que protege a
BEAM da armadilha da BEAM.*

Isso muda a previsão registrada para o **Go**, que ainda não foi medido: vale
conferir se o runtime do Go passou a ler `cpu.max` também, antes de repetir que
`GOMAXPROCS` seria armadilha. É uma verificação de fonte, não de opinião.

### 5.3 O Elixir perdeu para o FastAPI — e a previsão errou para o lado caro

Previsto: 150–400 µs, 2–6x melhor que o Django. Medido: **548,5 µs, 1,57x** —
fora da faixa, e **9,8% mais caro que o FastAPI** (499,7 µs). Na leitura em duas
queries a distância é maior: 394,6 contra 314,3, **25,6% pior**.

É a segunda vez seguida que a previsão de `django/06`, seção 8, erra sobre a
leitura. Vale registrar o padrão: as previsões daquele documento acertaram a
ordem de grandeza da **escrita** nos dois projetos e erraram a **leitura** nos
dois — subestimando o ganho do FastAPI e superestimando o do Elixir.

O que este resultado **não** autoriza dizer: que a BEAM é lenta. Ela entregou
1,57x sobre o Django com o mesmo SQL e a mesma estratégia. O que ele autoriza
dizer é que, **para este trabalho** — dois endpoints, payload minúsculo, uma
query por requisição —, o custo por requisição de CPython com uvloop e asyncpg é
menor que o de Elixir com Bandit e Postgrex. O trabalho é curto demais para a
BEAM cobrar barato: quase tudo é entrar e sair do runtime.

### 5.4 O achado não previsto: a leitura sai limitada pelo BANCO

Na variante padrão do extrato (`unica`), a API do Elixir fica com **1,9%** de
períodos throttlados e o **banco com 94,4%** — o gargalo migrou para o Postgres.
E o custo de CPU do banco, para o **SQL idêntico**, é:

| | µs de CPU no banco, por requisição |
| - | - |
| FastAPI + asyncpg | **177,0** |
| **Elixir + Postgrex** | **479,4** |

**2,7x**, com a mesma query, o mesmo schema, o mesmo `postgresql.conf` e a mesma
cota de banco. É grande demais para ser ruído, e é a explicação de por que o
Elixir entrega 1290 rps nesse braço contra 1638 do FastAPI **apesar de** ter a
API ociosa.

**Isto é um achado, não uma conclusão.** Não sei ainda o mecanismo. A hipótese
que testarei primeiro é reuso de *prepared statement*: `prepare: :named` é o
padrão do Postgrex e deveria manter o statement em cache por conexão, mas se por
algum motivo cada requisição refizer `Parse`/`Plan`, o custo cairia exatamente
onde caiu — a subquery com `string_agg` é cara de planejar e barata de executar.
Candidatas seguintes: diferença no protocolo estendido entre os dois drivers, e
o `queue_target`/`queue_interval` do DBConnection empurrando reconexões.

O jeito de decidir é medir, não argumentar: `log_statement` no Postgres, ou
`pg_stat_statements` contando `plans` contra `calls`.

Vale notar o desdobramento: **é a primeira vez neste laboratório que o Postgres
é o gargalo.** [`fastapi/03`](../fastapi/03-o-que-a-troca-de-framework-comprou.md)
previu que a troca de linguagem moveria o gargalo da aplicação para o banco. Ela
moveu — só que por um motivo que não era o previsto (não foi a aplicação ficar
rápida demais; foi o banco ficar caro demais).

### 5.5 A pontuação continua sem significar nada — mas a cauda melhorou

USD 100.000, como nas outras duas e como previsto. O que a nota não mostra: o
**máximo de 101ms** contra os **246ms** do FastAPI, que tinham encostado a 4ms
de custar dinheiro. E a subida em **4s**, a mais rápida das três.

Isso é consistente — mas só consistente, não comprovado — com a previsão nº 4:
a vantagem da BEAM apareceria na cauda, não na média. Uma execução não sustenta
a afirmação; sustentá-la exige repetir, e está nas ações.

### 5.6 As variantes de aplicação

- **`JSON_LIB=otp` contra `jason`: 0,5%.** Ruído. Esperado no braço `unica`, em
  que a aplicação não serializa nada — o JSON vem pronto do banco. O teste que
  valeria é no braço `duas`, e não foi rodado.
- **`EXTRATO_QUERY`**: os dois braços têm gargalos diferentes (API num, banco no
  outro), então a comparação de 246,7 contra 394,6 **não** é "1,6x melhor". O
  que ela diz é que a query única tira trabalho da API e o põe no banco — e no
  Elixir, ao contrário do FastAPI, o banco não tinha essa folga.

---

## 6. Ações decorrentes

- [x] Stack Elixir na competição: USD 100.000, zero inconsistências, subida em 4s.
- [x] Variantes `SCHEDULERS` e `BUSY_WAIT` medidas, com e sem cota.
- [ ] **Caçar os 479,4 µs de CPU de banco** (seção 5.4). É o achado mais
      relevante desta página, e o único que ainda é hipótese. Método:
      `pg_stat_statements` comparando `plans` com `calls`, Elixir contra FastAPI.
- [ ] Investigar a **amplitude de 28,8%** na leitura com query única. Amplitude
      alta não é ruído a mediar.
- [ ] Repetir a prova oficial mais duas vezes, para dizer se o **máximo de
      101ms** é propriedade da BEAM ou sorte de uma execução (seção 5.5).
- [ ] Medir `JSON_LIB` no braço `EXTRATO_QUERY=duas`, que é onde a aplicação de
      fato serializa.
- [ ] **Conferir no fonte se o runtime do Go lê `cpu.max`**, antes de repetir a
      previsão do `GOMAXPROCS` como armadilha (seção 5.2).
- [ ] Redistribuir a cota agora que o gargalo desta stack é o banco: a
      repartição `nginx 0.10 / API 0.40 ×2 / banco 0.60` foi eleita com o
      gargalo na aplicação, e pode não ser a melhor aqui.

---

## 7. Aprendizados transversais

Vão também para `04-aprendizados.md`.

- **Um runtime pode já ter resolvido a armadilha que você previu.** O OTP 27 lê
  a cota do cgroup — medido aqui, em quatro cotas; desde qual versão, não
  verifiquei. A previsão de 2026-08-22 tratou o comportamento do
  `os.cpu_count()` como se fosse universal. Verificar a versão do runtime é tão
  parte da metodologia quanto verificar o commit do código.
- **Uma previsão errada pelo motivo certo ainda é errada.** O raciocínio do
  busy-wait estava correto e a conclusão não, porque faltava uma premissa que a
  medição tinha em mãos.
- **Trabalho curto não deixa runtime nenhum brilhar.** Com uma query por
  requisição e payload minúsculo, quase todo o custo é entrar e sair do runtime,
  e é por isso que 1,57x é o teto aqui.
- **Quando o gargalo muda de serviço, a comparação anterior deixa de valer.**
  Duas linhas com o mesmo endpoint e a mesma cota podem estar medindo coisas
  diferentes — olhar `nr_throttled` por serviço **antes** de dividir os números
  é o que evita a conclusão errada.
