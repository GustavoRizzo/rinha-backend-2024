# elixir/02 — Quanto cada serviço fica ocioso na carga real

Pergunta: *a repartição de cota (nginx 0.10, API 0.40 × 2, banco 0.60) é a certa
para a stack Elixir?* Ela foi herdada do FastAPI, e o experimento
[`01`](./01-a-beam-sob-cota.md) mostrou que os dois endpoints desta stack têm
gargalos **opostos** — a escrita congela a API, a leitura congela o banco.
Parecia um caso claro de redistribuir.

Resposta medida: **não há o que redistribuir.** Na carga da Rinha, nenhum
serviço passa de 42% da própria cota e o throttling é praticamente zero. A
tensão que a bancada mostrou **não existe** no regime que a competição impõe.

Este experimento também estreia o instrumento que faltava: a coleta de
`cpu.stat` por serviço **durante a prova oficial**.

---

## 1. Ressalvas metodológicas

> ⚠️ **Os números desta página são ANTERIORES à correção do experimento
> [04](./04-o-statement-que-nao-era-reusado.md).** O Postgrex estava
> replanejando cada statement a cada requisição — um bug de configuração, não
> uma propriedade da linguagem. Com a correção, o custo de banco cai até 3,97x e
> **as conclusões comparativas desta página se invertem**. A página fica como
> está, com o commit medido ao lado de cada número: é registro do que foi
> medido, não do que é verdade hoje.


1. **Uma execução.** Os percentuais de ocupação são estáveis o bastante para a
   conclusão qualitativa ("ninguém satura"), mas os valores exatos não foram
   repetidos.
2. **É um delta de duas fotos**, tiradas antes e imediatamente depois da
   simulação. Ele inclui os poucos segundos entre o fim da carga e a segunda
   leitura, o que **superestima levemente** a CPU ociosa contabilizada — o viés
   vai contra a conclusão, não a favor dela.
3. **`cpu_us_por_request` aqui é média ponderada dos dois endpoints**, porque a
   carga oficial mistura débitos, créditos e extratos. Não é comparável direto
   com os números da bancada em [`01`](./01-a-beam-sob-cota.md), que isolam um
   endpoint por série.
4. **A ocupação depende da carga, e a carga é fixa.** A conclusão vale para os
   ~250 req/s da simulação oficial. Ela não diz nada sobre o que aconteceria com
   o dobro da carga — e é justamente isso que a bancada mede.

---

## 2. Ambiente e commit

| | |
| - | - |
| commit medido | `84f0cae` |
| execução | `resultados/elixir/20260825T134236` |
| stack | Elixir + Bandit + Postgrex, 1.50 CPU e 550MB |
| carga | Gatling 3.15.1, simulação oficial, 61.503 requisições em ~4 min |
| instrumento novo | `scripts/cgroup-snapshot.sh` + bloco `cgroup` em `metadata.json` |

---

## 3. Comandos para replicar

```bash
just run elixir                      # a coleta de cpu.stat agora é parte do ciclo
python3 -c "import json; print(json.load(open('resultados/elixir/<ts>/metadata.json'))['cgroup'])"
```

---

## 4. Resultados

### 4.1 Ocupação por serviço, na carga oficial

A coluna que responde a pergunta é **% da cota**: quanto da CPU reservada o
serviço realmente usou nos ~240 segundos de carga.

| serviço | cota | CPU usada | µs/req | **% da cota** | períodos congelados |
| - | - | - | - | - | - |
| api01 | 0.40 | 22,16 s | 360,2 | **23,0%** | **0,0%** (0 de 2408) |
| api02 | 0.40 | 22,32 s | 363,0 | **23,2%** | **0,0%** (0 de 2401) |
| db | 0.60 | 29,83 s | 485,1 | **20,5%** | 0,1% (2 de 2423) |
| nginx | 0.10 | 9,97 s | 162,1 | **41,7%** | 0,1% (3 de 2389) |

Total consumido: **84,3 s de CPU** ao longo de ~240 s, com 1,5 CPU disponível —
ou seja, **23% do orçamento**. Mais de três quartos da cota ficou parada.

### 4.2 A prova oficial desta execução

| | |
| - | - |
| Pontuação | **USD 100.000** |
| Abaixo de 250ms | 100,000% |
| p50 / p98 / p99 | 2ms / **5ms** / 6ms |
| Máximo | **91 ms** |
| Inconsistências | zero |
| Subida | 7s |

Segunda execução da stack Elixir, e ela repete o resultado: máximo de 91ms
contra os 101ms da primeira, e p98 de 5ms contra 6ms.

---

## 5. Conclusões

### 5.1 Não redistribuir. Não há gargalo a aliviar

Um serviço só se beneficia de mais cota se estiver **batendo** na que tem. Aqui
o mais ocupado (nginx) usa 42% da sua, e as APIs — que na bancada congelavam em
94% dos períodos — ficam em 23% com **zero** períodos congelados.

Mover CPU de um serviço ocioso para outro serviço ocioso não muda nada. E mover
para longe de alguém que hoje tem folga é o que
[`fastapi/02`](../fastapi/02-onde-esta-o-gargalo.md) mediu e a prova oficial
recusou: a folga não é desperdício, é o amortecedor da cauda.

**Ação: a repartição fica como está.** Pela primeira vez neste laboratório essa
decisão tem um número de carga real por trás, e não uma extrapolação de
saturação.

### 5.2 A tensão entre os dois endpoints era um artefato da saturação

O experimento [`01`](./01-a-beam-sob-cota.md) mostrou a escrita congelando a API
(94,3%) e a leitura congelando o banco (94,4%) — gargalos opostos, que pareciam
tornar impossível uma repartição boa para os dois.

Na carga real, os dois números viram **0,0% e 0,1%**. A tensão existe apenas
onde a bancada opera, que é acima do que a Rinha pede. É mais uma instância da
regra já registrada: *otimização medida em saturação não se transfere
automaticamente para a carga real* — e agora com a recíproca, que é nova:
**problema medido em saturação também não se transfere**.

### 5.3 O gargalo da Rinha não é CPU nenhuma

Com 23% do orçamento usado, p98 de 5ms contra um SLA de 250ms e zero
throttling, a conclusão é que **esta stack está superdimensionada para a carga
da competição** — e, pelas medições anteriores, as outras duas também.

Isso reforça o que o laboratório vem repetindo por outro caminho: a pontuação
satura porque o problema é fácil para qualquer implementação competente. O que
distingue as implementações é o **teto** — quanto elas aguentariam — e teto só
se mede com a bancada, nunca com a prova.

### 5.4 O que o nginx custa

162 µs por requisição, o serviço proporcionalmente mais carregado da stack. Vale
guardar o número: em [`django/06`](../django/06-tipos-de-worker.md) ele foi
medido em ~110 µs, e ele **não depende da linguagem da API** — é o mesmo binário
nos três projetos. Se a aplicação continuar barateando, o load balancer passa a
ser uma fração crescente do custo total.

---

## 6. Ações decorrentes

- [x] `scripts/cgroup-snapshot.sh` e o bloco `cgroup` no `metadata.json`: a
      prova oficial agora mede consumo por serviço, não só o limite declarado.
- [x] **Decisão: a repartição 0.10 / 0.40 × 2 / 0.60 fica**, agora com carga
      real por trás.
- [ ] Rodar `just run` do Django e do FastAPI com o instrumento novo, para ter a
      mesma tabela nas três stacks. É barato e fecha a comparação.
- [ ] O achado dos 479 µs de CPU de banco de [`01`](./01-a-beam-sob-cota.md)
      continua aberto — e note que na carga real o banco custa 485,1 µs/req,
      **consistente com a bancada**. Ou seja: o custo é real e não é artefato de
      saturação.
