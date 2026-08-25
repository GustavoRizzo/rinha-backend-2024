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

**Regra derivada**: **verificar a VERSÃO do runtime é parte da metodologia.**
Uma armadilha real de uma linguagem pode já ter sido resolvida na versão que
está rodando. `os.cpu_count()` não enxerga o cgroup; o OTP 27 enxerga. Tratar o
comportamento de um runtime como universal foi o que produziu a previsão errada
sobre a BEAM — e é o que precisa ser conferido no fonte antes de repetir a
previsão do `GOMAXPROCS` para o Go.

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
