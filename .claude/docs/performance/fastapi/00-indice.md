# Testes de performance — FastAPI

Índice geral em [../00-indice.md](../00-indice.md). A numeração reinicia aqui:
o experimento 01 do FastAPI **não** é continuação do 06 do Django.

| # | Experimento | Data | Estado |
| - | - | - | - |
| 01 | FastAPI + asyncpg: async de ponta a ponta | — | **planejado** |

## Por que este projeto existe

Ele fecha a pendência aberta em
[`django/06`, seção 9](../django/06-tipos-de-worker.md): *"FastAPI com views
`async` e `asyncpg` — async de ponta a ponta, que é o teste que este experimento
não fez"*. O experimento 06 mediu uvicorn servindo views **síncronas** do
Django, que o próprio Django empurra para um pool de threads — o async era do
servidor HTTP, não da aplicação. Aqui é da aplicação.

## Previsão registrada ANTES de medir

Copiada de [`django/06`, seção 8](../django/06-tipos-de-worker.md), escrita em
2026-08-22, antes de existir uma linha de código FastAPI. **Não editar** — o
valor deste registro está em poder estar errado.

| | CPU/req | vs. Django |
| - | - | - |
| Django + Gunicorn sync (**medido**) | **862 µs** | — |
| FastAPI async + asyncpg (**previsto**) | 300–500 µs | 1,7–2,9x |

E a previsão qualitativa que vai junto:

- **A pontuação não muda.** Já são USD 100.000 com p98 de 7ms contra um SLA de
  250ms — 35x de folga. Não existe nota acima do teto. O que se mede aqui é
  **teto de vazão** e **CPU por requisição**.
- **O ORM não é o ganho.** O caminho quente do Django já usa SQL cru
  (`UPDATE ... WHERE saldo + ? >= -limite RETURNING`), então esse custo já não
  estava sendo pago. O ganho previsto vem de Starlette ser mais enxuta que a
  pilha de request/response do Django.
- **O ganho estrutural não é velocidade**: com views `async` de verdade não
  existe thread por requisição, e portanto não existe o "uma conexão de Postgres
  por requisição concorrente" que obrigou a introduzir pool no ASGI do Django.
- **Se der certo, o gargalo migra para o Postgres**, que tem 0.60 CPU e hoje
  congela em 0,3–0,5% dos períodos. Aí a contenção nas 5 linhas quentes, hoje
  irrelevante, passa a ser o assunto. Isso é um resultado, não um problema.

## O que se mantém idêntico ao Django (uma variável por vez)

Sem isto a comparação não vale:

- mesmo schema — `infra/sql/ddl.sql`, tabelas `crebitos_cliente` e
  `crebitos_transacao`, mesmo índice `idx_transacao_extrato`
- mesma estratégia de concorrência — `UPDATE` atômico condicional com
  `RETURNING`, nunca read-then-write
- mesmo nginx (`infra/nginx/nginx-rinha.conf`), socket Unix, round-robin
- mesma distribuição de cota: API 0.40 × 2, banco 0.60, nginx 0.10
- mesma bancada: `oha`, 10s, aquecimento descartado, `cpu.stat` dos dois cgroups
