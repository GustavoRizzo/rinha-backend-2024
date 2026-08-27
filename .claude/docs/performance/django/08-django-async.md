# 08 — Django async de ponta a ponta

**Status**: hipótese registrada, medição pendente.

## Hipótese registrada ANTES de medir (2026-08-27)

O experimento 06 mediu *views síncronas sob ASGI* e cobrou 4295 µs/req. Este
mede o que aquele não pôde: views `async def` e acesso ao banco por
`psycopg.AsyncConnectionPool`, sem `sync_to_async` em lugar nenhum do caminho
quente.

Previsões, com número, para poderem estar erradas:

1. **Bate o `uvicorn` do 06 com folga.** Some a thread por requisição, some o
   `ThreadSensitiveContext` por request do `asgi.py`, some a conexão
   thread-local. Chute: **1000–1500 µs/req** na escrita, contra 4295 — algo
   como 3x.
2. **NÃO bate o `gunicorn sync` (862 µs).** Sob cota de 0.40 CPU o trabalho é
   CPU, não espera: o Postgres responde em microssegundos e
   `synchronous_commit=off` tirou o disco do caminho. Async não cria vazão onde
   não há espera para sobrepor — só adiciona event loop, corrotinas e o handler
   ASGI do Django, que é mais pesado que o WSGI. Chute: **1,2x a 1,7x mais caro
   que o sync**.
3. **Fica pior que o FastAPI async (499,7 µs, `fastapi/01`).** Mesmo padrão de
   I/O, mesmo driver-classe; o que sobra de diferença é a pilha do Django.
4. **Ganho estrutural real, esse sim: conexões.** O 06 precisou de pool porque
   ASGI dava uma conexão de Postgres por requisição concorrente. Com async de
   verdade o pool passa a ser o único mecanismo de concorrência e
   `max_connections=20` deixa de ser risco.

Se (2) estiver errada — se o async ganhar do sync — o aprendizado é que eu
subestimei o custo de `resp.force_close()` e do modelo uma-requisição-por-vez.
