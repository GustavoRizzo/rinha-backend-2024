# 03 — nginx na frente, e o que um socket Unix vale

**Data**: 2026-08-21 · **Commit**: `4cd8fe3` (árvore limpa, as 6 séries)
**Ferramenta**: `oha` 1.15.0 · **Banco**: SQLite · **Docker Desktop / WSL2**

Terceiro degrau: mesma aplicação, mesmo SQLite e mesmo endpoint dos experimentos
01 e 02 — agora atrás de um load balancer. A API deixa de ser exposta; só o nginx
publica porta.

O experimento existe por dois motivos. O primeiro é montar a camada que a Rinha
exige. O segundo é consertar o que invalidou metade do experimento 02: o
esgotamento de portas efêmeras. E como o conserto é uma linha de configuração,
dá para **medir exatamente quanto ele vale**.

---

## 1. Ressalvas metodológicas — leia antes dos números

**1. Ainda é só `GET /clientes/1/extrato`**, somente leitura, sobre SQLite. Sem
espera de I/O relevante. Conclusões sobre concorrência não transferem para o
Postgres.

**2. Uma instância de API, não duas.** A Rinha exige duas. Este experimento
isola o custo do salto pelo LB; a distribuição entre instâncias fica para depois.

**3. A cota de 0.15 CPU / 32MB do nginx é escolha, não dedução.** Escolhida por
ser enxuta dentro do orçamento de 1.5 CPU. O experimento mostra que sobra folga.

**4. `nginx-tcp` está aqui como controle, não como alternativa séria.** Ele
existe para quantificar o socket Unix. Os números dele são instáveis **por
projeto**, e essa instabilidade é o resultado.

**5. Docker Desktop.** Containers rodam numa VM; a rede publicada passa por um
proxy de porta. O custo disso está embutido em tudo.

**6. Nada disto se compara com números do Gatling.**

---

## 2. Metodologia

| Rig | Salto nginx→API | Diferença |
| - | - | - |
| `nginx-unix` | `unix:/sockets/api01.sock` | volume compartilhado entre os containers |
| `nginx-tcp` | `api01:8080` | **uma linha** do `upstream`; todo o resto idêntico |

Cotas: API 0.45 e 1.5 CPU / 150MB; nginx 0.15 CPU / 32MB. Gunicorn com worker
`sync`, 1 worker. Séries de 5 repetições de 10s (3 em taxa fixa), com
aquecimento descartado.

**Instrumentação nova**: `cpu.stat` é coletado dos **dois** cgroups. O custo do
load balancer entra no resultado em vez de ser externalidade.

---

## 3. Comandos para replicar

```bash
just bench-03                                  # experimento inteiro
just bench-stack nginx-unix 0.45 1 10s 5       # uma série
just bench-stack nginx-tcp  1.5  1 10s 5       # o controle instável
```

---

## 4. Resultados

### Saturação, API com 0.45 CPU

```
config                             rps  ampl%   p50ms    p99ms  API us/req  LB us/req  API thr%
direto, sem LB (exp. 02)         351.4   11.0   121.8    186.3        1343          –      99.0
nginx-tcp-cpu0.45-w1             364.0   47.5   118.1    184.2        1296        162      95.3
nginx-unix-cpu0.45-w1            384.7    1.8   114.5    184.2        1230        115      96.2
```

### Saturação, API com 1.5 CPU — a medição que era impossível

```
config                             rps  ampl%   p50ms    p99ms  API us/req  LB us/req
direto, sem LB (exp. 02)          impossível: esgotava as portas efêmeras
nginx-tcp-cpu1.5-w1              308.7  246.4    57.4    689.3        1310        484
nginx-unix-cpu1.5-w1             903.3    3.9    54.5     74.2        1159         97
```

Valores por repetição — é aqui que a história aparece:

```
nginx-unix   [916.7, 903.3, 881.3, 894.3, 911.5]     <- estável
nginx-tcp    [610.9, 110.9, 110.1, 308.7, 870.8]     <- colapso e recuperação
```

### Taxa fixa de 170 rps (modelo aberto, `--latency-correction`)

```
config                             rps   p50ms    p99ms  API us/req  LB us/req  thr%
nginx-tcp-cpu0.45-w1-170rps      170.2     1.5      2.9        1546        255   0.0
nginx-unix-cpu0.45-w1-170rps     170.3     1.4      2.8        1482        206   0.0
```

---

## 5. Conclusões

### O socket Unix vale 2,9x — e a diferença é estabilidade, não média

A 1.5 CPU: **903,3 rps contra 308,7**. Mas a mediana é a parte menos importante.
Olhe a amplitude: **3,9% contra 246,4%**. A configuração TCP não é "mais lenta";
ela **oscila entre funcionar e não funcionar**, e a mediana de uma série assim
não descreve coisa alguma.

A causa é a mesma diagnosticada no experimento 02: o worker sync do Gunicorn faz
`resp.force_close()` em toda resposta, então o TCP entre nginx e API precisa de
uma conexão nova por requisição. Socket Unix não tem porta nem `TIME_WAIT` — a
classe de falha deixa de existir por construção, não por ajuste.

**A 0.45 CPU a diferença quase some** (384,7 vs 364,0, ou +5,7%). Não é
contradição: é a confirmação do que o experimento 02 já sugeria. O throttling
segura a vazão abaixo do teto de ~470 conexões/s, então o limite de rede nunca é
alcançado. Ainda assim o `nginx-tcp` teve uma repetição em 194,2 rps contra
~364 nas outras — o problema estava lá, apenas mascarado.

> Lição que se repete: **afrouxar um gargalo revela o próximo.** Nunca conclua
> que um limite não existe só porque outro o esconde.

### Acrescentar um salto deixou o sistema mais rápido

Contraintuitivo e vale sublinhar: `nginx-unix` a 0.45 CPU entrega **384,7 rps
contra 351,4 do acesso direto** — mais 9,5%, mesmo pagando um processo a mais e
uma cópia a mais de cada resposta.

O motivo está na coluna `API us/req`: **1343 → 1230 µs**, uma queda de 8,4% no
custo de CPU da própria API. O nginx absorve toda a rotatividade de conexões TCP
com o cliente; a API passa a receber requisições por um socket local barato, sem
pagar `accept`, handshake e fechamento de TCP a cada uma. **A API ficou mais
barata porque parou de fazer trabalho de rede.**

É exatamente o arranjo que o comentário no fonte do Gunicorn descreve — "until
someone shows a buffering proxy". O LB obrigatório da Rinha não é burocracia de
regulamento: é o que torna o worker sync viável.

### O load balancer é barato, e o socket Unix o deixa mais barato ainda

| | LB µs/req | CPU do LB a 903 rps |
| - | - | - |
| socket Unix | **97** | 0,088 de 0,15 cota |
| TCP | 484 | — (série inválida) |

Mesmo na comparação estável de 0.45 CPU, o nginx gasta 115 µs/req com socket
Unix contra 162 com TCP — **29% mais barato**. O socket economiza dos dois lados
do salto, não só do lado da API.

Com 0,15 CPU o nginx nunca foi throttlado. Há espaço para devolver cota ao resto
da stack quando o Postgres chegar.

### O custo da conteinerização não é detectável

Pendência que vinha desde o experimento 02, agora respondível — porque um worker
`sync` é uma thread só e não consegue passar de 1,0 CPU, então a cota de 1.5 não
o limita. As duas medições são comparáveis:

| | rps | p99 |
| - | - | - |
| Experimento 01: host, sem container, sem LB | 875,9 | 63,1ms |
| Experimento 03: container 1.5 CPU + nginx + socket Unix | **903,3** | 74,2ms |

A versão conteinerizada é ~3% **mais rápida**. Ou seja, o overhead do container
existe mas é menor que o ganho trazido pelo nginx — e ambos somados ficam dentro
da margem. Não dá para separar os dois efeitos com estes dados; dá para afirmar
que **conteinerizar não custou vazão perceptível**.

### Throttling continua sendo o interruptor

96% dos períodos throttlados em saturação a 0.45 CPU; **0%** a 1.5 CPU e **0%**
em taxa fixa de 170 rps. Mesma imagem, mesmo binário — muda só a demanda.

E o dado que interessa para a Rinha: a 170 rps (a fatia de uma instância), com
socket Unix, o p99 é de **2,8ms**, com o nginx e a API somando ~0,29 CPU.

---

## 6. Ações decorrentes

- [x] nginx com `access_log off` e `worker_processes 1`.
- [x] Salto nginx→API por socket de domínio Unix, em volume nomeado.
- [x] `bench-stack.sh` coleta `cpu.stat` dos dois cgroups.
- [x] Pendência do exp. 02 resolvida: séries de 1.5 CPU agora são mensuráveis.
- [x] Pendência do exp. 02 resolvida: custo da conteinerização — não detectável.
- [x] Nome do projeto Compose fixado em `rinha-backend-django`.
- [ ] Pendência que continua: bridge vs. host, impossível no Docker Desktop.
- [ ] Experimento 04: Postgres. Só ali a espera de I/O aparece.
- [ ] Experimento 05: workers, sobre a stack completa.
- [ ] Experimento 06: 2 instâncias e a prova com Gatling.

---

## 7. Aprendizados transversais

- **Amplitude antes de mediana.** Uma série com 246% de amplitude não tem
  mediana significativa. `nginx-tcp` "perde por 2,9x" é uma leitura preguiçosa;
  o correto é que ele não funciona de forma previsível.
- **Adicionar uma camada pode acelerar**, quando ela remove trabalho de outra.
- **Socket de domínio Unix é a escolha padrão para salto local** entre processos
  cooperantes: sem portas, sem `TIME_WAIT`, sem handshake, e mais barato em CPU
  dos dois lados.
