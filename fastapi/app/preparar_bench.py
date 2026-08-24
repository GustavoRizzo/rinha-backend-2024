"""Deixa o banco num estado conhecido e realista para o benchmark.

Porte de `django/crebitos/management/commands/preparar_bench.py`, e o estado
final tem de ser **idêntico** ao que aquele comando produz: mesmas 50 transações
por cliente, mesmos valores, mesma ordem de inserção. Se o FastAPI medisse o
extrato com uma lista de tamanho diferente, a comparação com o Django estaria
medindo o payload, não a aplicação.

Sem isto, `GET /clientes/1/extrato` devolveria lista vazia e mediria a
serialização de quase nada. O contrato permite até 10 transações no extrato, e é
esse o payload que queremos exercitar.

Recria o estado do zero a cada chamada: comparar rodadas que partiram de bancos
diferentes não compara nada.
"""

import asyncio

from app import db

# Mais que as 10 do extrato, para o ORDER BY + LIMIT ter o que descartar.
TRANSACOES_POR_CLIENTE = 50


async def preparar() -> None:
    pool = await db.criar_pool()
    try:
        async with pool.acquire() as conexao:
            # RESTART IDENTITY para que os ids recomecem do 1 a cada rodada: o
            # extrato ordena por id, e ids crescentes entre repetições mudariam
            # o custo do índice ao longo da série.
            await conexao.execute("TRUNCATE crebitos_transacao RESTART IDENTITY")
            await conexao.execute("UPDATE crebitos_cliente SET saldo = 0")

            ids = [linha["id"] for linha in
                   await conexao.fetch("SELECT id FROM crebitos_cliente ORDER BY id")]

            # A ordem de inserção importa: o extrato devolve as 10 de maior id,
            # e é ela que decide QUAIS transações entram na resposta medida.
            linhas = [
                (id_cliente, 100, "c" if i % 2 == 0 else "d", f"bench{i:04d}"[:10])
                for id_cliente in ids
                for i in range(TRANSACOES_POR_CLIENTE)
            ]
            await conexao.executemany(
                "INSERT INTO crebitos_transacao"
                " (cliente_id, valor, tipo, descricao, realizada_em)"
                " VALUES ($1, $2, $3, $4, now())",
                linhas,
            )

            total = await conexao.fetchval("SELECT count(*) FROM crebitos_transacao")
        print(f"ok: {total} transações em {len(ids)} clientes")
    finally:
        await pool.close()


if __name__ == "__main__":
    asyncio.run(preparar())
