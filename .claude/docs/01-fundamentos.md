# 01 — Fundamentos teóricos

Documento de estudo. O objetivo aqui não é a Rinha em si, são os conceitos que a
Rinha exercita: teste de carga, latência, concorrência e limitação de recursos.

---

## 1. Teste de carga: o que é e o que não é

Um **teste de carga** (load test) mede como um sistema se comporta sob uma taxa
de requisições sustentada. Não confundir com os primos:

| Tipo | Pergunta que responde |
| - | - |
| **Load test** | O sistema aguenta a carga esperada dentro do SLA? |
| **Stress test** | Onde é o ponto de ruptura? O que quebra primeiro? |
| **Spike test** | O que acontece num pico súbito e curto? |
| **Soak / endurance** | Degrada ao longo de horas? (vazamento de memória, de conexões) |
| **Benchmark** | Comparação controlada entre implementações |

A Rinha é formalmente um **load test com asserções de correção embutidas** — e o
próprio autor avisa no código-fonte que misturar validação de lógica com teste de
performance não é prática recomendada no dia a dia. Ele fez isso porque a
competição precisa detectar quem trapaceia na consistência.

Para nós, o uso mais valioso é como **benchmark comparativo**: mesma carga, mesmas
restrições, implementações diferentes.

### Closed model vs. open model — o conceito mais importante daqui

Esta distinção explica quase todo comportamento estranho que você vai ver.

**Closed model** (modelo fechado): existe um número fixo de usuários virtuais. Cada
um faz uma requisição, **espera a resposta**, e só então faz a próxima. A vazão é
uma *consequência* da latência: se o servidor fica lento, os usuários fazem menos
requisições e a carga automaticamente diminui. É auto-regulado.

```
[VU 1] req ---> espera resposta ---> req ---> espera ...
```

**Open model** (modelo aberto): usuários novos chegam a uma taxa fixa,
**independentemente** de o servidor estar respondendo ou não. É o que acontece na
vida real: seus usuários não combinam entre si de acessar menos porque o site caiu.

```
t=0s  ->  220 usuários novos
t=1s  ->  220 usuários novos   (não importa se os de t=0 já responderam)
t=2s  ->  220 usuários novos
```

A Rinha usa **open model**: `constantUsersPerSec(220)`.

A consequência é dura. Num modelo fechado, um servidor lento apenas fica lento.
Num modelo aberto, se sua taxa de atendimento cai abaixo da taxa de chegada, a
fila cresce **sem limite** e a latência vai para o infinito. Não existe patamar
estável. Ou você escoa 340 req/s, ou você entra em colapso progressivo.

Isso é a razão pela qual "eu respondo devagar mas respondo" não é uma estratégia
viável aqui.

### Lei de Little

A relação fundamental entre as três grandezas:

```
L = λ × W

L = número médio de requisições dentro do sistema (concorrência)
λ = taxa de chegada (req/s)
W = tempo médio que cada requisição passa no sistema (latência)
```

Aplicando à Rinha, no pico: λ = 340 req/s. Se você quer manter a latência média
em, digamos, 20ms (0,02s):

```
L = 340 × 0,02 = 6,8 requisições simultâneas em voo
```

Ou seja: você precisa conseguir processar ~7 requisições ao mesmo tempo. Isso é
um bom número para dimensionar **pool de conexões do banco** e **workers da
aplicação**. Se a latência subir para 200ms, você precisa de 68 em voo — e
provavelmente não tem pool para isso, então a fila estoura.

A lei também funciona ao contrário, e é o diagnóstico mais útil: **se você sabe
sua vazão e sua concorrência máxima, sabe seu teto de latência.** Com um pool de
10 conexões e 340 req/s, o tempo máximo por requisição no banco é
`10 / 340 = 29ms`. Passou disso, forma fila.

---

## 2. Latência e percentis

### Por que a média é inútil

A média esconde a cauda. Considere 100 requisições: 99 em 1ms e 1 em 3000ms.
Média = 30ms — parece ótimo. Mas houve um usuário esperando 3 segundos.

Em sistemas reais a distribuição de latência é **fortemente assimétrica**: uma
massa concentrada perto do mínimo e uma cauda longa à direita causada por GC,
throttling de CPU, contenção de lock, retomada de conexão, page fault.

### Percentis

`pXX` = o valor abaixo do qual XX% das amostras caem.

- **p50** (mediana): a experiência típica.
- **p95 / p98 / p99**: a experiência dos azarados. É aqui que mora a verdade.
- **p99.9**: em escala real, é o que define se seu produto parece confiável.

A Rinha usa **p98 < 250ms**. Traduzindo: no máximo 2% das requisições podem passar
de 250ms.

> **Regra prática**: p50 diz se seu código é rápido. p99 diz se sua *infraestrutura*
> e seu *gerenciamento de recursos* são sadios. Uma cauda ruim quase nunca é
> algoritmo — é fila, lock, GC ou throttle.

### Coordinated omission

Armadilha clássica de ferramentas de carga. Se o gerador de carga espera a resposta
antes de mandar a próxima (closed model) e o servidor trava por 5s, a ferramenta
registra **uma** requisição de 5s — quando na realidade, num sistema aberto, teriam
chegado centenas de requisições nesse intervalo, todas sofrendo.

O resultado é que a ferramenta subestima drasticamente a cauda. O open model do
Gatling evita isso por construção. É mais um motivo pelo qual a Rinha usa esse
modelo, e um bom motivo para você preferi-lo em testes reais.

---

## 3. Limitação de recursos (cgroups)

### O que "1.5 CPU" significa

Nada a ver com clock ou GPU. É uma cota do **cgroup** do Linux: quanto tempo de CPU
o container pode consumir por unidade de tempo real.

O kernel divide o tempo em janelas (`cpu.cfs_period_us`, padrão 100ms) e dá ao
cgroup uma cota (`cpu.cfs_quota_us`). Com `cpus: "1.5"`:

```
período = 100ms
cota    = 150ms de CPU por período
```

O container pode usar 150ms de CPU a cada 100ms de relógio. Como 150 > 100, ele
**pode** rodar em mais de um núcleo ao mesmo tempo — 1,5 núcleo-equivalente. Não
existe fixação a núcleos específicos (isso seria `cpuset`, outra coisa).

### Throttling: a causa nº 1 de cauda ruim sob limite

Quando o cgroup esgota a cota antes do fim da janela, **todas as suas threads são
congeladas** até a próxima janela começar. Não há degradação suave: é uma parada
completa de até 100ms.

E aqui está o detalhe traiçoeiro: quanto **mais** threads você tem, mais rápido você
queima a cota. Uma aplicação com 8 threads sob cota de 0,45 CPU consome os 45ms
disponíveis em ~6ms de relógio e depois fica congelada por 94ms. Todo mundo que
chegar nesse intervalo espera.

```
Cota 0.45, 8 threads ativas:
|=== 6ms rodando ===|--------- 94ms CONGELADO ---------|=== rodando ===|
                     ^ requisições chegando e enfileirando
```

Uma aplicação com 2 threads sob a mesma cota espalha o consumo ao longo da janela
e pode nunca ser throttlada. **Menos paralelismo pode dar menos latência sob cota.**
Isso é contraintuitivo e é um dos aprendizados centrais da Rinha.

Como observar: `/sys/fs/cgroup/cpu.stat` dentro do container expõe `nr_throttled`
e `throttled_usec`. Se `nr_throttled` cresce, você achou seu gargalo.

### Limite de memória

`memory: "100MB"` é um teto rígido. Estourar não deixa lento — o **OOM killer**
mata o processo. Num container isso costuma aparecer como "a API sumiu no meio do
teste" e `docker inspect` mostrando `OOMKilled: true`.

Runtimes com heap gerenciado (JVM, .NET, Go) precisam ser informados do limite,
senão dimensionam o heap pela memória da máquina hospedeira e são mortos. Python
e Node sofrem menos, mas Postgres é sensível: `shared_buffers` + `work_mem` ×
conexões precisa caber.

### Onde declarar no Compose

```yaml
services:
  api01:
    deploy:
      resources:
        limits:
          cpus: "0.45"
          memory: "100MB"
```

> ⚠️ **Gotcha histórico**: `deploy.resources.limits` era originalmente uma chave de
> Docker Swarm e o `docker-compose` v1 a **ignorava silenciosamente** — você achava
> que estava testando sob limite e não estava. O Compose v2 (`docker compose`, sem
> hífen) honra a chave normalmente. As regras da Rinha exigem essa sintaxe, então
> use-a — mas **sempre confirme** com `docker stats` que o limite pegou.

---

## 4. Controle de concorrência

O coração do desafio. O problema é o clássico **read-modify-write**:

```
Thread A: lê saldo = 0
Thread B: lê saldo = 0
Thread A: valida -1 >= -limite  ok  ->  grava saldo = -1
Thread B: valida -1 >= -limite  ok  ->  grava saldo = -1
```

Duas transações de débito de 1, saldo final -1 em vez de -2. Dinheiro sumiu. É
exatamente isso que os 25 débitos concorrentes da simulação detectam.

### Lost update e as anomalias

- **Lost update**: a escrita de B sobrescreve a de A, que é perdida. É o caso acima.
- **Dirty read**: ler dado de transação não confirmada.
- **Non-repeatable read**: ler duas vezes na mesma transação e obter valores diferentes.
- **Phantom read**: uma segunda consulta retorna linhas novas.

Níveis de isolamento SQL (`READ COMMITTED`, `REPEATABLE READ`, `SERIALIZABLE`)
definem quais anomalias são impedidas. **`READ COMMITTED` — o padrão do Postgres —
NÃO impede lost update.** Este é o erro que mais derruba participantes.

### As estratégias

**1. Update atômico condicional** — a mais simples e a mais rápida:

```sql
UPDATE clientes
   SET saldo = saldo - $valor
 WHERE id = $id
   AND saldo - $valor >= -limite
RETURNING saldo, limite;
```

Uma única instrução. O banco pega o lock de linha, lê, valida e grava sem janela
entre as etapas. Se retornar zero linhas, o limite seria estourado → HTTP 422.
Não há round-trip intermediário, não há transação explícita, não há lógica de
saldo na aplicação. Difícil de superar.

**2. Lock pessimista** — `SELECT ... FOR UPDATE`:

```sql
BEGIN;
SELECT saldo, limite FROM clientes WHERE id = $id FOR UPDATE;
-- valida na aplicação
UPDATE clientes SET saldo = ... WHERE id = $id;
INSERT INTO transacoes ...;
COMMIT;
```

Correto, mas segura o lock durante dois round-trips de rede. Sob 340 req/s em 5
clientes, a contenção é severa. Funciona; é mais lento.

**3. Lock otimista** — coluna de versão, relê e tenta de novo em caso de conflito.
Ótimo quando conflitos são raros. Aqui os conflitos são **a regra** (5 clientes,
340 req/s), então o retry vira desperdício.

**4. Serialização por ator/fila** — uma fila por cliente, um processador por fila.
Elimina contenção por construção e é elegante, mas exige que todas as requisições
daquele cliente cheguem ao mesmo lugar — com 2 instâncias de API, precisa de
roteamento por cliente ou de um coordenador.

> Para a Rinha, a estratégia 1 é quase sempre a resposta certa. As outras valem
> como experimento comparativo.

### O detalhe do extrato

O teste faz um POST e imediatamente 5 GETs paralelos, exigindo que **todos**
vejam a transação recém-criada. Isso proíbe:

- responder 200 antes de a escrita estar confirmada (write-behind, fire-and-forget)
- cache do extrato sem invalidação síncrona
- réplicas de leitura com lag

Ou seja: **read-your-writes** é obrigatório.

---

## 5. Onde o desempenho realmente vai embora

Em ordem de impacto típico neste tipo de desafio:

1. **Conexões de banco.** Abrir conexão é caríssimo (TCP + autenticação + setup de
   sessão). Sem pool, você paga isso a cada requisição. No Postgres cada conexão é
   um **processo** com ~5-10MB — 100 conexões não cabem em 550MB. Pool pequeno e
   reutilizado ganha de pool grande.

2. **Round-trips.** Cada ida ao banco custa latência de rede. Duas queries em vez
   de uma dobra o custo. Daí a força do `UPDATE ... RETURNING`.

3. **Contenção de lock.** 5 clientes concentram toda a carga em 5 linhas. Quanto
   mais tempo o lock fica segurado, mais fila.

4. **Throttling de CPU.** Ver seção 3.

5. **Serialização JSON e overhead de framework.** Middlewares, validação, ORM.
   Um ORM pode adicionar 10x ao custo de uma query simples.

6. **Rede do Docker.** O modo `bridge` faz NAT em cada pacote. Em volumes altos
   isso aparece. O modo `host` elimina a camada — foi vantagem na primeira edição
   da Rinha.

7. **fsync / durabilidade.** Cada commit no Postgres força escrita em disco por
   padrão. `synchronous_commit = off` dá um ganho enorme ao custo de poder perder
   os últimos milissegundos num crash — decisão legítima aqui, inaceitável num
   banco real de pagamentos.

---

## 6. Vocabulário

| Termo | Significado |
| - | - |
| **VU** (virtual user) | Usuário simulado pelo gerador de carga |
| **Throughput / vazão** | Requisições processadas por segundo |
| **RPS** | Requests per second |
| **Latência** | Tempo entre enviar a requisição e receber a resposta |
| **Cauda (tail)** | As requisições mais lentas; p99 e além |
| **Backpressure** | Mecanismo de recusar/atrasar carga para não colapsar |
| **Head-of-line blocking** | Uma requisição lenta trava as que estão atrás dela |
| **Connection pool** | Conjunto de conexões reutilizadas |
| **Cold start** | Latência extra das primeiras requisições (JIT, cache frio) |
| **Warm-up** | Fase de aquecimento antes de medir |
| **Ramp-up** | Aumento gradual da carga |
| **Saturação** | Ponto em que aumentar a carga não aumenta a vazão |
| **Knee point** | Joelho da curva: onde a latência dispara |

---

## 7. Para aprofundar

- Gil Tene, *"How NOT to Measure Latency"* — a palestra sobre coordinated omission.
  Provavelmente a hora mais bem investida do assunto.
- Brendan Gregg, *Systems Performance* — método USE (Utilization, Saturation, Errors).
- Martin Kleppmann, *Designing Data-Intensive Applications*, cap. 7 — isolamento
  de transações e lost update, explicado melhor do que na documentação de qualquer banco.
- Documentação do Postgres, "Transaction Isolation" e "Explicit Locking".
