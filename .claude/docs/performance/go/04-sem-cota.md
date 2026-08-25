# go/04 — As quatro stacks sem limitação de hardware

O par de [`03`](./03-quatro-stacks-quatro-linguagens.md): a mesma comparação com
a **cota removida**, em 20 vCPU. É onde as diferenças de runtime deixam de ser
mascaradas pelo cgroup — sob 0.40 CPU, uma stack 3x mais rápida só mostra que
espera mais.

Repete o desenho de [`elixir/03`](../elixir/03-sem-cota-varios-nucleos.md), com
o Go entrando como quarto braço.

---

## 1. Ressalvas metodológicas

1. **Fora do regulamento de propósito.** Nada aqui é comparável com a
   competição, que exige 1.5 CPU e 550MB. Serve para responder *"quanto a cota
   está custando?"* e *"o que cada runtime entrega solto?"*.
2. **Commits diferentes**: Django e FastAPI em `ad1bd39`, Elixir em `cc193cf`,
   Go em `9f323bc`. Mesmo rig, mesma duração, mesma concorrência — o critério do
   projeto — mas o mesmo host em dias diferentes.
3. **O gerador de carga divide a máquina com a stack.** Sem cota, `oha` e stack
   disputam as mesmas 20 vCPU, e a partir de certo ponto o teto medido é o do
   conjunto. Os **fatores** sobrevivem; os valores absolutos, não.
4. **A leitura do braço B tem amplitude de 16% no Go.** As duas primeiras
   repetições dão ~25.500 rps e as três últimas ~30.100 — degrau, não dispersão.
   Não foi investigado; provavelmente é o mesmo aquecimento de cache do Postgres
   que [`01`, §5.2](./01-a-aplicacao-sai-da-frente.md) encontrou.
5. **`max_connections = 20` continua valendo**, e é ele que limita o braço B:
   cada stack usa a configuração que chega perto de 16 conexões sem passar.

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

| stack | rps | vs. Django | p50 | p99 | amplitude |
| - | - | - | - | - | - |
| Django + Gunicorn sync | 937,3 | — | 52,73 ms | 69,1 ms | 2,8% |
| FastAPI + uvicorn | 2204,8 | 2,35x | 20,85 ms | 55,7 ms | 2,1% |
| Elixir + Bandit | 2827,5 | 3,02x | 16,16 ms | 32,3 ms | 1,8% |
| **Go + net/http** | **3457,5** | **3,69x** | **13,62 ms** | **24,3 ms** | 5,6% |

### Braço B — máquina inteira

| stack | rps | vs. Django | p50 | p99 |
| - | - | - | - | - |
| Django, 4 workers | 1817,2 | — | 26,94 ms | 37,2 ms |
| FastAPI, 4w pool 4 | 2245,3 | 1,24x | 19,01 ms | 71,3 ms |
| Elixir, auto pool 16 | 2595,9 | 1,43x | 14,94 ms | 55,3 ms |
| **Go, auto pool 16** | **3411,2** | **1,88x** | **12,59 ms** | **36,6 ms** |

**O Go ganha nos dois braços**: 1,22x sobre o Elixir no A e 1,31x no B.

E repete-se o efeito que [`elixir/03`](../elixir/03-sem-cota-varios-nucleos.md)
nomeou: **dar mais paralelismo à escrita não ajuda ninguém**. O Go cai de 3457,5
para 3411,2 e o Elixir de 2827,5 para 2595,9 ao passar de A para B. A bancada
escreve sempre no **mesmo cliente**, e todo `UPDATE` na mesma linha serializa —
*paralelismo não resolve serialização*, a regra que já está em
`04-aprendizados.md`. Só o Django melhora (937 → 1817), porque ali o gargalo era
o próprio processo único, não a linha do banco.

---

## 4. Leitura — `GET /clientes/1/extrato`

### Braço A — um processo

| stack | rps | vs. Django | p50 | p99 |
| - | - | - | - | - |
| Django (ORM) | 757,3 | — | 65,27 ms | 85,7 ms |
| FastAPI | 4546,5 | 6,00x | 3,55 ms | 58,8 ms |
| Elixir | 18294,7 | 24,2x | 2,72 ms | 4,2 ms |
| **Go** | **21994,5** | **29,0x** | **2,09 ms** | **4,1 ms** |

### Braço B — máquina inteira

| stack | rps | vs. Django | p50 | p99 |
| - | - | - | - | - |
| Django, 4 workers | 2682,8 | — | 18,46 ms | 26,2 ms |
| FastAPI, 4w pool 4 | 13710,4 | 5,11x | 2,96 ms | 12,5 ms |
| Elixir, auto pool 16 | 19379,9 | 7,22x | 2,47 ms | 4,6 ms |
| **Go, auto pool 16** | **29942,8** | **11,2x** | **1,56 ms** | **3,5 ms** |

**1,20x sobre o Elixir no braço A e 1,55x no B.** A leitura é paralelizável — não
há contenção de linha — e é onde o braço B compensa: o Go sobe de 22.000 para
quase 30.000 rps.

O p99 conta a história melhor que o rps: **4,1 e 3,5 ms** contra 58,8 e 12,5 do
FastAPI. Sem cota, a diferença entre stacks compiladas/BEAM e CPython aparece na
cauda antes de aparecer na média.

---

## 5. CPU por requisição, sem cota

O cgroup continua sendo lido mesmo sem limite — ele mede consumo, não teto.

| braço | endpoint | API | banco | nginx |
| - | - | - | - | - |
| A (`GOMAXPROCS=1`) | escrita | **210,7 µs** | 426,8 µs | 73,2 µs |
| B (`auto`, 20 núcleos) | escrita | 364,2 µs | 665,4 µs | 79,9 µs |
| A (`GOMAXPROCS=1`) | leitura | **45,8 µs** | 114,2 µs | 31,6 µs |
| B (`auto`, 20 núcleos) | leitura | 136,5 µs | 137,8 µs | 26,4 µs |

**O braço B custa de 1,7x a 3,0x mais CPU por requisição para entregar de 0,99x a
1,36x de vazão.** É o preço do paralelismo, medido: 20 núcleos disputando as
mesmas linhas e o mesmo pool pagam sincronização que uma thread não paga.

E o número da esquerda embaixo é o mais interessante do documento: **45,8 µs por
extrato**. É o único ponto de todo o projeto em que a previsão de
[`django/06`, seção 8](../django/06-tipos-de-worker.md) — *50 a 100 µs* — foi
batida **por baixo**.

---

## 6. O que a cota estava custando

Comparando com o regime da competição
([`03`, §2](./03-quatro-stacks-quatro-linguagens.md)), no braço equivalente:

| endpoint | sob cota (API 0.40) | sem cota (1 processo) | fator |
| - | - | - | - |
| escrita | 1342,3 rps | 3457,5 rps | **2,58x** |
| leitura | 2753,9 rps | 21994,5 rps | **7,99x** |

A cota de 0.40 CPU custa 2,6x na escrita e **8,0x na leitura** — e a diferença
entre os dois fatores é o retrato de onde cada endpoint gasta: a escrita espera o
banco (que também está sob cota), a leitura é quase toda aplicação.

**Nada disso é ganho disponível na competição.** O regulamento é 1.5 CPU
somando tudo, e a stack sob cota já entrega 4x o pico da simulação.

---

## 7. Conclusões

1. **Sem cota, o Go é o mais rápido dos quatro nos dois endpoints e nos dois
   braços** — de 1,20x a 1,55x sobre o Elixir, de 1,57x a 4,84x sobre o FastAPI,
   de 1,88x a 29x sobre o Django.
2. **A vantagem do Go é maior sem cota do que com ela na leitura** (1,20–1,55x
   contra 1,45x) e **menor na escrita** (1,22–1,31x contra 1,53x). Sob cota, o
   que se mede é custo; sem cota, o que se mede é teto — e são coisas diferentes.
3. **Paralelismo continua sem resolver serialização.** Go e Elixir *pioram* na
   escrita ao ganhar a máquina inteira, pelo mesmo motivo de
   [`elixir/03`](../elixir/03-sem-cota-varios-nucleos.md).
4. **A cota custa 8x na leitura e 2,6x na escrita** — e nenhum desses fatores
   está disponível dentro do regulamento.
5. **O CPython é o único que fica para trás por ordem de grandeza na leitura**
   (6,00x atrás do Go no braço A com o mesmo SQL cru), e o Django com ORM,
   por 29x.

---

## 8. Ações decorrentes

- [ ] Investigar o degrau de 16% na leitura do braço B (ressalva 4). Duas
      repetições a 25.500 e três a 30.100 é mecanismo, não dispersão.
- [ ] Re-executar Django e FastAPI no commit atual — as séries deles são de
      `ad1bd39` (ressalva 2).
- [ ] O braço B do Go usa `pool 16` para casar com o Elixir. Não foi medido se
      esse é o pool ótimo para ele.
