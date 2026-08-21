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
| [05 — Hacks da competição](./05-hacks-da-competicao.md) | Atalhos que só se justificam por ser um desafio, não uma aplicação real |

## Estado atual

- [x] Repositório oficial clonado em `rinha-de-backend-2024-q1/` (não modificar)
- [x] Docker funcionando no WSL (Engine 29.6.2, Compose v5.3.1)
- [x] Documentação base
- [x] Decidido: Gatling na versão mais recente (3.14); repositório único (monorepo)
- [x] `git init` na raiz, `.gitignore`, `README.md`, `justfile`
- [x] Esqueleto Django (`django/`): uv + Django 6.1 + Python 3.14.6,
      projeto `kernel`, app `crebitos`
- [x] Modelo de domínio (`crebitos/models.py`): `Cliente`, `Transacao`,
      validações e `UPDATE ... RETURNING` atômico — 38 testes passando
- [x] Hacks isolados em `crebitos/hacks.py` + `.claude/docs/05-hacks-da-competicao.md`
- [x] Endpoints (`crebitos/views.py`, `kernel/urls.py`): Django puro, sem DRF;
      `settings.py` enxugado com os cortes comentados à vista
- [x] Fixture dos 5 clientes + `just dj-setup` / `dj-seed` / `dj-reset` / `dj-verify`
      — 64 testes passando
- [ ] Gatling instalado (`just doctor` acusa ausente)
- [ ] Scripts: `smoke-test.sh`, `rodar-carga.sh`, `check-limites.sh`,
      `pontuacao.py`, `diagnostico.py`, `comparar.py`
- [ ] Infra compartilhada: `infra/nginx/`, `infra/sql/`
- [ ] Dockerfile e compose do projeto Django
- [ ] Primeira execução de carga

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
