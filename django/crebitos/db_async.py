"""Pool assíncrono do psycopg, usado só pelo caminho `VIEWS_ASYNC=1`.

Por que o pool do psycopg direto, e não o ORM assíncrono do Django: o `aget`,
o `acreate` e companhia não são assíncronos de verdade. Em
`django/db/models/query.py:694` o `aget` é literalmente
`sync_to_async(self.get)` — ou seja, ele devolve o trabalho para uma thread do
executor, que é exatamente a camada que este experimento existe para remover.
Usar o ORM async aqui mediria de novo o experimento 06 com outra sintaxe.

O `connection` do Django também não serve: as conexões dele são thread-local
(`django/db/__init__.py`, `ConnectionHandler`), e num event loop não existe
"uma thread por requisição" para amarrar conexão.
"""

import asyncio
import os

from psycopg_pool import AsyncConnectionPool

_pool: AsyncConnectionPool | None = None
_lock = asyncio.Lock()


def _conninfo() -> str:
    return (
        f"host={os.environ['DB_HOST']}"
        f" port={os.environ.get('DB_PORT', '5432')}"
        f" dbname={os.environ.get('DB_NAME', 'rinha')}"
        f" user={os.environ.get('DB_USER', 'rinha')}"
        f" password={os.environ.get('DB_PASSWORD', 'rinha')}"
        f" connect_timeout=2"
    )


async def pool() -> AsyncConnectionPool:
    """Abre o pool na primeira requisição e reusa daí em diante.

    Inicialização preguiçosa, e não no `lifespan`, porque o handler ASGI do
    Django não implementa o protocolo `lifespan` — o uvicorn registra
    "ASGI 'lifespan' protocol appears unsupported" e segue. O `async with` no
    lock roda uma vez por processo; o caminho quente é o `if` de cima.
    """
    global _pool
    if _pool is not None:
        return _pool
    async with _lock:
        if _pool is None:
            p = AsyncConnectionPool(
                _conninfo(),
                min_size=int(os.environ.get("DB_POOL_MIN", "2")),
                # Cada conexão no Postgres é um PROCESSO, e `postgresql.conf`
                # fixa max_connections=20 para duas APIs.
                max_size=int(os.environ.get("DB_POOL_MAX", "8")),
                open=False,
                # `autocommit` porque o caminho quente controla a transação à
                # mão: o POST precisa de UPDATE+INSERT no mesmo BEGIN, o GET não
                # precisa de transação nenhuma. Deixar o psycopg abrir um BEGIN
                # implícito no extrato custaria um COMMIT por leitura.
                kwargs={"autocommit": True},
            )
            await p.open(wait=True, timeout=10)
            _pool = p
    return _pool
