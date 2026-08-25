# fastapi/02 — Onde está o gargalo, e como repartir 1.5 CPU

Responde à pergunta que o [experimento 01](./01-fastapi-async.md) deixou aberta:
com a API custando 1,73x menos CPU na escrita e 4,00x menos na leitura, o
gargalo migrou para o Postgres, como a previsão de
[`django/06`](../django/06-tipos-de-worker.md) dizia que migraria?

---

## 1. Ressalvas metodológicas

### 1.1 A varredura de diagnóstico ESTOURA o orçamento da Rinha, de propósito

**Leia isto antes de olhar qualquer tabela da seção 4.1 e 4.2.**

O rig de bancada (`compose.bench-postgres.yml`) tem **uma** instância de API, e
a varredura chega a dar **1.60 CPU só para ela** — mais de 2.3 CPU somando os
três serviços, contra um orçamento de 1.5. **Nenhuma linha daquelas tabelas é
uma configuração válida para a competição.** Elas existem para localizar a
parede: qual serviço para de dar conta primeiro, e a partir de que ponto.

A pergunta legítima da competição — **como repartir 1.5 CPU entre nginx, duas
APIs e o banco** — é respondida só na seção 4.3, em que todas as linhas somam
exatamente 1.50 CPU e 550MB, medidas na stack de produção com as duas
instâncias.

Para que esse erro não volte por descuido, o rig `producao` **aborta** quando a
repartição estoura o orçamento (`PERFIL_ORCAMENTO=1` em
`scripts/perfis/fastapi.sh`). Um número ótimo e ilegal contamina a tabela
inteira: depois não dá mais para saber qual linha podia existir.

### 1.2 Throttling alto não prova gargalo

Este experimento cometeu e corrigiu esse erro dentro dele mesmo — ver seção 5.2.
A porcentagem de períodos congelados diz que um serviço está **saturando a sua
cota**, não que ele seja o **limite do sistema**. A prova de gargalo é
operacional: **solte a cota daquele serviço e veja se a vazão sobe.** Se não
subir, ele não era a parede.

### 1.3 O resto

- **Não mede pontuação.** As duas implementações já marcam o teto de USD
  100.000 com 35x–50x de folga no SLA. Nada aqui muda isso; o que muda é o teto
  de vazão. A carga da Rinha tem pico de ~340 req/s, e **todas** as
  configurações medidas aqui ficam muito acima disso.
- **`oha` não é o Gatling.** Números das duas ferramentas nunca devem ser
  comparados. Ver `04-aprendizados.md`.
- **Saturação, não taxa fixa.** Modelo fechado, concorrência 50. Mede teto, não
  latência sob carga realista.
- **O gerador de carga divide a máquina com a stack.** Em vazões acima de
  ~3.000 rps, parte do custo medido pode ser disputa com o próprio `oha` — mais
  um motivo para não ler as linhas de leitura como teto absoluto.

---

## 2. Ambiente e commit

| Item | Valor |
| - | - |
| Commit | `1997e19` (diagnóstico), `420c644` (repartições), `PROVA` (provas oficiais) |
| Host | 20 vCPU, 31GB, kernel 6.6.87.2-microsoft-standard-WSL2 |
| Gerador de carga | `oha` 1.15.0, 10s, 5 repetições, aquecimento descartado, concorrência 50 |
| Aplicação | FastAPI 0.141.1 + uvicorn 0.52.4 (uvloop/httptools) + asyncpg 0.31.0 |
| Banco | Postgres 18-alpine, `synchronous_commit = off`, `max_connections = 20` |
| Variantes | validação manual, extrato em query única, orjson (os padrões desde o experimento 01) |

---

## 3. Comandos para replicar

```bash
# diagnóstico: varre a cota da API com o banco fixo em 0.6 (FORA do orçamento)
export BENCH_PROJETO=fastapi BENCH_TAG=gargalo
for c in 0.40 0.80 1.20 1.60; do
    BENCH_ENDPOINT=transacoes bash scripts/bench-stack.sh postgres $c 1 10s 5
done

# confirmação: solta a cota do serviço acusado e vê se a vazão sobe
BENCH_TAG=gargalo-db0.90 DB_CPUS=0.90 BENCH_ENDPOINT=transacoes \
    bash scripts/bench-stack.sh postgres 0.80 1 10s 5
BENCH_TAG=gargalo-lb0.40 LB_CPUS=0.40 BENCH_ENDPOINT=extrato \
    bash scripts/bench-stack.sh postgres 0.80 1 10s 5

# repartições DENTRO do orçamento, na stack de produção (2 APIs)
BENCH_TAG=r-atual                    bash scripts/bench-stack.sh producao 0.40 1 10s 5
DB_CPUS=0.80 BENCH_TAG=r-maisbanco   bash scripts/bench-stack.sh producao 0.30 1 10s 5
DB_CPUS=0.90 BENCH_TAG=r-bancolimite bash scripts/bench-stack.sh producao 0.25 1 10s 5
LB_CPUS=0.20 BENCH_TAG=r-maisnginx   bash scripts/bench-stack.sh producao 0.35 1 10s 5

# a tabela
python3 scripts/bench-tabela.py resultados/bench gargalo
python3 scripts/bench-tabela.py resultados/bench r-
```

---

## 4. Resultados

### 4.1 Diagnóstico — escrita, variando a cota da API (FORA do orçamento)

Banco fixo em 0.6, nginx em 0.15, **uma** instância de API.

| cota da API | rps | µs/req API | **API congelada** | µs/req banco | **banco congelado** |
| - | - | - | - | - | - |
| 0.40 | 826 | 498,9 | **94,3%** | 485,2 | 1,9% |
| 0.80 | 1351 | 467,2 | 0,9% | 455,4 | **94,3%** |
| 1.20 | 1376 | 468,2 | 0,0% | 446,4 | **92,6%** |
| 1.60 | 1364 | 469,0 | 0,0% | 449,5 | **94,3%** |

**O gargalo vira de lado entre 0.40 e 0.80.** Dobrar a cota rende 1,64x;
quadruplicar rende 1,65x — de 0.80 em diante a API deixa de ser o limite.

### 4.2 Confirmação — soltando a cota do serviço acusado

| configuração | rps | vs. base | API congelada | banco congelado | nginx congelado |
| - | - | - | - | - | - |
| escrita, API 0.80, banco **0.60** | 1351 | — | 0,9% | **94,3%** | 2,8% |
| escrita, API 0.80, banco **0.90** | **1856** | **1,37x** | 91,7% | 4,8% | 3,7% |
| escrita, API 0.80, banco **1.20** | 1836 | 1,36x | 92,6% | 0,0% | 3,7% |
| leitura, API 0.80, nginx **0.15** | 3553 | — | 44,4% | 6,7% | **87,2%** |
| leitura, API 0.80, nginx **0.40** | 3643 | **1,03x** | 91,7% | 7,7% | 0,0% |

Duas leituras opostas, e é o contraste entre elas que dá a regra:

- **O banco ERA a parede na escrita.** Soltar 0.60 → 0.90 rendeu 1,37x, e o
  gargalo voltou para a API (91,7% congelada). De 0.90 para 1.20 não rendeu mais
  nada — o banco deixou de ser o limite.
- **O nginx NÃO era a parede na leitura**, apesar de congelar em 87% dos
  períodos. Soltá-lo de 0.15 para 0.40 rendeu **2,6%**, dentro do ruído.

### 4.3 Repartições DENTRO do orçamento — a tabela que vale

Stack de produção completa, **duas** instâncias de API, todas as linhas somando
exatamente **1.50 CPU e 550MB**. A coluna "API" é a soma dos dois cgroups.

| repartição | nginx | api (cada) | banco |
| - | - | - | - |
| `r-atual` (herdada do Django) | 0.10 | 0.40 | 0.60 |
| `r-maisbanco` | 0.10 | 0.30 | 0.80 |
| `r-bancolimite` | 0.10 | 0.25 | 0.90 |
| `r-maisnginx` | 0.20 | 0.35 | 0.60 |

**Escrita — `POST /clientes/1/transacoes`**

| repartição | rps | ampl% | vs. atual | API congelada | banco congelado | nginx congelado |
| - | - | - | - | - | - | - |
| `r-atual` | 664,1 | 9,0 | — | 0,0% | **93,5%** | 7,1% |
| **`r-maisbanco`** | **1021,9** | 2,0 | **1,54x** | 63,7% | 57,4% | 7,2% |
| `r-bancolimite` | 806,6 | 7,2 | 1,21x | **68,8%** | 0,9% | 7,2% |
| `r-maisnginx` | 664,5 | 5,2 | 1,00x | 0,0% | **94,4%** | 0,0% |

**Leitura — `GET /clientes/1/extrato`**

| repartição | rps | ampl% | vs. atual | API congelada | banco congelado | nginx congelado |
| - | - | - | - | - | - | - |
| `r-atual` | 1437,4 | **27,9** | — | 0,4% | 3,8% | **96,5%** |
| `r-maisbanco` | 1506,6 | 6,4 | 1,05x | 7,6% | 0,0% | **97,4%** |
| `r-bancolimite` | 1798,9 | **17,1** | 1,25x | **86,0%** | 0,0% | 23,9% |
| **`r-maisnginx`** | **2561,0** | 8,6 | **1,78x** | 68,6% | 8,5% | 1,9% |

⚠️ **As amplitudes da leitura são altas** — 27,9% em `r-atual` e 17,1% em
`r-bancolimite`, muito acima do limiar de ~3% deste projeto. A diferença entre
`r-atual` e `r-maisbanco` (4,9%) **não é atribuível**: está dentro do ruído. Já
o ganho de `r-maisnginx` (78%) é grande demais para ser ruído. Pela regra do
projeto, amplitude alta é mecanismo pedindo para ser encontrado, e este ficou
por encontrar.

---

## 5. Conclusões

### 5.1 A repartição herdada do Django é a PIOR para escrita

`r-atual` — nginx 0.10, API 0.40 × 2, banco 0.60 — é a distribuição que os
experimentos `django/04` e `django/05` chegaram, e que o projeto FastAPI copiou
para manter *uma variável por vez*. Copiar foi certo; **mantê-la seria errado**.

Com a API custando 1,73x menos CPU por escrita, ela sobra: em `r-atual` a API
não congela em **nenhum** período, enquanto o banco congela em **93,5%**. A cota
está no serviço que não precisa dela. Mover 0.20 CPU das APIs para o banco
(`r-maisbanco`) rende **1,54x** na escrita, com amplitude de 2,0%.

**A previsão de `django/06` se confirma, e dentro do orçamento**: *"a troca de
linguagem moveria o gargalo da aplicação para o banco"*. Moveu — e a correção é
redistribuir a cota, não comprar mais CPU.

### 5.2 O erro que este experimento cometeu: throttling não é gargalo

Na varredura de diagnóstico (4.1/4.2), vi o nginx congelando em 87–93% dos
períodos na leitura e **afirmei que o gargalo tinha migrado para ele**. A série
de confirmação derrubou isso: soltar o nginx de 0.15 para 0.40 rendeu **2,6%**,
dentro do ruído. Ele estava saturando a própria cota sem ser o limite do
sistema.

**Regra derivada, que vale além deste experimento**: a porcentagem de períodos
congelados diz que um serviço **satura a sua cota**, não que ele seja a
**parede**. A prova é operacional — solte a cota daquele serviço e veja se a
vazão sobe. Se não subir, ele não era o gargalo.

Ironia útil: na stack de produção, com **duas** APIs batendo num nginx de 0.10,
ele **é** a parede na leitura (`r-maisnginx` rende 1,78x). Ou seja, a conclusão
que eu tirei cedo demais estava certa por acidente num cenário diferente
daquele em que a tirei. Um palpite que acerta pelo motivo errado é pior que
errar: ele passa despercebido.

### 5.3 A repartição ótima depende do endpoint — e a carga decide

| | melhor repartição | ganho |
| - | - | - |
| escrita | `r-maisbanco` (banco 0.80) | 1,54x |
| leitura | `r-maisnginx` (nginx 0.20) | 1,78x |

As duas são incompatíveis: uma tira das APIs para dar ao banco, a outra tira
para dar ao nginx. **A carga da Rinha decide**: 330 req/s de escrita contra 10
req/s de extrato — **97% da carga é escrita**. Pelo critério da competição,
`r-maisbanco` é a escolha.

**O que NÃO foi medido**: uma repartição mista (por exemplo nginx 0.20, API 0.30
× 2, banco 0.70). As quatro linhas variam uma coisa por vez em relação à atual,
e a combinação das duas melhorias é uma hipótese não testada — não uma
recomendação.

### 5.4 A prova oficial RECUSOU a repartição que a bancada elegeu

Este é o achado mais importante do experimento, e ele contradiz a seção 5.1.

Adotei `r-maisbanco` como padrão (banco 0.80, APIs 0.30 cada) e rodei a
simulação oficial. **Duas execuções**, para não concluir de uma só:

| | banco 0.60, APIs 0.40 | banco 0.80, APIs 0.30 | banco 0.80, APIs 0.30 |
| - | - | - | - |
| execução | `20260824T144338` | `20260825T001412` | `20260825T001929` |
| abaixo de 250ms | **100,000%** | 99,961% | 99,961% |
| requisições acima de 250ms | **0** | **24** | **24** |
| p98 | **5 ms** | 6 ms | 6 ms |
| p99 | **6 ms** | 8 ms | 9 ms |
| máximo | **246 ms** | 315 ms | 340 ms |
| pontuação | 100.000 | 100.000 | 100.000 |

A repartição que rende **1,54x na bancada** entrega uma cauda **pior** na carga
real. E não é ruído: as duas execuções deram exatamente **24** requisições acima
do SLA — número idêntico, o que aponta para causa sistemática, não dispersão.

**Por que as duas medições discordam.** Elas respondem perguntas diferentes:

| | `oha` | Gatling |
| - | - | - |
| pergunta | quanto cabe? | como se comporta no que chega? |
| carga | **saturação** (concorrência 50, sem folga) | ~340 req/s, o que a Rinha aplica |
| métrica | vazão e CPU por requisição | percentis de latência |

Sob saturação, cota parada nas APIs é desperdício e o banco é a parede. Sob 340
req/s, **nada satura** — e aí a folga das APIs deixa de ser desperdício e passa
a ser o que absorve os picos. Tirar 0.20 CPU delas não custou vazão (que sobra),
custou cauda (que é o que o SLA mede).

**Decisão: o padrão volta para banco 0.60 e APIs 0.40 cada.** A repartição
`r-maisbanco` fica documentada como a escolha certa para quem for limitado por
vazão — que a Rinha não é.

**Regra derivada**: *otimização medida em saturação não se transfere
automaticamente para a carga real.* Se o sistema não satura no uso previsto, a
folga não é desperdício: é o amortecedor da cauda. Vale além deste projeto.

**O que ficou por investigar**: as 24 requisições, idênticas nas duas execuções.
Número reprodutível é mecanismo, não dispersão — provavelmente a fase de subida
da rampa. Não foi caçado.

### 5.5 Nada disso muda a pontuação

O pico da simulação é **~340 req/s**. A pior repartição medida aqui entrega
**664 rps de escrita** — quase o dobro do pico, medindo só escrita, com uma
carga de saturação que a Rinha não aplica. Todas as quatro passam com folga, e
a stack já marcou USD 100.000 com a repartição *pior* das quatro.

**O valor deste experimento não é a nota, é saber onde está a parede** — e
descobrir que ela se mudou de lugar quando a aplicação ficou mais barata.

---

## 6. A melhor execução do projeto

Para quem quiser citar um número só, é este — e é o da repartição **antiga**,
que a prova oficial preferiu:

> **`resultados/fastapi/20260824T144338`** — FastAPI + uvicorn + asyncpg, nginx
> + 2 APIs + Postgres em **1.50 CPU e 550MB**:
>
> | | |
> | - | - |
> | Pontuação | **USD 100.000** (máxima) |
> | Requisições | 61.503 em 4 minutos |
> | Abaixo de 250ms | **100,000%** — nenhuma exceção |
> | p50 / p98 / p99 | **2ms / 5ms / 6ms** |
> | Máximo | 246 ms |
> | Inconsistências de saldo | **zero** |
> | Requisições com falha | **zero** |
> | Subida da stack | **7s** (limite: 40s) |
> | Commit | `2fad4bb` |

**As ressalvas que precisam viajar junto com esses números**, porque sem elas
eles enganam:

1. **A pontuação satura.** A stack Django também marca USD 100.000. O SLA exige
   98% abaixo de 250ms e o p98 ficou em 5ms — **50x de folga**. Nesse regime,
   qualquer implementação competente tira nota máxima, e comparar notas não diz
   nada. É por isso que este projeto usa o `oha` para comparar e o Gatling só
   para aprovar.
2. **O máximo de 246ms encostou no limite.** O SLA é 250ms; uma requisição
   passou a 4ms de custar dinheiro. As execuções em Django tiveram máximos
   melhores (76ms e 94ms). "100% abaixo de 250ms" é verdade e é apertado.
3. **A máquina é mais folgada que a oficial**: 20 vCPU contra 4, e aqui o
   gerador de carga não disputa CPU com a aplicação. **Estes números não são
   comparáveis com o ranking oficial da Rinha.**
4. **A competição encerrou em março de 2024.** Isto é um exercício de estudo,
   não uma submissão.

## 7. Ações decorrentes

- [x] Rig `producao` (2 APIs) com **trava de orçamento**: repartição que estoura
      1.5 CPU ou 550MB aborta em vez de virar linha de tabela.
- [x] Bancada coleta o cgroup do banco e soma os das duas APIs.
- [x] **`r-maisbanco` testado na prova oficial e REJEITADO**: 1,54x na bancada,
      cauda pior na carga real, em duas execuções. O padrão fica em banco 0.60 e
      APIs 0.40.
- [ ] Medir a repartição mista (nginx 0.20, API 0.30 × 2, banco 0.70), que
      combina os dois ganhos e não foi testada.
- [ ] Investigar a amplitude de 27,9% na leitura com `r-atual`. Amplitude alta
      não é ruído a mediar: é mecanismo a encontrar.
- [ ] Caçar as **24 requisições** acima de 250ms, idênticas nas duas execuções
      com banco 0.80. Número reprodutível é mecanismo.
- [ ] Repetir a varredura de repartições no **Django**: se o gargalo dele ainda
      é a aplicação, a repartição ótima é outra — e isso testaria se `r-atual`
      é de fato a melhor para ele, ou só a que foi encontrada primeiro.
