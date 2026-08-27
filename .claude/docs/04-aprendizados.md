# 04 — Diário de aprendizados técnicos

Registro cronológico do que descobrimos ao longo do projeto. Um item por
aprendizado, com data, contexto e conclusão. Entradas mais recentes no topo de
cada seção.

Formato sugerido para novas entradas:

```
### [AAAA-MM-DD] Título curto do aprendizado
**Contexto**: o que estava acontecendo
**Observado**: o dado concreto (número, erro, log)
**Conclusão**: o que isso ensina
**Ação**: o que mudou por causa disso
```

---

## Ambiente e ferramental

### [2026-08-20] `docker` no PATH era o shim do Windows
**Contexto**: `docker --version` falhava com "could not be found in this WSL 2
distro", mas `docker-compose` respondia normalmente.

**Observado**:
```
docker         -> /mnt/c/Program Files/Docker/Docker/resources/bin/docker
docker-compose -> /usr/bin/docker-compose   (v2.27.0, standalone)
dockerd        -> AUSENTE
/var/run/docker.sock -> não existe
```

**Conclusão**: o Docker Desktop instala um shim no PATH do WSL via interop com o
Windows. Se a **integração WSL não está habilitada para aquela distro específica**,
o shim existe mas falha. O `docker-compose` em `/usr/bin` era um binário standalone
sobrando da distro anterior — daí o sintoma bizarro de "ter compose sem ter docker".
A migração de `Ubuntu-22.04` para `Ubuntu 26.04` (jun/2026) deixou a integração
marcada só na distro antiga.

**Ação**: habilitada a integração em Docker Desktop → Settings → Resources → WSL
Integration. Resultado: Engine 29.6.2, Compose v5.3.1, 20 CPUs / 31GB.

**Generalizando**: `command -v <bin>` antes de depurar. Um binário sob `/mnt/c/`
é sempre um executável do Windows atravessando a fronteira do WSL.

---

### [2026-08-21] Esgotamento de portas efêmeras: o gargalo que não é CPU
**Contexto**: no experimento 02, as séries com 1.5 CPU degradavam entre
repetições e depois paravam de responder por completo — com o container vivo,
sem OOM, usando 54MB de 150MB e **sem throttling algum**.

**Observado**:
```
rep1 rps=781.9  connection error=0
rep2 rps=769.6  connection error=121
rep4 rps=636.0  connection error=256
rep5 rps=120.9  connection error=1159   (nenhuma resposta 200)
```
4315 requisições fizeram o `TIME_WAIT` do host subir de 5081 para 6269.
`/proc/sys/net/ipv4/ip_local_port_range` = `32768 60999`, ou seja ~28 mil portas.

**Conclusão**: uma conexão TCP é identificada pela quádrupla
`(IP origem, porta origem, IP destino, porta destino)`. A porta de origem é
sorteada de uma faixa finita — as **portas efêmeras**. Ao fechar, a conexão não
some: ela entra em **`TIME_WAIT` por ~60s**. Essa espera não é desperdício, é
segurança — impede que um pacote atrasado da conexão antiga seja entregue a uma
conexão nova que reusou a mesma quádrupla.

Consequência aritmética: **~28.000 portas ÷ 60s ≈ 470 conexões novas por
segundo** é o teto sustentável. Acima disso a faixa esgota e o sistema para de
abrir conexões — parada total, com CPU ociosa.

Isso só vira problema se **cada requisição abrir uma conexão nova**. E abre,
quando o worker sync do Gunicorn faz `resp.force_close()`
(`gunicorn/workers/sync.py:177`).

**O detalhe mais instrutivo**: a 0.45 CPU o problema **não aparecia**. O
throttling segurava a vazão em ~350 rps, abaixo do teto de ~470/s, e as portas
se liberavam no mesmo ritmo em que eram consumidas. **O limite de CPU escondia o
limite de rede.** Afrouxar um gargalo revelou o outro — que é como gargalos
costumam se comportar.

**Ação**: `bench-container.sh` aborta com mais de 1% de erros de conexão.
Achado central de `performance/django/02-container-e-cgroup.md`.

**Camadas — para não confundir HTTP com TCP**:

| Camada | O que faz | Exemplos |
| - | - | - |
| Aplicação | o que a mensagem significa | **HTTP**/1.1, HTTP/2, HTTP/3 |
| Transporte | entregar bytes de um ponto a outro | **TCP**, UDP, QUIC |
| Rede | achar o caminho entre máquinas | IP |

HTTP **não é** TCP: é um formato de mensagem que historicamente **viaja sobre**
TCP. HTTP/1.1 e HTTP/2 exigem TCP. **HTTP/3 não** — roda sobre QUIC, que roda
sobre UDP, e por isso não tem TIME_WAIT nem portas presas do mesmo jeito. Trocar
de transporte é uma escolha real — mas não aqui: o Gatling da Rinha fala
HTTP/1.1 sobre TCP, e quem escolhe é o cliente.

**Onde a escolha existe de verdade é no salto interno.** Entre o nginx e a API
nada obriga TCP: um **socket de domínio Unix** (`unix:/tmp/api.sock`) é um
arquivo atendido inteiramente dentro do kernel. Sem portas, sem TIME_WAIT, sem
handshake de três vias. Elimina esta classe de problema por construção, e é o
que deve ser usado quando o nginx entrar.

### Quem gasta porta efêmera, e por que os dois saltos não têm o mesmo problema

Esta parte faltava no registro original, e é o que responde à pergunta óbvia:
*se o socket Unix só protege o salto interno, o salto de fora não continua
exposto?*

**Porta efêmera é gasta por quem ABRE a conexão, não por quem a recebe.** O
servidor tem uma porta só — a 9999 — e todas as conexões chegam nela; o que
distingue uma da outra é a porta *do outro lado*, na quádrupla. Por isso um
servidor não esgota portas por atender, por mais carga que receba.

Quem esgotava, no experimento 02, era o **gerador de carga**. Está no número
registrado acima: o `TIME_WAIT` que subiu de 5.081 para 6.269 era do **host**,
onde o `oha` rodava. A aplicação forçava o fechamento a cada resposta, e o
cliente precisava de uma porta nova a cada requisição.

Daí a assimetria das duas correções:

| salto | quem abre conexão | o que protege | mecanismo |
| - | - | - | - |
| cliente → nginx | o cliente (Gatling, `oha`, navegador) | **keep-alive** | `keepalive_timeout 65` e `keepalive_requests 10000` no `nginx.conf`: cada conexão serve até 10.000 requisições, e as 61.503 do teste cabem em poucas centenas delas |
| nginx → API | o nginx | **socket Unix** | não existe porta para gastar |

O primeiro **administra** o problema: continua havendo portas, `TIME_WAIT` e
handshake, só que raramente. O segundo **elimina** o problema, e por isso é mais
forte — mas só é possível porque nginx e API estão na mesma máquina.

### E a conclusão que importa: o problema não era do protocolo

O HTTP/1.1 tem keep-alive desde 1997. O worker `sync` do Gunicorn simplesmente
não o usava (`resp.force_close()`, `gunicorn/workers/sync.py:177`). **O
protocolo oferecia a solução e a implementação recusava.**

Trocar de versão de HTTP não teria resolvido nada ali — e a mesma armadilha
existe do lado do nginx, num lugar que passa despercebido: o padrão do
`proxy_pass` é falar **HTTP/1.0** com o upstream, que não tem keep-alive. É por
isso que `infra/nginx/nginx-rinha.conf` traz as duas linhas

```nginx
proxy_http_version 1.1;
proxy_set_header Connection "";
```

Elas não são decoração: sem elas, o nginx recriaria a conexão com a API a cada
requisição — reintroduzindo, do lado de dentro, exatamente o comportamento que
derrubou a stack no experimento 02.

---

### [2026-08-21] Ferramentas de teste de carga: duas, com papéis diferentes
**Contexto**: para os comparativos locais (DEBUG vs. produção, `runserver` vs.
Gunicorn) o Gatling é ferramenta errada — ele existe para a prova final, contra a
stack completa na porta 9999, com asserções de consistência. Para medir o custo
de um processo isolado ele é pesado demais para o ciclo de iteração.

**Observado**: nenhum gerador de carga instalado na máquina (`wrk`, `hey`, `ab`,
`oha`, `k6`, `bombardier`, `vegeta` — todos ausentes). Gatling também.

**Decisão**: **duas ferramentas, papéis separados e nunca comparadas entre si.**

| Ferramenta | Papel | Modelo de carga | Por quê |
| - | - | - | - |
| **`oha`** | comparativos locais rápidos (docs em `performance/`) | aberto (`-q`) e fechado | binário único em Rust, sobe instantâneo, saída em JSON, e faz **taxa fixa de verdade** |
| **Gatling 3.14** | a prova oficial da Rinha, contra a stack completa | aberto (`constantUsersPerSec`) | é o que a competição usa; asserções de consistência no meio da carga |

Não são concorrentes: o Gatling aponta para a porta 9999 e exige LB + 2 APIs +
banco, com validação de lógica embutida — é o exame final. Subir uma JVM a cada
iteração de microbenchmark é atrito puro.

**Razão de escolher `oha` e não o óbvio `wrk`**: o `wrk` só faz modelo fechado.
Como o doc 01 explica, modelo fechado é auto-regulado — um servidor lento
simplesmente recebe menos carga, e a cauda de latência sai subestimada
(*coordinated omission*). O regime que mais interessa aqui é "latência sob taxa
fixa de ~340 req/s", e isso exige modelo aberto.

**Regra derivada** (a mesma da entrada sobre versões do Gatling, generalizada):
**nunca comparar números produzidos por ferramentas diferentes** — nem por
versões diferentes da mesma ferramenta. Cada tabela de resultado registra qual
ferramenta e qual versão a produziu.

---

### [2026-08-20] Decisão: usar sempre a versão mais recente do Gatling
**Contexto**: o repo oficial foi testado com Gatling 3.10.3 (mar/2024). A versão
mais recente é a **3.14** (mai/2025).

**Decisão**: usar a **mais recente**. O objetivo do projeto é estudo, não
reproduzir o ranking oficial — e como já não podemos comparar com o ranking
(hardware diferente, ver entrada abaixo), não há motivo para carregar uma versão
antiga.

**Risco avaliado**: os breaking changes desde a 3.10 (a 3.12 removeu o Akka)
afetam **plugins de terceiros**, não o DSL de simulação. Tudo que a simulação da
Rinha usa — `scenario`, `exec`, `http`, `jmesPath`, `checkIf`, `inject`,
`rampUsersPerSec`, `.resources()` — é API estável há várias versões. JDK 17
local atende.

**Ação**: instalada a **3.15.1** (a mais recente em ago/2026). A simulação Scala
compilou sem alteração alguma — a avaliação de risco estava certa quanto ao DSL.

⚠️ **O que a avaliação de risco NÃO previu**: a partir da 3.13 o *bundle* mudou
de formato. Não existe mais `$GATLING_HOME/bin/gatling.sh`; o download é um
**projeto Maven em Java**, com `mvnw` e `pom.xml`. Como a simulação oficial é
Scala, foi preciso montar `gatling/` no repositório com o `scala-maven-plugin`.
A execução passou a ser `./mvnw gatling:test`, e o `executar-teste-local.sh`
oficial não funciona mais como está.

**Generalizando**: ao avaliar o risco de uma atualização, olhar também o
*empacotamento*, não só a API. Foi o empacotamento que quebrou, não o DSL.

⚠️ **Regra derivada**: **nunca comparar números entre versões diferentes do
Gatling.** Escolhida uma versão, todas as variantes rodam nela. Se um dia
trocarmos, re-rodar tudo ou marcar a descontinuidade em `resultados/`.

---

### [2026-08-20] Decisão: repositório único (monorepo)
**Contexto**: cada framework terá sua pasta (`rinha-back-2024-django`,
`rinha-back-2024-fastapi`, ...). Versionar a raiz ou cada projeto?

**Decisão**: **um repositório único** na raiz `rinha-backend-2024/`.

**Razões**:
- O valor do projeto está na **comparação**, não em nenhuma implementação isolada.
  `resultados/` precisa ficar plano e lado a lado para `just compare` funcionar.
- `infra/`, `scripts/` e o `justfile` são compartilhados. Em repos separados
  viram cópias que divergem em silêncio — e aí não dá para saber se a diferença
  de resultado veio do código da API ou do nginx.
- Um commit = um estado testável do mundo inteiro. Torna `git bisect` viável
  quando um resultado piorar sem explicação óbvia.
- A documentação em `.claude/docs/` é transversal.

**Contraponto registrado**: se alguma variante virar projeto próprio para
portfólio, extrair depois é trivial (`git subtree split`). Começar junto e
separar depois é fácil; o inverso não.

**Ação**: `git init` na raiz. `rinha-de-backend-2024-q1/` vai para o
`.gitignore` (é público, read-only, não queremos o histórico dele aqui).

---

### [2026-08-20] Máquina de trabalho vs. ambiente oficial
**Observado**: local = 20 vCPU / 31GB. Oficial = 4 vCPU / 15GB.

**Detalhe importante sobre "4 vCPU"**: o `v` é de *virtual*. O `lscpu` oficial
mostra `Core(s) per socket: 2` e `Thread(s) per core: 2` — ou seja, **2 núcleos
físicos com hyper-threading**, não 4 núcleos independentes. Hyper-threads do
mesmo núcleo compartilham unidades de execução: duas threads no mesmo núcleo
rendem ~1,1-1,3x, não 2x. E, sendo VM Azure, ainda há disputa com outros
inquilinos.

**Conclusão**: os limites de cgroup (1.5 CPU / 550MB) se aplicam igual, mas o
contexto é diferente: no servidor oficial o Gatling disputava CPU com a aplicação,
o que degradava os resultados de todos. Aqui há folga de sobra.

**Ação**: números locais servem para comparar **variantes entre si**, não para
comparar com o ranking oficial. Toda pontuação registrada deve deixar isso claro.

---

## Conceitos

### [2026-08-25] Versões do HTTP: o que cada uma compra, e o que custa aqui
**Contexto**: a pergunta natural ao ver `http/1.1` no DevTools — *não faria
sentido usar algo mais moderno?* Ela tem duas metades: quem decide o protocolo,
e se a troca valeria a pena.

**Quem decide**: ninguém sozinho. O cliente propõe, o servidor aceita. O que o
`nginx.conf` faz é **oferecer** opções — e a nossa oferta é só HTTP/1.1, porque
`listen 9999` não tem `ssl` nem `http2`.

O detalhe que fecha a questão do navegador: **navegadores só falam HTTP/2 sobre
TLS**. A negociação acontece no ALPN, uma extensão do handshake TLS — sem TLS,
não há onde negociar. Existe HTTP/2 em texto claro (h2c) e o nginx o suporta,
mas nenhum navegador o implementa, de propósito.

**O que cada versão compra**:

| versão | transporte | ganho principal | custo |
| - | - | - | - |
| HTTP/1.0 | TCP | — | sem keep-alive: uma conexão por requisição |
| **HTTP/1.1** | TCP | keep-alive, pipelining | head-of-line blocking por conexão |
| HTTP/2 | TCP | multiplexação numa conexão, HPACK nos cabeçalhos | camada de frames e estado de HPACK = mais CPU por requisição; head-of-line blocking **desce para o TCP** |
| HTTP/3 | QUIC/UDP | multiplexação sem HOL blocking, handshake mais curto | pilha nova, mais CPU ainda, e sem `TIME_WAIT` porque não há TCP |

**Onde o ganho do HTTP/2 aparece de verdade**: muitas requisições pequenas por
conexão, com cabeçalhos grandes e repetidos — uma página com dezenas de assets.
**O que este workload tem**: duas rotas, corpos de 50 a 400 bytes, cabeçalhos
mínimos e keep-alive já ativo nos dois saltos. O problema que o HTTP/2 resolve
já não existe aqui.

**Medido** (exploratório — ver ressalva abaixo), leitura, sob a cota da
competição, com o nginx em 0.15 CPU:

| protocolo | rps | CPU do nginx | **nginx congelado** |
| - | - | - | - |
| HTTP/1.1 | **3121** | **42,7 µs** | 6,6–25,7% |
| h2c | 2707 | 58,6 µs | **97–98%** |

**+37% de CPU no nginx e −13% de vazão.** Na escrita, +24% de CPU e vazão
praticamente igual (1213 contra 1208), porque ali quem manda é a API.

E o braço de controle, com o nginx em 1.0 CPU para separar *custo* de
*saturação*, rodado nas duas ordens: o custo extra do h2c cai para **+11% a
+14%**, e a diferença de vazão **desaparece dentro da amplitude**.

**Conclusão**: o custo do HTTP/2 é real e consistente — ele sempre gasta mais
CPU no nginx. O que varia é se isso importa: sob cota, empurrou o serviço
proporcionalmente mais carregado da stack para 98% de saturação; sem cota, sumiu
no ruído. **É a regra da escassez outra vez** — a mesma que explica por que
statements replanejados custaram 2,02x ao Elixir e 1,01x ao Django.

**Ressalva**: medição exploratória, feita fora do ferramental do projeto — rig
numa porta separada, script de medição próprio, série **não arquivada** em
`resultados/`. Vale como ordem de grandeza e como direção, não como número de
documento. Para virar experimento, precisaria de `compose.h2c.yml` versionado,
slug próprio e série arquivada.

**Ação**: nada muda. O `listen 9999` continua sem `http2`, e por três motivos em
ordem de peso: (1) a simulação oficial do Gatling fala HTTP/1.1 e é cópia bit a
bit da original — trocar o protocolo mudaria o que está sendo medido e quebraria
a comparação com as outras três stacks; (2) o h2c custa CPU justamente no
serviço mais apertado; (3) para o navegador usar HTTP/2 seria preciso TLS, cujo
handshake e cifragem sairiam do mesmo orçamento de 1,5 CPU.

**Onde a escolha de protocolo seria interessante de verdade**: HTTP/3, que roda
sobre QUIC e portanto **não tem `TIME_WAIT` nem portas presas** do jeito que o
TCP tem. Isso ataca a raiz do achado das portas efêmeras em vez de administrá-lo
— mas o cliente é quem escolhe, e o cliente aqui é fixo.

---

### [2026-08-20] Open model é o que torna a Rinha difícil
**Contexto**: entender por que "responder devagar" não é uma opção viável.

**Conclusão**: `constantUsersPerSec(220)` injeta usuários a taxa fixa
independentemente das respostas. Se a taxa de atendimento cai abaixo da taxa de
chegada, a fila cresce sem limite — não existe equilíbrio estável em degradação.
Num modelo fechado, um servidor lento apenas gera menos carga; num aberto, ele
colapsa. Detalhes no doc 01, seção 1.

---

### [2026-08-20] O limite de 250ms é por requisição, não pelo teste
**Contexto**: confusão inicial sobre haver ou não limite de tempo.

**Conclusão**: os 4 minutos são a duração da carga. O SLA é `p98 < 250ms`, aplicado
**a cada requisição individual**. Responder mais rápido que 250ms não gera bônus —
o objetivo é ficar sob o limiar em 98%+ das 61.503 requisições, com zero
inconsistências.

---

## Concorrência

### [2026-08-22] Zero inconsistências em 9 execuções da prova oficial
**Contexto**: a hipótese inicial era que o `UPDATE ... WHERE saldo + delta >=
-limite RETURNING` bastaria para impedir *lost update*, sem `SELECT FOR UPDATE`
nem nível de isolamento elevado.

**Observado**: 9 execuções completas do Gatling (6 no experimento 05, 3 no 06),
somando mais de 550 mil requisições. **Nenhuma inconsistência de saldo.** O
grupo de verificações de consistência da simulação fechou 123/123 em todas.

A simulação faz exatamente o que quebraria uma implementação ingênua: 25 débitos
concorrentes tentando estourar o limite exato, e um POST seguido de 5 GETs
paralelos exigindo que todos vejam a transação recém-criada.

**Conclusão**: o `UPDATE` condicional atômico resolve leitura, validação e
escrita numa instrução, sem janela entre ler e gravar. `READ COMMITTED` — o
padrão do Postgres — **não** impede *lost update*; foi a estratégia que impediu,
não o banco.

**O achado mais interessante veio do fracasso**: no experimento 06 o `uvicorn`
colapsou, derrubando 54% das requisições, com p98 de 25 segundos — e mesmo assim
**zero inconsistências**. Um servidor sobrecarregado *recusa* requisições; ele
não processa transações erradas. **Disponibilidade e corretude falham
separadamente**, e é fácil confundir as duas ao ler um relatório ruim.

**Pendente**: comparar contra `SELECT FOR UPDATE` para quantificar a diferença.
A hipótese continua sendo que o lock pessimista perde por segurar o lock durante
dois round-trips, mas isso não foi medido.

---

## Performance

### [2026-08-22] O placar das decisões de desempenho
**Contexto**: consolidação do que os seis experimentos mediram. Cada linha tem
documento próprio em `performance/`.

| Decisão | Efeito medido | Onde |
| - | - | - |
| Conexão de banco persistente (`CONN_MAX_AGE`) | **4,75x** de vazão | [04](./performance/django/04-postgres.md) |
| Socket Unix entre nginx e API | 2,9x; amplitude de 246% para 3,9% | [03](./performance/django/03-nginx-e-socket-unix.md) |
| Worker `sync` em vez de `gthread` | 2,4x | [06](./performance/django/06-tipos-de-worker.md) |
| Worker `sync` em vez de ASGI/uvicorn | 4,7x | [06](./performance/django/06-tipos-de-worker.md) |
| Worker `sync` em vez de Django `async` de ponta a ponta | 2,5x (escrita) / 1,5x (leitura) | [08](./performance/django/08-django-async.md) |
| Cota de CPU nas APIs, não no banco | p98 de 217ms para 7ms | [05](./performance/django/05-stack-completa-gatling.md) |
| 1 worker por API em vez de 4 | 28% (sob cota) | [04](./performance/django/04-postgres.md) |
| `DEBUG=False` | 4,1% | [01](./performance/django/01-debug-vs-producao.md) |

**Conclusão que atravessa todas**: sob cota de cgroup, **CPU por requisição é a
única métrica que importa**. Vazão é consequência aritmética — cota dividida por
custo. Toda decisão acima é, no fundo, a mesma decisão: gastar menos CPU por
requisição.

**A mais barata de todas foi redistribuir**: mover 0,25 CPU de serviços ociosos
para as APIs não custou nada e derrubou o p98 de 217ms para 7ms. Só foi possível
porque `nr_throttled` estava sendo medido por serviço.

---

### [2026-08-27] Async não compra vazão onde não há espera para sobrepor
**Contexto**: [`django/08`](./performance/django/08-django-async.md) fechou a
lacuna que o experimento 06 deixou aberta — views `async def` com
`psycopg.AsyncConnectionPool`, sem `sync_to_async` no caminho quente.

**Hipótese registrada antes**: async perde do worker síncrono por 1,2x a 1,7x.
**Medido**: perde por **2,51x** na escrita e 1,48x na leitura. Certo na direção,
errado na magnitude — e certo só no endpoint de leitura.

O mecanismo é o que interessa. **Async compra sobreposição de espera.** Nesta
stack não existe espera para sobrepor: o Postgres é local e responde em
centenas de microssegundos, `synchronous_commit = off` tirou o disco do caminho
crítico, e a cota de 0.40 CPU garante que o gargalo é CPU de Python. Pagar o
mecanismo e não ter o que sobrepor é custo puro.

Três desdobramentos que valem além deste experimento:

1. **Remover uma camada acusada não devolve o custo inteiro.** Tirar a thread
   por requisição do ASGI recuperou metade dos 4160 µs, não tudo. O resto era a
   pilha ASGI do próprio Django, que ninguém tinha separado da thread.
2. **A vantagem do FastAPI não era o async.** 499,7 µs contra 2198 µs entre dois
   aplicativos assíncronos, mesmo Python, mesmo SQL: **4,4x que é só tamanho de
   framework**. Isso corrige uma leitura fácil de fazer do experimento
   [`fastapi/01`](./performance/fastapi/01-fastapi-async.md).
3. **Um pool maior pode encarecer o banco.** Uma conexão persistente concentra
   cache num backend; oito espalham a escrita por oito processos nas mesmas 5
   linhas quentes — +60% de CPU de banco por escrita. Hipótese, ainda não
   confirmada por `pg_stat_statements` por backend.

**E a inversão que sustenta a regra**: com um banco remoto de 50ms a resposta
viraria do avesso, e o worker síncrono — uma requisição por vez — seria o pior
arranjo de todos. **A arquitetura certa depende de onde o tempo é gasto**, e
aqui ele é gasto em CPU.

**Ganho que o async entregou de verdade, e não é vazão**: sem thread por
requisição, não existe mais "uma conexão de Postgres por requisição concorrente".
O `FATAL: sorry, too many clients` do experimento 06 fica impossível por
construção. Segurança operacional, não velocidade.

---

### [2026-08-25] O valor de uma correção é a escassez do recurso que ela libera
**Contexto**: o mesmo defeito — statements replanejados a cada requisição —
existia no Elixir e no Django, com a mesma assinatura (`plans = calls`).

**Observado**:

| | Elixir | Django |
| - | - | - |
| % do tempo de banco planejando | 62,2% | 44–54% |
| quem estava congelado | **o banco** (94,4%) | **a API** (94–96%) |
| ganho ao corrigir | **2,02x** | **1,01x** |

**Conclusão**: o tamanho do desperdício não prevê o tamanho do ganho. O que
prevê é **de quem era o recurso desperdiçado**. Devolver 62% do trabalho de um
banco saturado vira vazão; devolver 48% do trabalho de um banco ocioso não vira
nada.

**Ação**: registrado em `performance/django/07`. E vale como pergunta a fazer
antes de qualquer otimização: *o recurso que eu vou liberar está escasso?*

---

### [2026-08-25] A bancada elege, a prova oficial decide — pela segunda vez
**Contexto**: `GOMAXPROCS=1` no Go. Sob cota, custa 20% menos CPU por requisição
que o padrão `auto`, e derruba a amplitude entre repetições de 25% para 1,7%.

**Observado**: na prova oficial, cinco execuções de cada braço.

| | abaixo de 250ms | p98 por execução |
| - | - | - |
| `auto` | 100% nas cinco | 4, 4, 4, 5, 4 ms |
| `1` | 99,61% numa delas | 4, 5, 5, **37**, **68** ms |

**Conclusão**: é o mesmo mecanismo de `performance/fastapi/02`, seção 5.4, com
outro botão. Sob 340 req/s **nada satura** — a stack usa ~13% do orçamento — e
aí a segunda thread deixa de ser desperdício e vira o que absorve as rajadas do
modelo aberto.

**Ação**: padrão fica `auto`. E a regra derivada de lá ganha uma segunda
confirmação: *otimização medida em saturação não se transfere para a carga real;
se o sistema não satura no uso previsto, a folga não é desperdício, é o
amortecedor da cauda.*

---

### [2026-08-25] Bloco B: o `UPDATE` atômico vence, mas não "por larga margem"
**Contexto**: a maior lacuna do plano, aberta antes da primeira linha de código.

**Observado**, sob contenção máxima (50 requisições concorrentes na mesma linha):

| estratégia | rps | vs. B2 | quem congela |
| - | - | - | - |
| `update-returning` | 1256,5 | — | **o banco** (93,5%) |
| `select-for-update` | 1137,5 | 0,91x | a API (93,4%) |
| `advisory-lock` | 1072,7 | 0,85x | a API (94,3%) |
| `otimista` | 351,7 | 0,28x | os dois |

**Conclusão**: 9% a 15% sobre os locks pessimistas, e não a "larga margem" que a
hipótese previa. O ganho é **aritmética de round-trips** — B2 economiza um
contra B1 e dois contra B3 — não mágica.

E o detalhe contraintuitivo: **B2 é a única com o banco saturado, e ganha
assim**. As duas com lock explícito deixam o Postgres quase ocioso e perdem,
porque a aplicação passa o tempo **esperando** o lock — e esperar não aparece
como CPU em lugar nenhum.

**Ação**: `performance/go/05`. A estratégia do projeto não muda; passa a ser
escolha medida em vez de hipótese.

---

### [2026-08-25] O guarda contra falha silenciosa tinha uma falha silenciosa
**Contexto**: duas séries de bancada já haviam sido perdidas por sobrescrita
(`elixir/04` e `go/01`). A correção foi arquivar a série anterior antes de
gravar a nova.

**Observado**: o bloco de arquivamento procurava
`${config}-${ENDPOINT}.serie.json`. O nome real é `${config}.serie.json` — o
endpoint já está dentro de `$config`. Ele não achava nada e **não arquivava
nada, sem imprimir uma linha sequer**. Custou mais uma série antes de eu
perceber.

**Conclusão**: escrever o guarda não é o mesmo que ter o guarda. O que faltou
foi o passo de **verificar que ele dispara** — re-rodar uma série e ver o
arquivo aparecer, que é o que fez o bug cair em dez segundos depois.

**Ação**: corrigido e verificado. Nas 24 séries seguintes, 23 arquivamentos
dispararam.

---

### [2026-08-25] O mesmo zero significa o oposto em dois drivers de Postgres
**Contexto**: porte da configuração de pool do FastAPI para o Go. O asyncpg
recebe `max_inactive_connection_lifetime=0`, e ali zero quer dizer **nunca
recicle a conexão** — a decisão que `performance/django/04` sustenta com 4,75x
entre conexão persistente e conexão nova por requisição.

**Observado**: com `MaxConnLifetime = 0` no `pgxpool`, a API não subia:

```
pgxpool: too many failed attempts acquiring connection;
likely bug in PrepareConn, BeforeAcquire, or ShouldPing hook
```

A mensagem acusa hooks que o código não usa. A causa está em
`pgxpool/pool.go:463`: `isExpired` é `time.Now().After(maxAgeTime)`, e
`maxAgeTime` é a criação **mais** `MaxConnLifetime`. Com zero, toda conexão
nasce vencida e é destruída no primeiro `Acquire`. Os padrões do pgx são
finitos: 1h de vida e 30min de ociosidade (`pool.go:22-23`).

**Conclusão**: "zero" é uma convenção, não uma semântica. Em asyncpg é
*infinito*; em pgxpool é *imediato*. Portar configuração entre stacks copiando o
valor — e não a intenção — troca uma decisão medida por outra sem avisar.

**Ação**: `MaxConnLifetime` e `MaxConnIdleTime` passam a receber um valor grande
e finito, com o motivo e a citação de fonte no comentário
(`go/db.go`). Registrado em `performance/go/00-indice.md`, seção 7.3.

**O que salvou**: a falha foi barulhenta. Se zero significasse "recicle a cada
requisição" em vez de "destrua imediatamente", a stack teria subido, respondido
tudo certo, e pago 4,75x em toda requisição — dentro de um número plausível.
Este projeto já perdeu três experimentos para números plausíveis.

---

### [2026-08-21] `PositiveIntegerField` no Postgres é `integer` + CHECK constraint
**Contexto**: escolhendo o tipo da coluna `Transacao.valor`, que por contrato só
pode ser um inteiro positivo. A escolha "óbvia" seria `PositiveIntegerField`.

**Observado**: no fonte do Django 6.1 instalado,
`django/db/backends/postgresql/base.py`:

```python
data_types = {
    ...
    "PositiveIntegerField": "integer",      # linha 125
}
data_type_check_constraints = {
    ...
    "PositiveIntegerField": '"%(column)s" >= 0',   # linha 136
}
```

**Conclusão**: o Postgres **não tem** um tipo inteiro sem sinal. `Positive*Field`
não muda o tipo da coluna — gera o mesmo `integer` mais uma **CHECK constraint**,
avaliada em todo INSERT. É o mesmo raciocínio da FK (hack M2), em escala menor:
verificação no caminho mais quente reafirmando algo que a aplicação já garantiu.

Detalhe que decide sozinho a questão: a constraint expressa `>= 0`, não `> 0`.
Ela **aceitaria** `valor = 0`, que o contrato da Rinha proíbe. Ou seja, nem
substitui a validação da aplicação — duplicaria só metade dela, e errado.

**Ação**: `Transacao.valor` fica `IntegerField`. Registrado como hack M7 em
`05-hacks-da-competicao.md`.

**Generalizando**: em Postgres, todo `Positive*Field` é açúcar sintático sobre
uma CHECK constraint. Em MySQL é diferente — lá existe `unsigned` de verdade e o
Django usa o tipo nativo, sem constraint. **A mesma linha de Python tem custo
diferente por backend**; vale conferir `data_types` e
`data_type_check_constraints` do backend antes de assumir.

**Nota honesta**: numa aplicação real eu manteria a constraint. Defesa em
profundidade vale mais que microssegundos quando não se está espremido em 1.5 CPU
somando todos os serviços.

---

---

## Erros cometidos

Seção mantida deliberadamente: erros custam caro e são a parte que menos
aparece em relatório técnico.

### Afirmar sem medir
- **"`DEBUG=True` vaza memória sob WSGI."** Afirmado com confiança em dois
  lugares do código antes de medir. É falso: `reset_queries` está ligado ao
  sinal `request_started` (`django/db/__init__.py:52`), então `connection.queries`
  zera a cada requisição. O vazamento só existe fora do ciclo de request.
- **"O Gunicorn ganha do `runserver` por causa de keep-alive."** Falso: o
  `runserver` usa HTTP/1.1 (`basehttp.py:179`). A causa real é contenção de GIL,
  porque ele cria uma thread por conexão sem limite (`basehttp.py:87`).
- **"Com Postgres, mais workers vão ajudar por causa da espera de I/O."** O
  oposto: com `synchronous_commit = off` a escrita virou CPU-bound e 4 workers
  perderam 28%. Quem precisava de mais workers era o SQLite.
- **"O custo do ORM do Django já não está sendo pago, porque o caminho quente
  usa SQL cru."** Verdade para a escrita, falso para a leitura — e a frase foi
  escrita sem essa distinção, na previsão de `performance/django/06`, seção 8.
  `Cliente.extrato` faz `objects.get()` mais um queryset: **11 instâncias de
  modelo por requisição**. Medido em `performance/fastapi/01`: a escrita ganhou
  1,73x ao trocar para FastAPI+asyncpg (dentro do previsto), e a leitura ganhou
  **4,00x**, muito acima da faixa prevista. A diferença entre os dois números é
  o tamanho do ORM no endpoint que eu não olhei.

- **"Tirar a thread por requisição do ASGI recupera quase todo o excedente do
  experimento 06."** Previsto 1000–1500 µs por escrita; medido **2198 µs**.
  Recuperou metade dos 4160 µs, não dois terços: eu tratei a thread por
  requisição como se fosse todo o custo do caminho ASGI, e a pilha do
  `django/core/handlers/asgi.py` continua lá depois que ela sai. Na mesma
  previsão eu disse que o async perderia do worker síncrono por 1,2x–1,7x —
  perdeu por **2,51x** na escrita; a faixa só valeu para a leitura (1,48x).
  Medido em `performance/django/08`.

- **"A BEAM sobe um scheduler por núcleo VISÍVEL, e `SCHEDULERS=auto` seria
  armadilha sob cota."** Falso no OTP 27: ele lê a cota do cgroup e sobe 1
  scheduler com `--cpus=0.40`, 2 com 2 CPU, 4 com 4 — enxergando 20 núcleos o
  tempo todo. Os quatro braços do teste ficaram dentro de 2,2%, abaixo do ruído.
  A armadilha existe, mas só **sem** cota: lá `auto` custa 2,16x mais CPU por
  requisição para 4,4% mais vazão. Medido em `performance/elixir/01`.
- **"Sob cgroup, o busy-wait dos schedulers da BEAM custa mais que schedulers
  demais."** Aposta própria, registrada antes de medir, e **errada**: 0,4% de
  diferença. O raciocínio ("spin queima cota, e queimar não é de graça") estava
  certo; faltava a premissa de que **com 1 scheduler não há para quem esperar**,
  e a própria BEAM já tinha reduzido para 1 ao ler a cota. Medido em
  `performance/elixir/01`.
- **"Elixir custaria 150–400 µs por requisição, 2 a 6x menos que o Django."**
  Medido: 548,5 µs e 1,57x — fora da faixa, e **9,8% mais caro que o FastAPI**,
  que a mesma previsão colocava atrás dele. Terceira previsão de
  `performance/django/06`, seção 8, e a segunda a errar a leitura: 394,6 µs
  contra 314,3 do FastAPI, 25,6% pior.

- **"O Elixir custa mais por requisição que o FastAPI."** Dito assim, engana. O
  custo da APLICAÇÃO é 1,10x na escrita e 0,96x na leitura — praticamente
  empate. O que é sistematicamente mais caro é o **banco**: 1,36x na escrita e
  2,71x na leitura, com SQL idêntico, mesmo schema, mesma cota, e reproduzido em
  três regimes (bancada sob cota, carga real do Gatling e bancada sem cota, onde
  chega a 3,47x). A conclusão original de `performance/elixir/01` foi corrigida
  na própria página. **Somar API e banco numa métrica só escondeu onde estava o
  custo.**

- **"O Go entrega a pior cauda das quatro stacks."** Afirmado com número
  (98,57% abaixo de 250ms, 882 requisições lentas) a partir de **uma execução**
  — que era a **primeira execução daquela stack na máquina**. Três execuções
  depois: 99,95%, 100% e 100%, com p98 de 4ms, o **melhor** das quatro. A regra
  "descartar a rodada de aquecimento" está escrita no `CLAUDE.md`, eu a aplico
  em toda série de `oha`, e não a apliquei à prova oficial — que custa 4 minutos
  e por isso convida a rodar uma vez só. Medido em
  `performance/go/00-indice.md`, seção 7.5.

- **"Uma porta Go sem `GOMAXPROCS` ajustado subiria 20 threads disputando 0.40
  CPU, e teria cauda pior que o Django."** Previsão de
  `performance/django/06`, seção 8, **morta pela versão da linguagem** antes de
  a primeira série rodar: o Go 1.27 lê a cota do cgroup
  (`runtime/cgroup_linux.go:85-92`) e sobe 2 threads sob 0.40 CPU, não 20. Mesma
  história do OTP 27 logo acima — duas previsões de armadilha de runtime, as
  duas neutralizadas por evolução do runtime. **A armadilha é real e o
  mecanismo é real; o que envelhece é o pressuposto de que o runtime não
  aprendeu.** O que sobra de verdadeiro: `NumCPU()` continua devolvendo 20 lá
  dentro, e qualquer código que dimensione por ele continua caindo na armadilha.
  Medido em `performance/go/00-indice.md`, seção 7.1.

- **"`prepare: :named` mantém os statements em cache, sem pagar parse+plan por
  requisição."** Escrito num comentário de `elixir/lib/rinha/config.ex` com a
  confiança de quem conferiu, sem ter conferido. É falso: `Postgrex.query/4` sem
  `:cache_statement` monta um `%Query{name: ""}` — statement **sem nome**, que o
  Postgres prepara e descarta a cada chamada
  (`deps/postgrex/lib/postgrex.ex:339`). Medido com `pg_stat_statements`:
  `plans = calls` e **62,2% do tempo de banco gasto planejando**, contra ZERO do
  asyncpg. Corrigido, a leitura ficou **3,97x mais barata no banco** e o Elixir
  passou de "mais caro que o FastAPI" para o **mais barato dos três**. Duas
  conclusões de documento tiveram de ser invertidas. Ver
  `performance/elixir/04`.

- **"O nginx virou o gargalo da leitura."** Afirmado a partir de 87–93% de
  períodos congelados no cgroup dele. Soltar a cota de 0.15 para 0.40 rendeu
  2,6% — dentro do ruído. Ele saturava a própria cota sem ser o limite do
  sistema. Medido em `performance/fastapi/02`.

- **"Mover 0.20 CPU das APIs para o banco melhora a stack."** Medido: 1,54x mais
  escritas na bancada. E recusado pela prova oficial, em duas execuções — 24
  requisições acima do SLA nas duas, e o máximo indo de 246ms para 315 e 340ms.
  A bancada mede em SATURAÇÃO; a Rinha aplica ~340 req/s e não satura nada.
  Registrado em `performance/fastapi/02`, seção 5.4.

**Regra derivada**: **otimização medida em saturação não se transfere
automaticamente para a carga real.** Se o sistema não satura no uso previsto, a
folga não é desperdício: é o amortecedor da cauda. As duas ferramentas deste
projeto respondem perguntas diferentes — o `oha` responde "quanto cabe", o
Gatling responde "como se comporta no que chega" — e a segunda é quem decide.

**Regra derivada**: **throttling alto não prova gargalo.** A porcentagem de
períodos congelados diz que um serviço satura a *sua* cota, não que ele seja a
parede. A prova é operacional: solte a cota daquele serviço e veja se a vazão
sobe. Se não subir, ele não era o gargalo.

**Regra derivada**: **quando a hipótese vier com o método ao lado, execute o
método.** O achado dos "479 µs de CPU de banco" foi registrado com a solução
escrita junto (*"`pg_stat_statements` comparando `plans` com `calls`"*), e
seguiram-se dois documentos e nove séries apoiados na conclusão errada. Executar
o método custou dois comandos e cinco minutos, e a resposta era binária.

**Regra derivada**: **um comentário de código com um número dentro não é uma
medição.** O comentário errado do `config.ex` citava a opção certa, descrevia um
comportamento plausível e concluía o oposto do que a opção faz. Ele sobreviveu a
três experimentos porque *parecia* verificado. A regra do `CLAUDE.md` — citar
arquivo e linha do fonte — existe exatamente para isso, e não foi seguida.

**Regra derivada**: **medir por serviço, não por sistema.** Uma métrica que
soma aplicação e banco responde "quanto custa", nunca "onde custa" — e as duas
perguntas levam a ações opostas: trocar de linguagem ou trocar de driver. O
cgroup de cada serviço é barato de coletar e foi o que separou as duas.

**Regra derivada**: **paralelismo não resolve serialização.** Sem cota nenhuma,
num host de 20 núcleos, o Elixir entregou 2,06x o FastAPI na LEITURA e perdeu
por 12,8% na ESCRITA — porque a bancada escreve sempre no mesmo cliente, e todo
`UPDATE` na mesma linha serializa. Antes de atribuir a um runtime a culpa por
não escalar, verifique se o trabalho é paralelizável.

**Regra derivada**: **verificar a VERSÃO do runtime é parte da metodologia.**
Uma armadilha real de uma linguagem pode já ter sido resolvida na versão que
está rodando. `os.cpu_count()` não enxerga o cgroup; o OTP 27 enxerga. Tratar o
comportamento de um runtime como universal foi o que produziu a previsão errada
sobre a BEAM — e produziu de novo a do `GOMAXPROCS` para o Go, que o 1.27
neutraliza lendo a cota do cgroup (`runtime/cgroup_linux.go:85-92`). Duas
previsões, dois runtimes, a mesma causa: supor que o runtime não aprendeu.

**Regra derivada**: **a regra do aquecimento vale para a prova oficial também.**
Ela nasceu na bancada, onde uma rodada custa 10 segundos e repetir é barato. A
simulação do Gatling custa 4 minutos, e foi exatamente por isso que rodei uma
vez só e escrevi uma conclusão que três execuções derrubaram. O custo de uma
medição não muda o que ela vale.

**Regra derivada**: **`docker exec` roda DENTRO do cgroup do container medido.**
Um amostrador que fotografa `cpu.stat` por segundo gasta a cota do serviço
observado: numa execução instrumentada, o nginx (0.10 CPU) saltou de 0,1% para
20,6% de períodos congelados, e o custo por requisição de todos os serviços
inflou de 19% a 39%. Instrumento de amostragem contínua serve para achar
**quando**, nunca para medir **quanto** — e é inutilizável em serviço de cota
pequena. As duas fotos de `cgroup-snapshot.sh`, antes e depois, não têm esse
problema.

**Regra derivada**: **quando o gargalo muda de serviço, a comparação anterior
deixa de valer.** Duas linhas com o mesmo endpoint e a mesma cota podem estar
medindo coisas diferentes: no extrato com query única, a API do Elixir fica
ociosa e o banco satura, enquanto no FastAPI é o contrário. Olhar
`nr_throttled` **por serviço** antes de dividir os números é o que evita a
conclusão errada.

**Regra derivada**: **"o caminho quente" não é um lugar só.** Uma afirmação
verificada num endpoint não vale no outro sem verificar de novo. Este sistema
tem dois endpoints com perfis de custo opostos.

### Ferramenta que mente em silêncio
- **`summary.total` do `oha` é a DURAÇÃO, não a contagem de requisições.** O CPU
  por requisição saiu inflado ~350x até alguém conferir a ordem de grandeza.
- **`pontuacao.py` procurava a coluna "Total Count"**, mas o rótulo do Gatling
  3.15 é "Total". O `.get` devolvia 0 e o total zerado virava multa máxima —
  98 mil de multa numa execução sem nenhuma falha.
- **`pontuacao.py` contava todo KO como inconsistência de saldo**, e cobrou USD
  26,7 milhões por 33.305 timeouts. Timeout pesa no SLA; não é inconsistência.

**Regra derivada**: todo script de medição deve **abortar** quando não
reconhecer o que está lendo. Os três casos acima produziram números plausíveis
em vez de erro.

### Proveniência falsa
- **A primeira versão do experimento 01 registrou um commit que não continha o
  código medido** — nem o interruptor `DJANGO_DEBUG` existia lá. Hoje os scripts
  abortam com a árvore suja.
- **O `dml.sql` foi gerado com `pg_dump` depois de um smoke test**, então o
  cliente 1 nasceu com saldo 100. O `verificar_clientes` abortou a subida da
  stack e evitou o desastre. Agora o DML vem da fixture.

### Medição sem higiene estatística
- **A primeira execução de qualquer configuração é lixo** (757 rps contra
  833–877 nas seguintes). Sem descartá-la, o efeito de 4% do `DEBUG` ficava
  invisível — a ponto de a primeira medição sugerir que `DEBUG=True` era *mais
  rápido*.
- **Reportar mediana sem amplitude.** Uma série com 246% de amplitude não tem
  mediana significativa; ela diz que a configuração é imprevisível.

### Infraestrutura
- **Dois projetos Compose com o mesmo `name`.** Um container remanescente da
  stack real bloqueava a subida do rig de bancada, e o erro era engolido por um
  `>/dev/null` — o `set -e` derrubava o script sem dizer nada.
- **Redirecionar stderr de comando crítico para `/dev/null`.** Transformou uma
  falha diagnosticável em falha silenciosa, duas vezes.
- **`useradd --no-create-home`** e o gunicorn 26 logando `Permission denied` a
  cada boot, porque cria o socket do control server no HOME.
