# elixir/03 — As três implementações sem limitação de hardware

**Resultado curto:** na leitura com um processo por stack, o Elixir entrega
**2,06x** o FastAPI e um p99 **8,4x melhor** — a previsão do usuário estava
certa, e com folga. Mas dando quatro workers ao FastAPI a vantagem **inverte**,
e na escrita ela nunca existiu, porque a escrita da bancada **não é
paralelizável**: todas disputam a mesma linha.

A frase que resume as quatro tabelas: **o Elixir escala melhor e gasta mais.**

Todos os experimentos anteriores deste laboratório mediram sob **cota de
cgroup**, porque é a restrição da competição. Este mede o contrário: as três
implementações soltas numa máquina de 20 vCPU, para responder o que a Rinha
nunca pergunta — *qual delas escala quando há núcleos de sobra?*

Instrumento: só `oha`. Não há prova oficial aqui, porque fora do orçamento de
1.5 CPU não existe pontuação a calcular.

---

## 1. Previsão registrada ANTES de medir

> ⚠️ **Os números desta página são ANTERIORES à correção do experimento
> [04](./04-o-statement-que-nao-era-reusado.md).** O Postgrex estava
> replanejando cada statement a cada requisição — um bug de configuração, não
> uma propriedade da linguagem. Com a correção, o custo de banco cai até 3,97x e
> **as conclusões comparativas desta página se invertem**. A página fica como
> está, com o commit medido ao lado de cada número: é registro do que foi
> medido, não do que é verdade hoje.


**Do usuário, 2026-08-25, antes de existir qualquer série:**

> "Dai sim com vários núcleos, eu prevejo que o Elixir vai se destacar
> bastante."

É uma previsão em sentido **oposto** ao resultado de
[`01`](./01-a-beam-sob-cota.md), em que o Elixir ficou 9,8% mais caro que o
FastAPI na escrita. A hipótese implícita, e o que a torna interessante: aquela
derrota aconteceu num regime — 0.40 CPU, um scheduler — em que a principal
vantagem da BEAM estava desligada por construção. Com 20 núcleos, um único nó
Elixir usa a máquina inteira, enquanto um processo CPython usa um núcleo.

**Previsão do Claude, mesma data, para ficar no mesmo placar:**

1. **Com um processo por implementação, o Elixir ganha por larga margem** — é o
   único dos três que paraleliza dentro do processo. Não é mérito de runtime
   rápido, é ausência de GIL.
2. **Com cada uma configurada para usar a máquina inteira** (Django e FastAPI
   com vários workers, Elixir com `SCHEDULERS=auto`), **a diferença encolhe
   muito**, e o vencedor passa a ser decidido pelo Postgres, não pela aplicação.
3. **O gargalo vira o banco nos três casos**, e o experimento corre o risco de
   medir o `postgresql.conf` em vez das aplicações. Se isso acontecer, é
   resultado, não fracasso — mas precisa ser dito antes.
4. **O custo de CPU por requisição vai PIORAR nos três** em relação às séries
   sob cota. Já foi medido para o Elixir em [`01`](./01-a-beam-sob-cota.md):
   `SCHEDULERS=auto` sem cota custou 1087,8 µs contra 502,7 µs com um
   scheduler. Paralelismo compra vazão pagando em eficiência.

---

## 2. Ressalvas que já valem, antes do primeiro número

1. **O gerador de carga disputa a mesma máquina.** Sob cota isso importava
   pouco: a stack estava presa em 1.5 CPU e sobravam 18 vCPU para o `oha`. Sem
   cota, aplicação e gerador brigam pelos mesmos 20 núcleos, e **a medição passa
   a incluir essa briga**. É a maior limitação deste experimento.
2. **`max_connections = 20`.** O `infra/postgres/postgresql.conf` é compartilhado
   pelas três stacks, e mudá-lo mudaria a base de comparação de todos os
   experimentos anteriores. Isso limita quantos workers e que tamanho de pool
   cada braço pode usar, e a restrição **não cai igual** nos três: um worker
   síncrono do Django usa 1 conexão, um worker do FastAPI usa um pool inteiro, e
   o Elixir usa um pool só para o nó inteiro.
3. **Sem cota, "µs de CPU por requisição" e "rps" contam histórias
   diferentes.** Sob cgroup, vazão era consequência (cota ÷ custo) e bastava uma
   métrica. Aqui as duas precisam ser lidas juntas: um braço pode ganhar em rps
   **gastando mais** CPU por requisição, e foi exatamente o que
   `SCHEDULERS=auto` fez em [`01`](./01-a-beam-sob-cota.md).
4. **Isto está fora do regulamento da Rinha** e não gera pontuação. Não use
   estes números para falar da competição.


---

## 3. Ambiente e commit

| | |
| - | - |
| commit medido | `ad1bd39` (árvore limpa em todas as séries) |
| host | 20 vCPU, WSL2 |
| rig | `postgres-sem-limite` nos três projetos: nginx + 1 API + banco, **sem `deploy.resources`** |
| bancada | `oha` 1.15.0, 10s, concorrência 50, 5 repetições + aquecimento descartado |
| Elixir | `SCHEDULERS=auto` nos dois braços — sob cota ele seria 1, aqui são 20 |

A coluna **núcleos** é derivada: `rps × µs/req ÷ 10⁶`. Ela diz quantos núcleos
aquela camada manteve ocupados em média, e é ela que torna o mecanismo visível
em vez de inferido.

## 4. Comandos para replicar

```bash
just bench-sem-cota      # os dois braços, 12 séries
just bench-tabela
```

## 5. Números crus

#### A / transacoes

| stack | rps | ampl% | µs/req API | µs/req banco | núcleos API | núcleos banco | p99 ms |
| - | - | - | - | - | - | - | - |
| Django + gunicorn sync, 1 worker | 937.3 | 2.8 | 773.5 | 335.2 | 0.72 | 0.31 | 69.1 |
| FastAPI + uvicorn, 1 worker | 2204.8 | 2.1 | 440.9 | 415.4 | 0.97 | 0.92 | 55.7 |
| Elixir, 1 nó (schedulers auto) | 1955.0 | 2.0 | 1025.8 | 613.3 | 2.01 | 1.20 | 46.3 |

#### A / extrato

| stack | rps | ampl% | µs/req API | µs/req banco | núcleos API | núcleos banco | p99 ms |
| - | - | - | - | - | - | - | - |
| Django + gunicorn sync, 1 worker | 757.3 | 2.1 | 1102.2 | 272.3 | 0.83 | 0.21 | 85.7 |
| FastAPI + uvicorn, 1 worker | 4546.5 | 2.1 | 221.8 | 138.3 | 1.01 | 0.63 | 58.8 |
| Elixir, 1 nó (schedulers auto) | 9383.5 | 4.4 | 620.5 | 479.5 | 5.82 | 4.50 | 7.0 |

#### B / transacoes

| stack | rps | ampl% | µs/req API | µs/req banco | núcleos API | núcleos banco | p99 ms |
| - | - | - | - | - | - | - | - |
| Django + gunicorn sync, 4 workers | 1817.2 | 5.2 | 922.8 | 421.0 | 1.68 | 0.77 | 37.2 |
| FastAPI, 4 workers x pool 4 | 2245.3 | 0.4 | 592.1 | 746.0 | 1.33 | 1.68 | 71.3 |
| Elixir, 1 nó, pool 16 | 1743.0 | 1.6 | 1104.9 | 923.2 | 1.93 | 1.61 | 90.6 |

#### B / extrato

| stack | rps | ampl% | µs/req API | µs/req banco | núcleos API | núcleos banco | p99 ms |
| - | - | - | - | - | - | - | - |
| Django + gunicorn sync, 4 workers | 2682.8 | 3.8 | 1214.5 | 294.1 | 3.26 | 0.79 | 26.2 |
| FastAPI, 4 workers x pool 4 | 13710.4 | 4.4 | 291.4 | 192.7 | 4.00 | 2.64 | 12.5 |
| Elixir, 1 nó, pool 16 | 11756.1 | 45.2 | 522.5 | 544.6 | 6.14 | 6.40 | 7.2 |

---

## 6. Conclusões

### 6.1 A previsão do usuário está certa — na leitura, com um processo

9383,5 rps contra 4546,5 do FastAPI: **2,06x**. E o p99 vai de 58,8ms para
**7,0ms**, uma diferença de **8,4x** que é maior que a de vazão.

A coluna de núcleos mostra o mecanismo sem deixar margem para interpretação:

| | núcleos que a API manteve ocupados |
| - | - |
| Django, 1 worker | 0,83 |
| FastAPI, 1 worker | **1,01** |
| Elixir, 1 nó | **5,82** |

**1,01 núcleo é o GIL, medido.** Um processo CPython satura exatamente um
núcleo e para ali, por mais máquina que exista embaixo. O nó da BEAM espalhou
por 5,82 sem nenhuma configuração especial — é o único dos três que paraleliza
**dentro** do processo.

Vale ser preciso sobre o que isso é e o que não é: **não é eficiência, é
paralelismo.** O Elixir gastou 620,5 µs de CPU por requisição contra 221,8 do
FastAPI — quase **3x mais caro**. Ele ganhou porque tinha 20 núcleos e usou 6, e
o adversário estava algemado a 1.

### 6.2 Na escrita a vantagem não existe, e a razão não é a linguagem

FastAPI 2204,8 contra Elixir 1955,0 no braço A: o Python **ganha** por 12,8%,
com um processo só, mesmo com o Elixir usando 2,01 núcleos contra 0,97.

A explicação está na bancada, não nos runtimes: `bench-stack.sh` escreve
**sempre no mesmo cliente**, de propósito, porque é o pior caso de contenção da
Rinha. Todas as escritas disputam **uma linha** do Postgres, e `UPDATE` na mesma
linha serializa. Paralelismo não resolve serialização.

Nesse regime o que decide é quem faz o round-trip mais barato, e aí o Elixir
perde pelo mesmo motivo que perdia sob cota. Ele só recupera na **cauda**: p99
de 46,3ms contra 55,7ms.

### 6.3 Dando processos ao Python, a vantagem inverte

| leitura | braço A (1 processo) | braço B (máquina inteira) |
| - | - | - |
| FastAPI | 4546,5 | **13710,4** |
| Elixir | **9383,5** | 11756,1 |
| razão | Elixir **2,06x** à frente | Elixir **0,86x** — 14% atrás |

O FastAPI multiplicou por 3,02 ao ganhar 4 workers; o Elixir cresceu 1,25x ao
ganhar pool maior. E o custo explica: no braço B o FastAPI ocupa **4,00 núcleos
exatos** (quatro processos saturados) para entregar 13710, enquanto o Elixir
precisa de **6,14** para entregar 11756.

**A leitura honesta:** o teto do FastAPI aqui não é o runtime, é o número de
workers que eu dei a ele. Com 8 ou 16 workers ele iria mais longe — o Elixir já
estava usando a máquina toda no braço A. O que este braço mede não é "quem é
mais rápido", é **quanto de máquina cada um consegue usar por processo**, e a
resposta é que o Python compra escala com processos e o Elixir vem com ela de
fábrica.

Minha previsão nº 2 (a diferença encolhe no braço B) acertou; a nº 1 (o Elixir
ganha por larga margem no braço A) acertou na leitura e **errou na escrita**.

### 6.4 A cauda é do Elixir nos quatro cenários

| | Django | FastAPI | **Elixir** |
| - | - | - | - |
| escrita A | 69,1 | 55,7 | **46,3** |
| escrita B | 37,2 | 71,3 | 90,6 |
| leitura A | 85,7 | 58,8 | **7,0** |
| leitura B | 26,2 | 12,5 | **7,2** |

Três dos quatro, e no braço B da escrita ele é o pior. A previsão nº 4 do índice
— *a vantagem da BEAM aparece na cauda* — se sustenta na leitura, com 7,0ms
contra 58,8ms, e **não** se sustenta na escrita sob contenção de linha única.

Isso é coerente: o escalonamento preemptivo protege contra uma requisição
monopolizar o scheduler. Ele não protege contra uma **linha do banco**
monopolizar todo mundo.

### 6.5 O custo extra continua sendo do banco

Em todas as oito linhas, o Elixir gasta mais CPU **de Postgres** por requisição
que o FastAPI, com o SQL idêntico:

| | FastAPI | Elixir | fator |
| - | - | - | - |
| escrita A | 415,4 | 613,3 | 1,48x |
| escrita B | 746,0 | 923,2 | 1,24x |
| leitura A | 138,3 | 479,5 | **3,47x** |
| leitura B | 192,7 | 544,6 | 2,83x |

Sob cota o mesmo padrão apareceu (1,36x na escrita, 2,71x na leitura), e na
carga real do Gatling também. **É sistemático, atravessa os dois endpoints, os
dois regimes e as duas configurações.** Continua sendo o achado em aberto mais
importante do projeto Elixir, e o único cuja causa ainda não foi medida.

### 6.6 A cota estava cobrando caro do Elixir, e barato do FastAPI

Comparando cada um consigo mesmo, com e sem cota, na escrita:

| | com cota (0.40) | sem cota | |
| - | - | - | - |
| FastAPI | 499,7 µs | **440,9 µs** | a cota custa 13% |
| Elixir | 548,5 µs | **1025,8 µs** | soltar a cota custa **1,87x** |

A previsão nº 4 do documento — *o custo por requisição vai piorar nos três* —
acertou no Elixir e **errou no FastAPI**, que ficou mais barato ao sair da cota.
O motivo é o congelamento: um processo throttlado paga trocas de contexto que
não produzem trabalho. Já o Elixir piora porque, solto, sobe 20 schedulers — o
mesmo efeito medido em [`01`](./01-a-beam-sob-cota.md), seção 5.2.

---

## 7. Ressalva que este experimento não conseguiu eliminar

**A amplitude de 45,2% do Elixir na leitura do braço B.** Pela regra do projeto,
amplitude alta não é ruído a mediar: é mecanismo a encontrar. Aquela linha
específica não deve ser citada sem esta ressalva junto. É a segunda vez que a
leitura do Elixir com query única apresenta amplitude alta (28,8% sob cota, em
[`01`](./01-a-beam-sob-cota.md)), o que sugere que o mecanismo é o mesmo — e
possivelmente o mesmo dos 3,47x de CPU de banco.

## 8. Ações decorrentes

- [x] Os dois braços medidos, nos três projetos, nos dois endpoints.
- [ ] **Medir o FastAPI com 8 e 16 workers.** O braço B parou em 4 por causa de
      `max_connections = 20`, e a conclusão 6.3 depende de saber onde ele para
      de verdade. Exige um override de `postgresql.conf` só para este
      experimento, declarado como tal.
- [ ] **Uma série de escrita distribuída entre os 5 clientes**, em vez de todas
      no cliente 1. É o teste que separa "o Elixir não escala na escrita" de "a
      escrita desta bancada não é paralelizável". Hoje não dá para distinguir.
- [ ] Perseguir a amplitude de 45,2% e os 3,47x de CPU de banco — provavelmente
      o mesmo mecanismo.
