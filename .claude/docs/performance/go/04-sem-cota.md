# go/04 — As quatro stacks sem limitação de hardware

O par de [`03`](./03-quatro-stacks-quatro-linguagens.md): a mesma comparação com
a **cota removida**, em 20 vCPU. É onde as diferenças de runtime deixam de ser
mascaradas pelo cgroup — sob 0.40 CPU, uma stack 3x mais rápida só mostra que
espera mais.

Repete o desenho de [`elixir/03`](../elixir/03-sem-cota-varios-nucleos.md), com
o Go entrando como quarto braço.

> **Versão 2 deste documento.** A primeira comparava séries de quatro commits
> diferentes, e a ressalva 2 daquela versão pedia a re-execução. **As dezesseis
> séries foram refeitas no commit `2b408eb`**, todas no mesmo dia e no mesmo
> host. Os números mudaram pouco (a maior diferença é 11% no Elixir da leitura,
> onde a amplitude é 51%), e as conclusões não mudaram nenhuma.

---

## 1. Ressalvas metodológicas

1. **Fora do regulamento de propósito.** Nada aqui é comparável com a
   competição, que exige 1.5 CPU e 550MB. Serve para responder *"quanto a cota
   está custando?"* e *"o que cada runtime entrega solto?"*.
2. **O gerador de carga divide a máquina com a stack.** Sem cota, `oha` e stack
   disputam as mesmas 20 vCPU, e a partir de certo ponto o teto medido é o do
   conjunto. Os **fatores** sobrevivem; os valores absolutos, não.
3. **Duas séries têm amplitude alta demais para o número valer sozinho**: o
   Elixir na leitura do braço A (**51,3%**) e o FastAPI na leitura do mesmo
   braço (24,7%). Nos dois casos o fator contra o Go é grande o bastante para
   sobreviver à dispersão, mas a mediana deles não deve ser citada como valor.
4. **`max_connections = 20` continua valendo**, e é ele que limita o braço B:
   cada stack usa a configuração que chega perto de 16 conexões sem passar.
5. **A CPU por requisição sem cota mede consumo, não custo mínimo.** Um runtime
   que ocupa 20 núcleos gasta mais CPU por requisição do que o mesmo runtime
   restrito a um — e isso aparece nas tabelas, não é erro.

---

## 2. Os dois braços, e por que são dois

| braço | pergunta | Django | FastAPI | Elixir | Go |
| - | - | - | - | - | - |
| **A** | *um processo, sem cota* | 1 worker sync | 1 uvicorn | `SCHEDULERS=auto` | `GOMAXPROCS=1` |
| **B** | *a máquina inteira* | 4 workers | 4 workers, pool 4 | auto, pool 16 | `GOMAXPROCS=auto`, pool 16 |

O braço A isola o custo por requisição do runtime; o B mede o que cada um faz
quando pode usar os 20 núcleos. **Os dois braços do Go são também os dois braços
de `GOMAXPROCS`** — sem cota, `auto` são os 20 núcleos, e não o piso de 2 do
regime da competição ([`00`, §7.1](./00-indice.md)).

---

## 3. Escrita — `POST /clientes/1/transacoes`

### Braço A — um processo

| stack | rps | vs. Django | p50 | p99 | CPU da API | CPU do banco |
| - | - | - | - | - | - | - |
| Django + Gunicorn sync | 928,4 | — | 53,27 ms | 70,5 ms | 782,9 µs | 343,1 µs |
| FastAPI + uvicorn | 2210,8 | 2,38x | 20,89 ms | 56,2 ms | 439,7 µs | 416,6 µs |
| Elixir + Bandit | 2762,2 | 2,98x | 16,47 ms | 33,0 ms | 888,0 µs | 457,6 µs |
| **Go + net/http** | **3589,4** | **3,87x** | **12,87 ms** | **23,9 ms** | **202,6 µs** | 412,9 µs |

### Braço B — máquina inteira

| stack | rps | vs. Django | p50 | p99 | CPU da API | CPU do banco |
| - | - | - | - | - | - | - |
| Django, 4 workers | 1620,0 | — | 30,26 ms | 48,4 ms | 1044,5 µs | 457,8 µs |
| FastAPI, 4w pool 4 | 1989,7 | 1,23x | 22,39 ms | 76,0 ms | 687,0 µs | 832,8 µs |
| Elixir, auto pool 16 | 2459,3 | 1,52x | 15,99 ms | 57,7 ms | 989,3 µs | 775,2 µs |
| **Go, auto pool 16** | **3427,6** | **2,12x** | **12,48 ms** | **36,2 ms** | **361,7 µs** | 664,0 µs |

**O Go ganha nos dois braços**: 1,30x sobre o Elixir no A e 1,39x no B.

E repete-se o efeito que [`elixir/03`](../elixir/03-sem-cota-varios-nucleos.md)
nomeou: **dar mais paralelismo à escrita não ajuda ninguém**. Go, Elixir e
FastAPI *pioram* de A para B (3589 → 3428, 2762 → 2459, 2211 → 1990). A bancada
escreve sempre no **mesmo cliente**, e todo `UPDATE` na mesma linha serializa —
*paralelismo não resolve serialização*. Só o Django melhora (928 → 1620), porque
ali o gargalo era o próprio processo único, não a linha do banco.

---

## 4. Leitura — `GET /clientes/1/extrato`

### Braço A — um processo

| stack | rps | vs. Django | p50 | p99 | CPU da API | CPU do banco |
| - | - | - | - | - | - | - |
| Django (ORM) | 767,5 | — | 64,44 ms | 85,3 ms | 1084,4 µs | 274,0 µs |
| FastAPI | 4410,2 ⚠️ | 5,75x | 4,09 ms | 58,8 ms | 228,5 µs | 165,2 µs |
| Elixir | 16453,6 ⚠️ | 21,4x | 2,92 ms | 5,9 ms | 433,7 µs | 162,4 µs |
| **Go** | **21737,2** | **28,3x** | **2,14 ms** | **4,1 ms** | **46,3 µs** | **114,6 µs** |

⚠️ amplitude de 24,7% (FastAPI) e **51,3%** (Elixir) — ver ressalva 3.

### Braço B — máquina inteira

| stack | rps | vs. Django | p50 | p99 | CPU da API | CPU do banco |
| - | - | - | - | - | - | - |
| Django, 4 workers | 2607,2 | — | 18,87 ms | 26,7 ms | 1249,2 µs | 304,5 µs |
| FastAPI, 4w pool 4 | 13355,1 | 5,12x | 3,05 ms | 13,2 ms | 298,0 µs | 196,3 µs |
| Elixir, auto pool 16 | 19161,1 | 7,35x | 2,48 ms | 4,8 ms | 377,0 µs | 157,5 µs |
| **Go, auto pool 16** | **29600,8** | **11,4x** | **1,58 ms** | **3,5 ms** | **139,1 µs** | **141,5 µs** |

**1,32x sobre o Elixir no braço A e 1,54x no B.** A leitura é paralelizável — não
há contenção de linha — e é onde o braço B compensa: o Go sobe de 21.700 para
quase 29.600 rps.

O p99 conta a história melhor que o rps: **4,1 e 3,5 ms** contra 58,8 e 13,2 do
FastAPI. Sem cota, a diferença entre stacks compiladas/BEAM e CPython aparece na
cauda antes de aparecer na média.

---

## 5. A leitura que só a coluna de CPU permite

Os `µs/req` sem cota dizem uma coisa que o rps esconde:

| braço A, escrita | rps | CPU da API |
| - | - | - |
| Elixir (`SCHEDULERS=auto`) | 2762,2 | **888,0 µs** |
| Go (`GOMAXPROCS=1`) | 3589,4 | **202,6 µs** |

**O Elixir gasta 4,4x mais CPU por requisição para entregar 1,30x menos.** Não é
defeito da BEAM: é `SCHEDULERS=auto` numa máquina de 20 núcleos, exatamente o
que [`elixir/01`](../elixir/01-a-beam-sob-cota.md) mediu (*"sem cota, `auto`
custa 2,16x mais CPU por requisição para 4,4% mais vazão"*). O braço A do Elixir
é o braço **paralelo**; o do Go é o **serial**. Os dois são legítimos, e a
comparação de CPU entre eles não é.

O mesmo efeito, dentro do Go: `GOMAXPROCS=1` custa 202,6 µs e `auto` custa 361,7
— **1,79x mais CPU para 0,95x da vazão**. É o preço do paralelismo, medido na
mesma stack, sem trocar nada mais.

E isso confirma, sem cota, a conclusão que [`02`](./02-tirando-proveito-da-stack.md)
tirou sob cota: **paralelismo custa CPU por requisição em toda parte; o que muda
é se há folga para pagar**.

---

## 6. O que a cota estava custando

Comparando com o regime da competição
([`03`, §2](./03-quatro-stacks-quatro-linguagens.md)), no braço equivalente:

| endpoint | sob cota (API 0.40) | sem cota (1 processo) | fator |
| - | - | - | - |
| escrita | 1262,4 rps | 3589,4 rps | **2,84x** |
| leitura | 2971,8 rps | 21737,2 rps | **7,31x** |

A cota de 0.40 CPU custa 2,8x na escrita e **7,3x na leitura** — e a diferença
entre os dois fatores é o retrato de onde cada endpoint gasta: a escrita espera o
banco (que também está sob cota), a leitura é quase toda aplicação.

**Nada disso é ganho disponível na competição.** O regulamento é 1.5 CPU
somando tudo, e a stack sob cota já entrega 4x o pico da simulação.

---

## 7. Conclusões

1. **Sem cota, o Go é o mais rápido dos quatro nos dois endpoints e nos dois
   braços** — de 1,30x a 1,54x sobre o Elixir, de 1,62x a 4,93x sobre o FastAPI,
   de 2,12x a 28,3x sobre o Django.
2. **E é o mais barato por requisição em todos eles**, com margem que vai de
   2,2x a 9,4x sobre o segundo colocado de cada linha.
3. **Paralelismo continua sem resolver serialização.** Go, Elixir e FastAPI
   pioram na escrita ao ganhar a máquina inteira; só o Django melhora, e só
   porque o gargalo dele era o processo único.
4. **A cota custa 7,3x na leitura e 2,8x na escrita** — e nenhum desses fatores
   está disponível dentro do regulamento.
5. **O CPython fica para trás por ordem de grandeza na leitura** (5,75x atrás do
   Go no braço A com o mesmo SQL cru), e o Django com ORM, por 28x.

---

## 8. Ações decorrentes

- [x] Re-executar as dezesseis séries no mesmo commit — feito, `2b408eb`.
- [ ] Investigar a amplitude de 51,3% do Elixir na leitura do braço A. Era 9,0%
      na versão anterior deste documento, com o mesmo comando: alguma coisa
      mudou no host ou no ferramental entre as duas medições.
- [ ] O braço B do Go usa `pool 16` para casar com o Elixir. Não foi medido se
      esse é o pool ótimo para ele.
