# Rinha de Backend 2024/Q1 — Documentação de estudo

Projeto de aprendizado. A competição encerrou em março/2024; usamos suas regras
como especificação de um exercício sobre teste de carga, concorrência e limitação
de recursos.

## Documentos

| Doc | Conteúdo |
| - | - |
| [01 — Fundamentos](./01-fundamentos.md) | Teoria: teste de carga, open/closed model, percentis, cgroups, controle de concorrência |
| [02 — Regras](./02-regras.md) | Contrato HTTP, arquitetura mínima, restrições, pontuação, o que a simulação testa |
| [03 — Plano de implementação](./03-plano-implementacao.md) | Matriz de variantes, justfile, metodologia de diagnóstico |
| [04 — Aprendizados](./04-aprendizados.md) | Diário técnico do que descobrimos |
| [performance/](./performance/00-indice.md) | Um arquivo por experimento de performance |
| [05 — Hacks da competição](./05-hacks-da-competicao.md) | Atalhos que só se justificam por ser um desafio, não uma aplicação real |

## Estado atual

**Quatro implementações, dezessete experimentos, as quatro passando na prova
oficial com pontuação máxima e zero inconsistências.**

- [x] Documentação base (docs 01 a 05) e diário de aprendizados
- [x] Modelo de domínio, endpoints e 177 testes automatizados (64 no Django,
      50 no FastAPI, 24 no Elixir, 39 no Go)
- [x] Stack completa: nginx + 2 APIs Django/Gunicorn + Postgres, em 1.50 CPU e 550MB
- [x] Ferramental: `oha` 1.15.0 (comparativos rápidos) e Gatling 3.15.1 (prova oficial)
- [x] Scripts de ciclo, bancada, pontuação e validação de limites
- [x] 9 execuções da simulação oficial: **USD 100.000 e zero inconsistências**
- [x] Seis documentos de experimento em [`performance/django/`](./performance/django/00-indice.md)
- [x] Segunda implementação em FastAPI + uvicorn + asyncpg, com bancada
      parametrizada por projeto e três experimentos em
      [`performance/fastapi/`](./performance/fastapi/00-indice.md) — incluindo o
      [fechamento](./performance/fastapi/03-o-que-a-troca-de-framework-comprou.md),
      que separa o que a troca de framework comprou do que não comprou
- [x] Terceira implementação em Elixir + Bandit + Postgrex: **USD 100.000**,
      zero inconsistências, máximo de 51ms, e quatro experimentos em
      [`performance/elixir/`](./performance/elixir/00-indice.md). O
      [04](./performance/elixir/04-o-statement-que-nao-era-reusado.md) derrubou
      a conclusão dos três anteriores: o statement era **replanejado a cada
      requisição**, e corrigido isso o Elixir vira o **mais barato dos três**
- [x] Quarta implementação em Go + `net/http` + `pgx`, com stack, rigs de
      bancada, perfil e suíte própria. O
      [documento de abertura](./performance/go/00-indice.md) registra as
      previsões **antes** de medir — e já derruba a previsão do `GOMAXPROCS`
      com medição do runtime cru
- [x] Prova oficial do Go: **USD 100.000**, zero inconsistências, API a 227 µs
      por requisição (a mais barata das quatro) — e **98,57% abaixo de 250ms**,
      contra ~100% das outras três
- [ ] **Explicar a cauda do Go**: 882 requisições acima de 250ms, todas nos 4
      últimos segundos do teste. Quatro hipóteses com método em
      [`performance/go/00-indice.md`](./performance/go/00-indice.md), seção 7.5
- [x] Bancada do Go ([`performance/go/01`](./performance/go/01-a-aplicacao-sai-da-frente.md)):
      **302,9 µs na escrita e 91–109 µs na leitura**, a mais barata das quatro —
      e o `diag-prepared` refutou o replanejamento de statements (48 planos para
      36.014 chamadas)
- [x] Variantes do Go medidas ([`go/02`](./performance/go/02-tirando-proveito-da-stack.md)):
      a bancada elege `GOMAXPROCS=1` (20% menos CPU/req) e a **prova oficial
      recusa** — mesmo padrão de `fastapi/02`
- [x] Comparativo das quatro stacks [sob cota](./performance/go/03-quatro-stacks-quatro-linguagens.md)
      e [sem cota](./performance/go/04-sem-cota.md), com **contagem de linhas de
      código** (`just codigo`)
- [ ] **Redistribuir a cota com o Go**: a repartição atual foi obtida com uma API
      que custava 862 µs; a de agora custa 303 µs e o banco satura primeiro na
      leitura

**As quatro marcam USD 100.000 e ficam 100% abaixo de 250ms.** O que as separa
é o custo por requisição, que a pontuação saturada não enxerga — medido nas
quatro no mesmo commit (`2b408eb`):

| | Django | FastAPI | Elixir | Go |
| - | - | - | - | - |
| CPU/req, escrita | 856 µs | 512 µs | 444 µs | **323 µs** |
| CPU/req, leitura | 1224 µs | 257 µs | 158 µs | **105 µs** |
| p98 na prova oficial | 7 ms | 5 ms | 5 ms | **4 ms** |
| linhas de código (app+framework) | **289** | 318 | 442 | 688 |

O Go é o mais barato dos quatro e a **primeira stack em que a aplicação sai da
frente**: sob a cota da competição, quem satura é o Postgres (93,5% de períodos
congelados) enquanto a API fica em 0,9% na leitura.

### O que ficou em aberto

- Variante com as 10 últimas transações em `JSONB` (hack M5, não implementada)
- `synchronous_commit` como variável medida, não como decisão
- bridge vs. host no Docker: impossível no Docker Desktop
- Redistribuir a cota entre API e banco no Go: a repartição atual foi calibrada
  com uma API de 862 µs, e a de hoje custa 323 µs — o Postgres é que satura
- Promover a query única do extrato a padrão do FastAPI (1,25x, já com testes
  provando bytes idênticos)
- **Duas amplitudes altas sem explicação**: 51,3% na leitura do Elixir sem cota
  (era 9,0% três dias antes, mesmo comando) e 31,4% na leitura do Go sob cota.
  Pela regra do projeto, amplitude alta é mecanismo a encontrar
- Medir a estratégia otimista com a carga **espalhada** entre os 5 clientes: a
  bancada bate sempre no cliente 1, o pior caso possível para ela
  ([`go/05`](./performance/go/05-bloco-b-estrategias-de-concorrencia.md))
- Portar as quatro estratégias de concorrência para o FastAPI, para saber se os
  fatores se mantêm quando a aplicação é 1,6x mais cara

## Referência rápida

```
Contrato:    POST /clientes/{id}/transacoes  -> 200 {limite, saldo} | 422 | 404
             GET  /clientes/{id}/extrato     -> 200 {saldo, ultimas_transacoes} | 404
Arquitetura: LB round-robin :9999 + 2 APIs + 1 banco persistente
Limites:     1.5 CPU e 550MB somados entre TODOS os serviços
Carga:       4 min, pico ~340 req/s (220 débitos + 110 créditos + 10 extratos)
SLA:         p98 < 250ms; multa (98 - %) x USD 1.000
Consistência: multa USD 803,01 por inconsistência detectada
Clientes:    1..5 (limites 100000/80000/1000000/10000000/500000, saldo 0); id 6 -> 404
```
