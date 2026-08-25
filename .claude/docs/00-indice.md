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

**Quatro implementações, doze experimentos. As quatro marcam USD 100.000 na
prova oficial com zero inconsistências — mas a do Go, recém-nascida, entrega a
pior cauda das quatro e ainda não passou pela bancada.**

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
- [ ] Bancada do Go: `just diag-prepared go` primeiro, depois as séries

Resultado da configuração final em Django: **100% das requisições abaixo de
250ms**, p98 de 7ms contra um SLA de 250ms, subida em ~20s contra um limite de
40s. O FastAPI repete a pontuação com p98 de 5ms, e custa **1,73x menos CPU na
escrita e 4,00x menos na leitura** — diferença que a pontuação, saturada, não
enxerga. O Elixir repete a pontuação com p98 de 5ms e o **melhor máximo das
três (51ms)**, e depois da correção do
[`elixir/04`](./performance/elixir/04-o-statement-que-nao-era-reusado.md) é o
mais barato por requisição: 462 µs na escrita e 158 µs na leitura.

### O que ficou em aberto

- Comparar o `UPDATE` atômico contra `SELECT FOR UPDATE` (nunca medido)
- Variante com as 10 últimas transações em `JSONB` (hack M5, não implementada)
- `synchronous_commit` como variável medida, não como decisão
- bridge vs. host no Docker: impossível no Docker Desktop
- **Rodar `just diag-prepared django`**: o Django usa psycopg com SQL cru e
  ninguém conferiu se ele reusa statements. Se não reusar, parte dos 862 µs da
  escrita e dos 1258 µs da leitura é o mesmo problema do
  [`elixir/04`](./performance/elixir/04-o-statement-que-nao-era-reusado.md)
- **Medir o Go.** A implementação existe e passa nos 39 testes; nenhum número de
  desempenho foi levantado. A previsão de
  [`performance/django/06`](./performance/django/06-tipos-de-worker.md), seção 8
  (50–100 µs/req) está registrada em
  [`performance/go/00-indice.md`](./performance/go/00-indice.md), seção 6, junto
  com as deste projeto
- Redistribuir a cota entre API e banco agora que a API ficou mais barata — é o
  teste que responde se o gargalo migrou para o Postgres
- Promover a query única do extrato a padrão do FastAPI (1,25x, já com testes
  provando bytes idênticos)

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
