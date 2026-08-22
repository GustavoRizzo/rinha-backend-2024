# 06 — Tipos de worker: `sync`, `gthread` e ASGI/uvicorn

**Data**: 2026-08-22 · **Commits**: `8cf7e36` (séries sob cota), `6746658` (sem cota)
**Ferramenta**: `oha` 1.15.0 + Gatling 3.15.1 · **Banco**: Postgres 18

Sexto degrau, e o último da série. Uma variável: o servidor HTTP que executa a
aplicação. Tudo o mais é a stack do experimento 05 — nginx com socket Unix,
Postgres, 0.40 CPU por API.

**Por que o `oha` é o instrumento principal aqui.** A pontuação do Gatling
**satura**: com p98 de 7ms contra um SLA de 250ms, toda configuração razoável
marca USD 100.000 e a métrica perde resolução. O `oha` em saturação mede a
**folga**, que é onde a diferença entre servidores aparece. O Gatling entra como
confirmação de que a configuração passa na prova, não como comparador.

---

## 1. Ressalvas metodológicas — leia antes dos números

**1. As views deste projeto são SÍNCRONAS.** O braço `uvicorn` mede *Django com
views síncronas sob ASGI*, não "async em Python". Um aplicativo com views `async`
e driver de banco assíncrono é outro teste — e o Django 6.1 não tem driver
assíncrono de verdade (`db/models/query.py:694`: `aget` é
`sync_to_async(self.get)`).

**2. `uvicorn` precisou de pool de conexões para sequer completar uma série.**
Isso muda a configuração dele em relação aos outros. O braço `sync-pool` existe
para separar o custo do pool do custo do ASGI.

**3. Ainda é uma instância de API**, atrás do nginx, com toda a carga de escrita
concentrada no cliente 1 — pior caso de contenção.

**4. A seção "sem restrição" está fora do regulamento de propósito.** Serve para
responder quanto a cota custa e o que a aplicação entrega solta. Não compare com
nada da competição.

**5. Máquina local de 20 vCPUs, Docker Desktop sobre WSL2.**

---

## 2. Metodologia

| Braço | Servidor | Concorrência interna | Keep-alive | Conexões de banco |
| - | - | - | - | - |
| `sync` | Gunicorn sync | 1 requisição por vez | **não** | 1 persistente |
| `sync-pool` | Gunicorn sync | 1 requisição por vez | não | pool (máx. 8) |
| `gthread` | Gunicorn gthread | pool fixo de N threads | sim | 1 por thread |
| `uvicorn` | Uvicorn ASGI | thread por requisição | sim | pool (máx. 8) |

Séries de 5 repetições de 10s, aquecimento descartado, concorrência 50, banco
recriado antes de cada repetição nas séries de escrita.

### Hipótese registrada antes de medir

No fim do experimento 05 eu escrevi, no plano deste experimento:

> `uvicorn` (views síncronas) — **deve perder**: views síncronas vão para thread
> pool.

Fica registrado para o placar ser honesto: **essa previsão se confirmou**, ao
contrário da que fiz no experimento 03 sobre o número de workers com Postgres,
que se mostrou errada.

---

## 3. Comandos para replicar

```bash
just bench-06                                              # experimento inteiro
just bench-servidor uvicorn 4 transacoes 0.40 10s 5        # uma série
BENCH_POOL=1 just bench-servidor uvicorn 4 transacoes      # com pool de conexões
API_SERVER=gunicorn-gthread API_THREADS=4 just load django-gthread4   # Gatling
```

---

## 4. Resultados sob a cota da Rinha (0.40 CPU por API)

### Escrita — `POST /transacoes`, saturação

```
servidor                   rps   ampl%    p99ms  API us/req   thr%
sync                     483.9     4.8    166.3         862   95.3
sync + pool              467.7     6.6    157.3         884   94.3
gthread 2 threads        281.0     1.4    206.1        1500   96.2
gthread 8 threads        202.6     3.5    377.2        2093   96.2
gthread 4 threads        200.8     4.5    301.8        2114   97.2
uvicorn (ASGI) + pool    102.0    11.1    611.0        4295   95.4
```

### Leitura — `GET /extrato`, saturação

```
servidor                   rps   ampl%    p99ms  API us/req   thr%
sync                     334.9     3.6    194.8        1258   95.3
gthread 4 threads        170.1   906.0    780.2        2571   98.6
uvicorn (ASGI) + pool    114.0     2.5    575.4        3828   95.4
```

Todas as séries fecharam com 100% de HTTP 200.

---

## 5. Conclusões

### O worker sync ganha de todos, e com folga

**483,9 rps contra 281,0 do melhor `gthread` e 102,0 do `uvicorn`.** A explicação
inteira está na coluna `API us/req`: 862 µs contra 1500 e 4295.

Sob uma cota de CPU, **CPU por requisição é a moeda**. Vazão é apenas a cota
dividida por esse custo — e os números batem: `0,40 CPU ÷ 862 µs ≈ 464 req/s`,
contra 483,9 medidos.

### O pool custa 3%, então os 79% do uvicorn não são do pool

O braço `sync-pool` foi um controle que valeu a pena. O pool de conexões sozinho
custa 22 µs por requisição (862 → 884), ou ~3% de vazão.

Isso isola o resultado: **os 3433 µs extras do `uvicorn` são do caminho ASGI**,
não do pool. Cada requisição atravessa `async` → thread do pool → view síncrona →
volta, e paga por isso.

### `gthread` perdeu o argumento que tinha — por causa do experimento 03

O `gthread` entrou nesta comparação por um motivo específico: ele faz
keep-alive, e o worker `sync` fecha toda conexão (`sync.py:177`,
`resp.force_close()`), o que no experimento 02 esgotou as portas efêmeras do
host e invalidou metade daquele experimento.

Só que o experimento 03 resolveu esse problema por outro caminho: **socket de
domínio Unix** entre nginx e API, que não tem porta nem `TIME_WAIT`. Com o
problema eliminado por construção, o keep-alive do `gthread` deixou de comprar
qualquer coisa — e sobrou só o custo: +74% de CPU por requisição com 2 threads,
+145% com 4.

É um caso limpo de decisão que envelheceu bem: resolver a causa em vez do
sintoma tornou desnecessária uma troca que teria custado 42% de vazão.

### Mais threads não ajudam porque o trabalho é CPU, e existe o GIL

`gthread` com 4 e 8 threads deu praticamente o mesmo resultado (200,8 e 202,6
rps), ambos piores que com 2 threads (281,0). Threads adicionais não têm espera
para preencher — o Postgres responde rápido e `synchronous_commit = off` tirou o
disco do caminho crítico (experimento 04). O que sobra é trabalho de Python, que
o GIL serializa. As threads só somam troca de contexto.

A série de leitura com `gthread` teve **906% de amplitude** entre repetições. Uma
série assim não tem mediana significativa: ela diz que a configuração é
imprevisível, não que é lenta.

### O que isto NÃO diz sobre async

Vale insistir, porque é fácil ler errado: este experimento **não** mostra que
"async é lento em Python". Ele mostra que **rodar views síncronas sob um servidor
ASGI adiciona uma camada sem remover nenhuma**. O ganho do async depende de o
I/O ser assíncrono de ponta a ponta, e no Django 6.1 o ORM assíncrono é um
invólucro de thread pool sobre o driver síncrono.

Ter Django/uvicorn medido separadamente tem um valor específico para o futuro:
numa comparação Django vs. FastAPI, o servidor deixa de ser variável escondida.

---

## 6. Sem restrição de CPU e memória

*(fora do regulamento, por curiosidade)*

Mesma stack, com `deploy.resources.limits` removido — as cotas de CPU e memória
simplesmente não existem.

```
servidor                          conc.     rps    p99ms  API us/req  CPU usada
sync, 1 worker                       50   901.2     71.3         810      0.73
gthread 4 threads, 1 worker          50   737.0     79.2        1825      1.34
uvicorn (ASGI) + pool, 1 worker      50   378.8    167.8        3396      1.29
sync, 4 WORKERS (processos)         200  1817.2    142.4         940      1.71
```

`CPU usada` = `rps × CPU por requisição`, ou seja, quantos núcleos-equivalentes
o container consumiu de fato.

### A cota custa 46%, mas o ranking não muda

| servidor | 0.40 CPU | sem limite | fator |
| - | - | - | - |
| `sync` | 483,9 | 901,2 | 1,86x |
| `gthread` 4t | 200,8 | 737,0 | 3,67x |
| `uvicorn` | 102,0 | 378,8 | 3,71x |

O `sync` é o que **menos** ganha ao soltar a cota — e o motivo é bonito: um
worker sync é **uma thread**, e uma thread não passa de 1,0 CPU por definição
física. A 901,2 rps × 810 µs ele já consome 0,73 CPU. Ele está perto do próprio
teto, não do teto da máquina.

Os outros ganham mais porque **conseguem usar mais de um núcleo**: `gthread` a
737 rps × 1825 µs = 1,34 CPU; `uvicorn` a 378,8 × 3396 µs = 1,29 CPU.

E aqui está o resultado que eu não esperava: **mesmo podendo usar mais de um
núcleo, os dois continuam perdendo para um worker de uma thread só.** Com o GIL,
threads extras não paralelizam trabalho de Python — apenas encarecem cada
requisição o suficiente para anular o acesso a mais CPU.

### Processos escalam; threads não

A última linha da tabela é o contraste que fecha o argumento. Quatro workers
`sync` — que são **processos**, não threads — entregam **1817,2 rps**, o dobro de
um worker só, com o custo por requisição praticamente intacto (810 → 940 µs).

| 4 unidades de concorrência, sem cota | rps | CPU/req |
| - | - | - |
| 4 **threads** (`gthread`) | 737,0 | 1825 µs |
| 4 **processos** (`sync`, 4 workers) | **1817,2** | 940 µs |

**2,5x de diferença entre as duas formas de "usar 4".** Cada processo tem seu
próprio interpretador e seu próprio GIL, então o paralelismo é real; threads
dentro de um processo disputam o mesmo GIL e só pagam a troca de contexto.

Isso não muda a decisão para a Rinha — sob 0.40 CPU, quatro processos queimariam
a cota quatro vezes mais rápido e o experimento 04 já mostrou que perdem 28%.
Mas explica por que o Gunicorn escolheu processos como unidade padrão, e por que
o `WEB_CONCURRENCY` deste projeto vale 1 **por causa da cota**, não porque
paralelismo seja inútil.

---

## 7. Previsões: e se trocássemos de framework ou de linguagem?

**Esta seção é especulação, não medição.** Está aqui com números explícitos para
poder ser conferida depois — se as previsões estiverem erradas, o registro fica.

### O que os dados já dizem sobre onde está o gargalo

A pergunta natural é se trocar de linguagem adiantaria, ou se o gargalo real é o
banco e a rede. **Neste projeto, os dados respondem: o gargalo é a aplicação.**

| serviço | períodos throttlados, sob carga da Rinha |
| - | - |
| APIs | 95% (saturação) / 1,4% (carga real) |
| Postgres | 0,3–0,5% |
| nginx | 0,1–0,7% |

O banco e o balanceador ficam com folga enquanto as APIs congelam. E o custo por
requisição confirma: **862 µs na API contra ~110 µs no nginx**. O trabalho está
no Python.

### FastAPI com views `async` e `asyncpg`

**Previsão: ganho real, porém modesto — algo entre 1,5x e 3x.**

Continua sendo CPython, e é aí que mora a maior parte dos 862 µs. O que se
ganharia: Starlette é mais enxuto que a pilha de request/response do Django, e o
Pydantic v2 valida com núcleo em Rust. O que **não** se ganharia tanto quanto se
imagina: nosso caminho quente já usa SQL cru, então o custo do ORM do Django já
não está sendo pago.

Chute concreto: **300–500 µs por requisição**, contra 862 µs hoje.

Um ganho estrutural, esse sim, seria eliminar o problema que este experimento
encontrou: com views `async` de verdade e `asyncpg`, não existe thread por
requisição, e portanto não existe o "uma conexão de Postgres por requisição
concorrente" que nos obrigou a introduzir pool.

### Go

**Previsão: ganho grande — 8x a 15x menos CPU por requisição.**

Compilado, sem GIL, goroutines baratas, `pgx` excelente. Chute: **50–100 µs por
requisição**, o que sob a mesma cota de 0.40 CPU daria um teto de **4.000 a 8.000
rps**, contra os 484 medidos.

**Mas há uma armadilha que este projeto já pisou.** O experimento 02 mediu
`os.cpu_count() = 20` dentro de um container com 0.40 CPU: **o cgroup limita a
cota, não a visibilidade**. O runtime do Go define `GOMAXPROCS` pelo número de
núcleos visíveis, então uma porta ingênua subiria 20 threads de sistema
disputando 0.40 CPU — queimando a cota em milissegundos e congelando o cgroup
inteiro, exatamente como os 4 workers do experimento 04.

Previsão específica e testável: **uma porta Go sem `GOMAXPROCS` ajustado teria
cauda pior que o Django atual**, mesmo sendo muito mais rápida por requisição.
Com `GOMAXPROCS=1` (ou `automaxprocs`), aí sim os 8-15x apareceriam.

Ganho colateral: memória. O container Python usa ~54MB; um binário Go usaria
10-20MB, liberando ~70MB por instância para o Postgres dentro do orçamento de
550MB.

### Elixir / BEAM

**Previsão: ganho moderado em vazão, ganho maior em previsibilidade de cauda.**

Chute: **150–400 µs por requisição** — melhor que CPython, pior que Go. A BEAM
não é uma máquina de números rápida; a força dela é outra.

O diferencial seria o **escalonamento preemptivo**: nenhuma requisição consegue
monopolizar um scheduler, então a cauda tende a ser mais bem comportada sob
carga irregular. Num sistema em que p99 importa mais que média, isso vale mais
que vazão bruta.

Duas ressalvas honestas. Primeira: **sob cgroup, a justiça da BEAM não ajuda** —
quando a cota acaba, o cgroup congela *todos* os schedulers de uma vez, e não
existe escalonamento justo dentro de um processo congelado. Segunda: a BEAM
também sobe um scheduler por núcleo visível, ou seja, **cairia na mesma
armadilha do Go** sem ajuste de `+S`.

Ponto a favor: o pool do Ecto é explícito e limitado por configuração, o que
combina bem com `max_connections` apertado.

### Resumo das previsões

| | CPU/req (chute) | vs. Django hoje | Pontuação na Rinha |
| - | - | - | - |
| Django + Gunicorn sync (medido) | **862 µs** | — | 100.000 |
| FastAPI async + asyncpg | 300–500 µs | 1,7–2,9x | 100.000 |
| Go + pgx | 50–100 µs | 8–17x | 100.000 |
| Elixir/Phoenix | 150–400 µs | 2–6x | 100.000 |

### A conclusão que mais importa

**Nenhuma dessas trocas mudaria a pontuação.** A coluna da direita é a mesma em
todas as linhas, e não por acaso: já estamos em USD 100.000, com p98 de 7ms
contra um SLA de 250ms — **35x de folga**. Não existe nota acima do teto.

O ganho seria em **teto de vazão**, não em resultado. E vale notar onde o novo
gargalo apareceria: para sustentar 4.000 rps, o Postgres precisaria de ~8x a CPU
que tem hoje, e não há de onde tirar dentro de 1.5 CPU. **A troca de linguagem
moveria o gargalo da aplicação para o banco** — e aí a contenção nas 5 linhas
quentes, que hoje é irrelevante, passaria a ser o assunto.

Ou seja: a resposta à pergunta "o gargalo não seria o banco?" é **hoje não, mas
viraria**. E o que continuaria decidindo a corretude é a estratégia de
concorrência — o `UPDATE` atômico condicional — que não depende de linguagem
nenhuma.

---

## 8. Ações decorrentes

- [x] `WEB_SERVER` seleciona `gunicorn-sync`, `gunicorn-gthread` ou `uvicorn`.
- [x] Pool de conexões do psycopg disponível via `DB_POOL=1`.
- [x] `docker-compose.yml` parametrizado, com padrão na configuração vencedora.
- [x] **Decisão: o worker sync fica.** É o padrão do projeto.
- [ ] Experimento futuro: FastAPI com views `async` e `asyncpg` — async de ponta
      a ponta, que é o teste que este experimento não fez.

---

## 9. Aprendizados transversais

- **Sob cota, CPU por requisição é a única métrica que importa.** Vazão é
  consequência: cota ÷ custo.
- **Resolver a causa pode aposentar uma otimização inteira.** O socket Unix
  eliminou a razão de existir do `gthread` aqui.
- **Um controle barato separa causas.** O braço `sync-pool` custou uma série e
  provou que o pool não era o culpado pelo resultado do `uvicorn`.
- **Amplitude alta é informação, não ruído.** 906% de amplitude descreve uma
  configuração imprevisível.
- **Concorrência não é paralelismo.** Threads sob GIL adicionam custo sem
  adicionar vazão quando o trabalho é CPU.
