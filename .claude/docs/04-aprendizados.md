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
Achado central de `performance/02-container-e-cgroup.md`.

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

**Ação**: instalar a 3.14. Se a simulação não compilar, ajustar o mínimo
necessário e registrar aqui; 3.10.3 fica como rede de segurança.

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
o objetivo é ficar sob o limiar em 98%+ das ~82.000 requisições, com zero
inconsistências.

---

## Concorrência

*(a preencher conforme os experimentos do Bloco B)*

Hipótese inicial a validar: `UPDATE ... WHERE saldo - valor >= -limite RETURNING`
vence `SELECT FOR UPDATE` por margem larga, porque elimina um round-trip com o
lock segurado. Sob 340 req/s concentrados em 5 linhas, o tempo de posse do lock
domina.

---

## Performance

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

*(a preencher — seção provavelmente a mais valiosa do documento)*
