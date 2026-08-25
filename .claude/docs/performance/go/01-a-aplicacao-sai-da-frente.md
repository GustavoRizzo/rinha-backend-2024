# go/01 — A aplicação sai da frente, e o banco vira a parede

Primeiro experimento do projeto Go. Ele responde à previsão de
[`django/06`, seção 8](../django/06-tipos-de-worker.md) — *50 a 100 µs por
requisição, 8 a 17x menos que o Django* — e encontra, no caminho, o mecanismo
que a previsão de [`fastapi/03`, §4.5](../fastapi/03-o-que-a-troca-de-framework-comprou.md)
anunciou: **baratear a aplicação não elimina o gargalo, transfere-o**.

---

## 1. Ressalvas metodológicas

1. **A série canônica da leitura foi executada três vezes, e as três discordam
   entre si** — medianas de 2918,8, 3707,4 e 2753,9 rps para a *mesma*
   configuração e o *mesmo* commit. A seção 5 mostra que a causa é o banco
   saturado, mas isso significa que **nenhum número de leitura sob 0.6 CPU vale
   como valor absoluto**; o que vale é a comparação entre braços e a forma da
   variação.
2. **O slug da série não codifica `DB_CPUS`.** O braço com o banco em 2 CPU
   (seção 5.2) sobrescreveu o JSON do braço canônico, que precisou ser
   re-executado. É a mesma limitação de ferramental que
   [`elixir/04`](../elixir/04-o-statement-que-nao-era-reusado.md) deixou em
   aberto para o commit, agora com uma segunda dimensão perdida. Os números do
   braço de 2 CPU sobrevivem **apenas neste texto**.
3. **A escrita e a leitura não têm a mesma qualidade de medição.** A escrita tem
   1,77% de amplitude entre repetições e é confiável; a leitura tem 27,9% a
   48,6% e é um diagnóstico, não uma medida.
4. **O `oha` satura a stack de propósito** (modelo fechado, concorrência 50). Os
   rps daqui não dizem nada sobre a carga da competição, que pede 340 rps.
5. **As séries do Django, do FastAPI e do Elixir não foram re-executadas.** Elas
   continuam nos commits em que foram medidas. Rig, cota, endpoint e duração são
   os mesmos, que é o critério do projeto — mas é o mesmo host num dia diferente.

---

## 2. Ambiente e commit

| | |
| - | - |
| commit | `1e9f7e6` |
| Go / pgx | 1.27.0 / v5.10.0 |
| rig | `go/compose.bench-postgres.yml` — nginx + 1 API + Postgres |
| cota | API 0.40 CPU, banco 0.60 CPU, nginx 0.15 CPU |
| ferramenta | `oha` 1.15.0, 10s, concorrência 50, 5 repetições, aquecimento descartado |
| estado | 50 transações por cliente, reposto entre repetições |

---

## 3. Comandos para replicar

```bash
just diag-prepared go extrato       # a hipótese herdada do elixir/04
just diag-prepared go transacoes
just bench-go transacoes 0.40       # a série confiável
just bench-go extrato 0.40          # a série instável — rode mais de uma vez
DB_CPUS=2 just bench-go extrato 0.40 # o braço que decide a seção 5
```

---

## 4. Os statements são reusados — hipótese refutada com medição

A conferência no fonte já dizia isso (`pgx@v5.10.0/conn.go:191`, registrado em
[`00`, §7.2](./00-indice.md)), mas o [`elixir/04`](../elixir/04-o-statement-que-nao-era-reusado.md)
custou dois documentos exatamente por adiar a medição que estava disponível.

| endpoint | `calls` | `plans` | planos/chamada | % do tempo planejando |
| - | - | - | - | - |
| extrato | 36.014 | **48** | 0,001 | **0,5%** |
| transações (`UPDATE`) | 13.266 | **48** | 0,004 | **0,0%** |
| transações (`INSERT`) | 13.264 | **48** | 0,004 | 0,3% |

Os 48 são o preparo inicial por conexão, não por requisição. Para efeito de
comparação, o Elixir antes da correção marcava `plans = calls` — 9.122 para
9.122 — e 62,2% do tempo de banco planejando.

**A armadilha nº 2 da seção 5 de [`00`](./00-indice.md) não existe nesta stack.**

---

## 5. O resultado principal: onde o gargalo está em cada endpoint

### 5.1 Escrita — a aplicação ainda é a parede, e ficou 1,53x mais barata

| | CPU da API | CPU do banco | rps | amplitude |
| - | - | - | - | - |
| Django + Gunicorn + psycopg | 862,4 µs | — | 483,9 | 4,8–5,3% |
| FastAPI + uvicorn + asyncpg | 498,9 µs | 485,2 µs | 826,0 | 1,3–2,1% |
| Elixir + Bandit + Postgrex | 462,5 µs | 484,7 µs | 892,9 | — |
| **Go + net/http + pgx** | **302,9 µs** | **461,4 µs** | **1342,3** | **1,8%** |

**1,53x mais barato que o Elixir, 1,65x que o FastAPI, 2,85x que o Django.** A
API fica com 91,5% dos períodos congelados e o banco com 89,8%: os dois estão
saturados, mas é a API que limita — dar cota a ela é o que moveria o número.

O custo de banco caiu também (461,4 contra 484,7 do Elixir e 485,2 do FastAPI),
mas **3–5% está no ruído das outras duas séries** e não sustenta afirmação: o
esperado, e o que a tabela mostra, é que três drivers executando o mesmo SQL
preparado no mesmo Postgres custem o mesmo.

### 5.2 Leitura — o banco vira a parede, e é ele que produz a instabilidade

| | CPU da API | CPU do banco | rps | throttling do banco |
| - | - | - | - | - |
| Django (ORM) | 1257,9 µs | — | 334,9 | — |
| FastAPI | 256,1 µs | — | 1601,9 | — |
| Elixir | 157,9 µs | 120,7 µs | 2610,4 | **0,0%** |
| **Go** | **91,0–109,1 µs** | 165,9–224,5 µs | 2753,9–3707,4 | **93,5%** |

A API do Go é **1,45x a 1,74x mais barata que a do Elixir** e nem chega a
esquentar: 0,9% de períodos congelados contra 93,5% do banco. **O gargalo da
leitura não está na aplicação.**

E é essa saturação que produz a amplitude que a seção 1 registra. O braço de
controle:

| banco | rps (mediana) | amplitude | CPU da API | CPU do banco | throttling do banco |
| - | - | - | - | - | - |
| **0.60 CPU** (canônico) | 2753,9–3707,4 | **27,9–48,6%** | 108,7 µs | 224,5 µs | **93,6%** |
| **2.00 CPU** (controle) | **3832,9** | **9,1%** | 91,3 µs | 164,3 µs | **0,0%** |

Dar cota ao banco derruba a amplitude de 27,9% para 9,1%, zera o throttling e
sobe a vazão. **A instabilidade era do banco espremido, não da aplicação** — e a
API, que antes aparecia com 108,7 µs, revela seus 91,3 µs reais quando para de
esperar por um banco congelado.

Duas leituras que valem além deste experimento:

- **O `nr_throttled` por serviço decidiu em um braço o que três execuções da
  série não decidiram.** É a regra do `CLAUDE.md` — *olhar `nr_throttled` por
  serviço antes de culpar a aplicação* — se pagando pela terceira vez.
- **A previsão de [`fastapi/03`, §4.5](../fastapi/03-o-que-a-troca-de-framework-comprou.md)
  se confirmou na leitura**: o gargalo não foi eliminado, mudou de elo. No
  Elixir ele ainda estava na API (banco a 0,0% de throttling); no Go está no
  Postgres.

### 5.3 A previsão de `django/06` errou, e errou como o próprio documento previu

| | previsto | medido | veredito |
| - | - | - | - |
| escrita | 50–100 µs | **302,9 µs** | **errado por 3x a 6x** |
| leitura | 50–100 µs | **91,0–109,1 µs** | **certo** |
| vs. Django (escrita) | 8–17x | **2,85x** | errado |
| vs. Django (leitura) | 8–17x | **11,5x a 13,8x** | **certo** |
| pontuação | 100.000 | 100.000 | certo |

A faixa acertou o endpoint em que a aplicação faz pouco (montar JSON a partir de
uma string que o Postgres já entregou pronta) e errou o endpoint em que ela paga
uma transação de banco com dois statements. A previsão nº 2 registrada em
[`00`, §6](./00-indice.md) — escrita acima da faixa, leitura dentro dela — está
**certa**, e pelo motivo que ela deu: `BEGIN`, `UPDATE`, `INSERT`, `COMMIT` não
ficam mais baratos porque a aplicação é compilada.

---

## 6. Conclusões

1. **O Go é a implementação mais barata das quatro nos dois endpoints.** 1,53x
   sobre o Elixir na escrita, 1,45–1,74x na leitura, e 2,85x/11,5x+ sobre o
   Django.
2. **E isso importa menos do que parece.** A competição pede 340 rps; a stack
   entrega 1342 na escrita com uma única instância de API sob 0.40 CPU. Toda a
   vazão extra é folga que o teste nunca pede — a conclusão de
   [`fastapi/03`, §4.3](../fastapi/03-o-que-a-troca-de-framework-comprou.md),
   agora com outra linguagem.
3. **O gargalo da leitura mudou de elo pela primeira vez neste laboratório de
   verdade.** O `elixir/01` achou que tinha mudado, e o `04` mostrou que era um
   bug. Aqui os statements estão reusados (seção 4), a API está ociosa e o banco
   está congelado 93,5% do tempo. **Redistribuir a cota deixou de ser
   curiosidade e virou o próximo experimento.**
4. **A instabilidade tem dono.** 48,6% de amplitude não era ruído a mediar: era
   um banco a 0.6 CPU. A regra do projeto se pagou de novo.

---

## 7. Ações decorrentes

- [ ] **Redistribuir a cota** com o Go: a repartição atual (nginx 0.10, API 0.40
      × 2, banco 0.60) foi obtida com o Django, cuja API custava 862 µs. Com uma
      API de 303 µs, o experimento `E3` do
      [plano](../../03-plano-implementacao.md) deixa de ser hipotético.
- [ ] **Explicar a cauda da prova oficial** — 882 requisições acima de 250ms,
      todas nos 4 últimos segundos ([`00`, §7.5](./00-indice.md)). Nada neste
      experimento a explica: sob bancada o p99 fica em 94–97ms e estável.
- [ ] **Comparar o custo de banco da leitura entre Go e Elixir** com o mesmo
      instrumento de diagnóstico. 165,9–224,5 µs contra 120,7 µs merece
      verificação, e a diferença pode ser inteiramente efeito da saturação — o
      braço de 2 CPU baixou para 164,3 µs sem mudar uma linha de SQL.
- [ ] **Fazer o slug da série codificar `DB_CPUS`** (ressalva 2). Duas dimensões
      já se perderam por isso.
- [ ] Rodar as variantes: `GOMAXPROCS=1`, `EXTRATO_QUERY=duas`,
      `SERIALIZACAO=stdlib`, `GOMEMLIMIT`. Nenhuma foi exercitada.
