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

**Os seis experimentos estão concluídos.** A stack passa na prova oficial com
pontuação máxima.

- [x] Documentação base (docs 01 a 05) e diário de aprendizados
- [x] Modelo de domínio, endpoints e 64 testes automatizados
- [x] Stack completa: nginx + 2 APIs Django/Gunicorn + Postgres, em 1.50 CPU e 550MB
- [x] Ferramental: `oha` 1.15.0 (comparativos rápidos) e Gatling 3.15.1 (prova oficial)
- [x] Scripts de ciclo, bancada, pontuação e validação de limites
- [x] 9 execuções da simulação oficial: **USD 100.000 e zero inconsistências**
- [x] Seis documentos de experimento em [`performance/`](./performance/00-indice.md)

Resultado da configuração final: **100% das requisições abaixo de 250ms**, p98
de 7ms contra um SLA de 250ms, subida em ~20s contra um limite de 40s.

### O que ficou em aberto

- Comparar o `UPDATE` atômico contra `SELECT FOR UPDATE` (nunca medido)
- Variante com as 10 últimas transações em `JSONB` (hack M5, não implementada)
- `synchronous_commit` como variável medida, não como decisão
- bridge vs. host no Docker: impossível no Docker Desktop
- Outras linguagens/frameworks — previsões registradas em
  [`performance/06`](./performance/06-tipos-de-worker.md), seção 8

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
