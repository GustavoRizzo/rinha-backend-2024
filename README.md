# Rinha de Backend 2024/Q1 — laboratório de estudo

Implementações da [Rinha de Backend 2024/Q1](https://github.com/zanfranceschi/rinha-de-backend-2024-q1)
em diferentes stacks, comparadas sob as mesmas restrições de recursos.

A competição encerrou em março de 2024. **Este repositório não é uma submissão** —
é um laboratório pessoal para estudar teste de carga, controle de concorrência e
limitação de recursos, usando as regras da Rinha como especificação.

## O desafio, em uma tela

Uma API de créditos e débitos ("crébitos") com dois endpoints:

```
POST /clientes/{id}/transacoes   -> 200 {limite, saldo} | 422 | 404
GET  /clientes/{id}/extrato      -> 200 {saldo, ultimas_transacoes} | 404
```

Sob as seguintes restrições:

| | |
| - | - |
| **Arquitetura** | Load balancer round-robin na porta 9999 + 2 instâncias de API + 1 banco persistente |
| **Recursos** | 1.5 CPU e 550MB somados entre **todos** os serviços |
| **Carga** | 4 minutos, pico de ~340 req/s (220 débitos + 110 créditos + 10 extratos) |
| **SLA** | p98 < 250ms — multa de `(98 - %sucesso) × USD 1.000` |
| **Consistência** | multa de `USD 803,01` por inconsistência de saldo detectada |

Só existem **5 clientes**, o que concentra toda a carga em 5 linhas do banco. A
dificuldade não é vazão — é manter correção absoluta sob contenção máxima.

## Documentação

O material de estudo está em [`.claude/docs/`](./.claude/docs/):

| Doc | Conteúdo |
| - | - |
| [00 — Índice](./.claude/docs/00-indice.md) | Estado do projeto e referência rápida |
| [01 — Fundamentos](./.claude/docs/01-fundamentos.md) | Teste de carga, open/closed model, percentis, cgroups, concorrência |
| [02 — Regras](./.claude/docs/02-regras.md) | Contrato HTTP, restrições, pontuação, o que a simulação testa |
| [03 — Plano](./.claude/docs/03-plano-implementacao.md) | Matriz de variantes, justfile, metodologia de diagnóstico |
| [04 — Aprendizados](./.claude/docs/04-aprendizados.md) | Diário técnico e decisões tomadas |

## Estrutura

```
.
├─ .claude/docs/              documentação de estudo
├─ rinha-de-backend-2024-q1/  repo oficial (gitignored, read-only)
├─ infra/                     nginx e SQL compartilhados entre projetos
├─ django/                    implementação Django
├─ resultados/                metadados das execuções
├─ scripts/                   smoke test e coleta de métricas
└─ justfile                   comandos
```

Cada pasta de topo é um **projeto** (uma stack). Dentro dele, **variantes** são
overrides de compose — `django` + `sqlite`, `django` + `raw-sql` — em vez de
pastas duplicadas.

## Uso

```bash
just                          # lista os comandos disponíveis
just run django               # sobe, valida, roda a carga e derruba
just run django sqlite        # mesma coisa com o override de SQLite
just compare django-orm django-raw-sql
```

## Requisitos

- Docker Engine + Compose v2
- [`just`](https://github.com/casey/just)
- [`uv`](https://docs.astral.sh/uv/) (projetos Python)
- JDK 17+ e [Gatling](https://gatling.io/open-source/) (versão mais recente)

## Status

Em construção. Ver [o índice](./.claude/docs/00-indice.md) para o estado atual.

## Créditos

Desafio original por [@zanfranceschi](https://github.com/zanfranceschi).
