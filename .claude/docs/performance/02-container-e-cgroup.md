# 02 — A API em container, sob os limites de cgroup da Rinha

**Data**: 2026-08-21 · **Commit**: ver `resultados/bench/cpu*.serie.json`
**Ferramenta**: `oha` 1.15.0 · **Banco**: SQLite · **Docker Desktop / WSL2**

Segundo degrau da escada: mesma aplicação, mesmo SQLite, mesmo endpoint e mesma
ferramenta do experimento 01 — agora dentro de um container com cota de CPU e
teto de memória. Sem nginx e sem Postgres, para que a diferença seja atribuível
ao container e ao cgroup.

---

## 1. Ressalvas metodológicas — leia antes dos números

**1. Metade do experimento falhou, e a falha é o achado principal.** As
configurações com 1.5 CPU **não produziram números válidos** (seção 5). Só os
resultados de 0.45 CPU podem ser usados.

**2. Consequência: o custo da conteinerização em si NÃO foi isolado.** Era um
dos objetivos. Comparar 0.45 CPU no container contra o experimento 01 sem cota
misturaria duas variáveis; a única configuração que permitiria a comparação
limpa é justamente a que falhou.

**3. `network_mode: host` não funciona neste ambiente.** Docker Desktop roda os
containers numa VM separada, então a rede host liga à VM e não ao localhost do
WSL. O override `compose.bench-sqlite.host.yml` está no repositório e deve
funcionar em Docker nativo no Linux — aqui, não. **O custo do NAT da bridge
segue embutido em todos os números**, sem como separar.

**4. Ainda é só `GET /clientes/1/extrato`**, somente leitura, sobre SQLite. As
conclusões sobre número de workers podem mudar com o Postgres: espera de I/O
bloqueante é exatamente o cenário em que mais workers ajudam.

**5. A cota de 0.45 CPU é uma estimativa**, não uma regra. A Rinha limita 1.5 CPU
somando nginx + 2 APIs + banco; 0.45 por API é o rateio plausível, a ser
revisado quando a stack existir.

**6. Nada disto vale contra números do Gatling** nem contra o experimento 01 —
ferramentas e condições diferentes.

---

## 2. Metodologia

| Eixo | Valores |
| - | - |
| Cota de CPU (`deploy.resources.limits.cpus`) | 0.45 e 1.5 |
| Memória | 150MB |
| Workers do Gunicorn (sync) | 1, 2, 4 |
| Regime | saturação (`-c 50`) e taxa fixa de 170 rps |

170 rps é a fatia realista por instância: a Rinha injeta 340 req/s divididos
entre duas APIs.

Cada série: aquecimento descartado + 5 repetições (3 em taxa fixa) de 10s.

**Instrumentação nova em relação ao experimento 01**: leitura de
`/sys/fs/cgroup/cpu.stat` dentro do container, antes e depois de cada
repetição. Sem isso, "está lento" e "está congelado" são indistinguíveis.

Em taxa fixa, `oha --latency-correction` compensa coordinated omission — sem
ela a latência sai otimista.

---

## 3. Comandos para replicar

```bash
just bench-02                                        # experimento inteiro
just bench-cont 0.45 1 bridge 10s 5                  # uma série de saturação
just bench-cont 0.45 1 bridge 10s 3 170              # taxa fixa de 170 rps
```

Diagnóstico do que deu errado:

```bash
ss -tan state time-wait | wc -l     # portas em TIME_WAIT no host
docker exec rinha-bench-api01 cat /sys/fs/cgroup/cpu.stat
docker exec rinha-bench-api01 cat /sys/fs/cgroup/cpu.max
```

---

## 4. Resultados válidos (0.45 CPU)

### Saturação (`-c 50`, 5 repetições)

```
config                     rps   ampl%   p50ms    p99ms  CPUus/req   thr%
cpu0.45-w1-bridge        351.4    11.0   121.8    186.3       1343   99.0
cpu0.45-w2-bridge        307.6     5.4   190.7    206.3       1554   98.1
cpu0.45-w4-bridge        221.2    15.6   203.5    391.2       2169   98.1
```

### Taxa fixa 170 rps (modelo aberto, com `--latency-correction`)

```
config                     rps   p50ms    p99ms  CPUus/req   thr%
cpu0.45-w1-bridge-170rps  170.1     1.6      2.9       1638    0.0
cpu0.45-w2-bridge-170rps  170.1     1.8      3.3       1888    1.0
cpu0.45-w4-bridge-170rps  170.1     1.9      3.1       2088    1.0
```

---

## 5. O que deu errado: o worker sync do Gunicorn não faz keep-alive

Este é o resultado mais importante do experimento, e ele apareceu como um bug.

As séries de 1.5 CPU degradavam ao longo das repetições — `[819, 820, 355, 260,
268]` rps — e depois passaram a falhar por completo. O container continuava
`running`, sem OOM, com 54MB de 150MB usados. Olhando os erros do `oha` por
repetição:

```
rep1 rps=781.9  connection error=0
rep2 rps=769.6  connection error=121
rep3 rps=841.2  connection error=28
rep4 rps=636.0  connection error=256
rep5 rps=120.9  connection error=1159   (nenhuma resposta 200)
rep6 rps=102.1  connection error=971    (nenhuma resposta 200)
```

Progressão de esgotamento de recurso do lado do **host**, não do container. E de
fato: 4315 requisições fizeram o `TIME_WAIT` do host subir de 5081 para 6269. A
faixa de portas efêmeras é 32768–60999, ou seja ~28 mil portas, cada uma presa
por ~60s depois de fechada.

Isso só acontece se **cada requisição abrir uma conexão TCP nova**. E abre. Está
no fonte do Gunicorn, `workers/sync.py:177`:

```python
# Force the connection closed until someone shows
# a buffering proxy that supports Keep-Alive to
# the backend.
resp.force_close()
```

**O worker sync fecha toda conexão, sempre.** Não é configurável — a opção
`keepalive` do Gunicorn só vale para os workers assíncronos.

### Por que isso importa muito mais do que parece

Não é uma curiosidade de bancada. Tem três consequências diretas para a Rinha:

**O próprio comentário do Gunicorn descreve a arquitetura da Rinha.** "Until
someone shows a buffering proxy that supports Keep-Alive to the backend" — o
nginx é exatamente esse proxy. O desenho da competição (LB obrigatório na frente)
não é decorativo: com o worker sync, ele é o que torna o arranjo viável.

**O nginx resolve metade do problema.** Ele mantém keep-alive com o cliente
(o Gatling), mas o salto nginx→API continua pagando um TCP novo por requisição,
já que o backend recusa keep-alive. `upstream ... { keepalive N; }` no nginx não
adianta contra um backend que faz `force_close`.

**Isso reabre a escolha do worker.** `gthread` e os workers assíncronos suportam
keep-alive. O experimento 01 mostrou que o worker sync é rápido *por request*;
este mostra que ele é caro *por conexão*. Sob 340 req/s sustentados, isso pode
inverter a conta — e agora é uma pergunta empírica com data marcada.

### O que foi corrigido no ferramental

- `bench-container.sh` agora **aborta** quando os erros de conexão passam de 1%
  das respostas, em vez de gravar uma série envenenada em silêncio.
- Pausa de 5s entre repetições (`BENCH_PAUSA`) para o `TIME_WAIT` drenar.
- Isso mitiga, mas não resolve: a 800 rps o esgotamento volta. A solução real é
  keep-alive no backend.

---

## 6. Conclusões sobre os dados válidos

### Sob cota, menos workers é mais — e o efeito é grande

| Workers | rps (saturação) | CPU por request |
| - | - | - |
| 1 | **351,4** | **1343 µs** |
| 2 | 307,6 (−12%) | 1554 µs (+16%) |
| 4 | 221,2 (**−37%**) | 2169 µs (+61%) |

Monotônico nos dois sentidos. O mecanismo está na coluna da direita: **cada
worker adicional torna a requisição mais cara em CPU** — troca de contexto,
disputa de cache, mais processos por trás da mesma cota. Como a cota é fixa,
CPU desperdiçada é vazão perdida, um para um.

É a previsão do doc 01 (seção 3) confirmada com número: sob cgroup, mais
paralelismo pode dar menos desempenho. E o custo é grande o suficiente para não
haver dúvida — 37% de vazão entre 1 e 4 workers, muito acima dos ~15% de
amplitude entre repetições.

**Isto contradiz frontalmente o experimento 01**, onde 4 workers deram 3,7x mais
vazão. Não há contradição real: lá havia 20 vCPUs ociosos, aqui há 0,45. É
exatamente por isso que aquele número vinha marcado como não-transferível.

### Sob carga realista, sobra folga

A 170 rps — a fatia de uma instância na carga da Rinha — a configuração de 1
worker entrega **p99 de 2,9ms**, sem throttling algum. O consumo é de
`170 × 1638µs ≈ 0,28` CPU dos 0,45 disponíveis, ou 62% da cota.

Com a ressalva obrigatória: isto é leitura pura sobre SQLite. O `POST` com
Postgres é outra história, e é o experimento 03.

### Throttling: o interruptor que separa "lento" de "congelado"

Em saturação, **99% dos períodos** foram throttlados nas três configurações de
0.45 CPU. Em taxa fixa de 170 rps, **0%**. O mesmo binário, a mesma cota, a
mesma imagem — o que muda é só a demanda.

Isso é o que o doc 01 chama de penhasco: não há região intermediária de
degradação suave. Ou a demanda cabe na cota, ou o cgroup congela o processo até
a próxima janela. É por isso que `nr_throttled` é a primeira coisa a olhar
quando a latência piorar, antes de suspeitar do código.

---

## 7. Ações decorrentes

- [x] Dockerfile multi-stage com `uv`, entrypoint que prepara o banco.
- [x] Corrigido `Permission denied: /home/rinha` — o usuário foi criado com
      `--no-create-home` e o gunicorn 26 precisa do HOME para o control server.
- [x] `bench-container.sh` aborta com excesso de erros de conexão.
- [x] Instrumentação de `cpu.stat` (throttling e CPU por requisição).
- [ ] **Refazer as séries de 1.5 CPU** com um worker que faça keep-alive
      (`gthread`), ou em Docker nativo no Linux.
- [ ] Isolar o custo da conteinerização — pendente, depende do item acima.
- [ ] Medir o custo da bridge vs. host — impossível neste ambiente.
- [ ] Experimento 03: Postgres. A conclusão "1 worker" precisa ser reavaliada
      quando houver espera de I/O bloqueante.
- [ ] Experimento 04: nginx. Redesenhar considerando que o salto nginx→API não
      terá keep-alive com o worker sync.

---

## 8. Aprendizados transversais

- Uma série que degrada ao longo das repetições não está medindo o alvo; está
  medindo um recurso se esgotando. Olhar os valores crus por repetição, não só
  a mediana.
- `errorDistribution` do gerador de carga é dado de primeira classe. Uma série
  com 1159 erros de conexão e vazão "razoável" é lixo com aparência de número.
- Sob cgroup, CPU por requisição é a métrica que importa — não rps. rps depende
  de quanta CPU existe; CPU por requisição é propriedade do seu código.
