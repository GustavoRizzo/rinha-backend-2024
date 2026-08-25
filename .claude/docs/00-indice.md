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

**Duas implementações, sete experimentos, as duas passando na prova oficial com
pontuação máxima.**

- [x] Documentação base (docs 01 a 05) e diário de aprendizados
- [x] Modelo de domínio, endpoints e 114 testes automatizados (64 no Django,
      50 no FastAPI)
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
- [x] Terceira implementação em Elixir + Bandit + Postgrex: stack de pé em
      1.50 CPU e 550MB, 24 testes verdes, smoke passando — **sem medição
      ainda**. Vocabulário da linguagem e previsões registradas em
      [`performance/elixir/`](./performance/elixir/00-indice.md)

Resultado da configuração final em Django: **100% das requisições abaixo de
250ms**, p98 de 7ms contra um SLA de 250ms, subida em ~20s contra um limite de
40s. O FastAPI repete a pontuação com p98 de 5ms, e custa **1,73x menos CPU na
escrita e 4,00x menos na leitura** — diferença que a pontuação, saturada, não
enxerga.

### O que ficou em aberto

- Comparar o `UPDATE` atômico contra `SELECT FOR UPDATE` (nunca medido)
- Variante com as 10 últimas transações em `JSONB` (hack M5, não implementada)
- `synchronous_commit` como variável medida, não como decisão
- bridge vs. host no Docker: impossível no Docker Desktop
- **Medir o Elixir.** A implementação existe e passa no smoke; nenhuma série de
  bancada foi rodada ainda. Previsões em
  [`performance/elixir/`](./performance/elixir/00-indice.md), seção 4
- Go — previsão registrada em
  [`performance/django/06`](./performance/django/06-tipos-de-worker.md), seção 8.
  A do FastAPI já foi conferida em
  [`performance/fastapi/01`](./performance/fastapi/01-fastapi-async.md): certa na
  escrita, subestimada na leitura
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
