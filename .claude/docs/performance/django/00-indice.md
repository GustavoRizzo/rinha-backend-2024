# Testes de performance — Django

Índice geral em [../00-indice.md](../00-indice.md).

Cada experimento tem arquivo próprio. A convenção de escrita está descrita em
`.claude/memory/documentacao-testes-performance.md`; as regras de ouro estão no
índice geral.

| # | Experimento | Data | Estado |
| - | - | - | - |
| [01](./01-debug-vs-producao.md) | Custo do `DEBUG=True` e de `runserver` vs. Gunicorn (SQLite) | 2026-08-21 | **concluído** |
| [02](./02-container-e-cgroup.md) | Container + cgroup (SQLite): workers sob cota, throttling | 2026-08-21 | **parcial** |
| [03](./03-nginx-e-socket-unix.md) | nginx na frente, e o que um socket Unix vale | 2026-08-21 | **concluído** |
| [04](./04-postgres.md) | Postgres: leitura, escrita e o custo de `CONN_MAX_AGE` | 2026-08-21 | **concluído** |
| [05](./05-stack-completa-gatling.md) | Stack completa (2 instâncias) + Gatling: **USD 100.000, zero inconsistências** | 2026-08-21 | **concluído** |
| [06](./06-tipos-de-worker.md) | Tipos de worker: `sync`, `gthread`, ASGI/uvicorn | 2026-08-22 | **concluído** |
