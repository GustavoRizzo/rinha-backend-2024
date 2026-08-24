# fastapi/01 — FastAPI + asyncpg: async de ponta a ponta

Fecha a pendência aberta em [`django/06`, seção 9](../django/06-tipos-de-worker.md):
*"FastAPI com views `async` e `asyncpg` — async de ponta a ponta, que é o teste
que este experimento não fez"*.

---

## 1. Ressalvas metodológicas

**O que este teste mede.** O custo em CPU de uma requisição, sob cota de cgroup,
com a aplicação saturada. A métrica principal é **µs de CPU por requisição**
(`cpu.stat` do cgroup ÷ respostas), não rps: sob cota, vazão é consequência —
cota ÷ custo.

**O que este teste NÃO mede.**

- **Não mede pontuação.** A stack Django já marca USD 100.000 com p98 de 7ms
  contra um SLA de 250ms — 35x de folga. Não existe nota acima do teto, e
  nenhum número aqui pode melhorá-la. A prova oficial (Gatling) roda no fim
  apenas para confirmar que a implementação é **correta**, não para comparar.
- **Não isola o driver.** A comparação é Django+psycopg contra
  FastAPI+asyncpg — dois frameworks e dois drivers de uma vez. É uma violação
  consciente do "uma variável por vez": medir FastAPI+psycopg custaria uma
  terceira implementação, e a pergunta que interessa é sobre a *pilha*, não
  sobre o driver isolado. Onde isso importa para a conclusão, está dito.
- **Não é o ambiente da competição.** 20 vCPU e 31GB, contra 4 vCPU no servidor
  oficial, e o gerador de carga não disputa CPU com a aplicação aqui.
- **`oha` não é o Gatling.** Números destas duas ferramentas **nunca** devem ser
  comparados entre si. Ver `04-aprendizados.md`.
- **Rig de uma instância.** O rig de bancada tem UMA API, não duas. Mede custo
  por requisição, não a stack de produção.

**O que foi mantido idêntico ao Django**, para que a diferença seja atribuível:
mesmo schema (`infra/sql/ddl.sql`), mesmo `postgresql.conf`, mesmo nginx e mesmo
socket Unix, mesma cota (0.40 CPU na API), mesmo endpoint, mesma duração, mesma
concorrência, mesmo estado inicial (50 transações por cliente) e a mesma
estratégia de concorrência — o `UPDATE` atômico condicional com `RETURNING`.

---

## 2. Ambiente e commit

| Item | Valor |
| - | - |
| Commit (FastAPI) | `2df750f` |
| Commit (Django, séries de referência) | `762808f` |
| Host | 20 vCPU, 31GB, kernel 6.6.87.2-microsoft-standard-WSL2 |
| Docker | 29.6.2 |
| Gerador de carga | `oha` 1.15.0 |
| Python | 3.14.6 nos dois projetos |
| Django | 6.1 + gunicorn sync + psycopg 3.3.4 |
| FastAPI | 0.141.1 + uvicorn 0.52.4 (uvloop 0.22.1, httptools 0.8.0) + asyncpg 0.31.0 |
| Postgres | 18-alpine, `synchronous_commit = off`, `max_connections = 20` |

Rig: nginx (0.15 CPU) + 1 API (0.40 CPU) + Postgres (0.6 CPU), socket Unix entre
nginx e API. 10s por repetição, 5 repetições, aquecimento descartado,
concorrência 50, modelo fechado (saturação).

---

## 3. Comandos para replicar

```bash
# linha de base do FastAPI (escrita e leitura)
just bench-fa transacoes
just bench-fa extrato

# as variantes, uma por vez
BENCH_PROJETO=fastapi VALIDACAO=pydantic BENCH_ENDPOINT=transacoes \
    bash scripts/bench-stack.sh postgres 0.40 1 10s 5
BENCH_PROJETO=fastapi EXTRATO_QUERY=unica BENCH_ENDPOINT=extrato \
    bash scripts/bench-stack.sh postgres 0.40 1 10s 5

# o experimento inteiro
just bench-fa-01

# a série de referência do Django, no MESMO rig e na MESMA cota
BENCH_ENDPOINT=transacoes bash scripts/bench-stack.sh postgres 0.40 1 10s 5
```

---

## 4. Resultados

_(preenchido ao fim das séries)_

---

## 5. Conclusões

_(preenchido ao fim das séries)_
