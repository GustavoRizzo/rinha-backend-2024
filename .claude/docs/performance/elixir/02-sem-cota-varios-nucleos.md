# elixir/02 — As três implementações sem limitação de hardware

**Documento aberto: a previsão está registrada, a medição ainda não aconteceu.**

Todos os experimentos anteriores deste laboratório mediram sob **cota de
cgroup**, porque é a restrição da competição. Este mede o contrário: as três
implementações soltas numa máquina de 20 vCPU, para responder o que a Rinha
nunca pergunta — *qual delas escala quando há núcleos de sobra?*

Instrumento: só `oha`. Não há prova oficial aqui, porque fora do orçamento de
1.5 CPU não existe pontuação a calcular.

---

## 1. Previsão registrada ANTES de medir

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
