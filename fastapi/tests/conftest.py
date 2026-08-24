"""Ferramental dos testes.

Os testes rodam contra um **Postgres de verdade**, não contra um dublê. A parte
que mais importa neste projeto — o `UPDATE ... WHERE ... RETURNING` que impede o
lost update — só existe no banco; testá-la contra um mock testaria o mock.

Suba o banco descartável com `just fa-db-teste` (ou `just fa-test`, que faz o
ciclo inteiro).
"""

import os

import asyncpg
import pytest
from httpx import ASGITransport, AsyncClient

# Antes de importar a aplicação: `app.config` lê o ambiente na importação.
os.environ.setdefault("DB_HOST", "127.0.0.1")
os.environ.setdefault("DB_PORT", "5433")
# A carga inicial é reposta pelo fixture a cada teste; a conferência da subida
# aconteceria antes disso e reclamaria de saldo residual do teste anterior.
os.environ.setdefault("VERIFICAR_CLIENTES", "0")

from app import config, db, main  # noqa: E402


@pytest.fixture(scope="session")
def anyio_backend() -> str:
    return "asyncio"


@pytest.fixture
async def pool():
    pool = await db.criar_pool()
    yield pool
    await pool.close()


@pytest.fixture(autouse=True)
async def banco_limpo(pool: asyncpg.Pool):
    """Zera o estado ANTES de cada teste, não depois.

    Depois é tentador e errado: se um teste falha no meio, o próximo herda a
    sujeira e falha por um motivo que não é o dele — e é o segundo que a gente
    vai passar a tarde depurando.
    """
    async with pool.acquire() as conexao:
        await conexao.execute("TRUNCATE crebitos_transacao RESTART IDENTITY")
        await conexao.execute("UPDATE crebitos_cliente SET saldo = 0")
    yield


@pytest.fixture
async def cliente(pool: asyncpg.Pool):
    """Cliente HTTP falando ASGI direto com a aplicação, sem servidor no meio.

    Sem uvicorn e sem socket: o que está sob teste é o contrato e a lógica, não
    o transporte. O transporte é medido pelo `oha` e pelo Gatling.
    """
    main._pool = pool
    transporte = ASGITransport(app=main.app)
    async with AsyncClient(transport=transporte, base_url="http://teste") as http:
        yield http
    main._pool = None
