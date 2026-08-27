"""Os mesmos dois endpoints, `async def` de ponta a ponta.

Ligado por `VIEWS_ASYNC=1`, e só faz sentido sob ASGI: em WSGI o Django
envolveria estas views em `async_to_sync` e o teste mediria o contrário do que
pretende (`django/core/handlers/base.py`, `adapt_method_mode`). O entrypoint
aborta nessa combinação.

O que muda em relação a `views.py`: **nada de semântica**. Mesmo SQL, mesma
ordem de validações, mesmos bytes de resposta — os testes de domínio rodam
contra as duas. O que muda é o caminho de execução: sob ASGI com views
síncronas o Django cria um `ThreadSensitiveContext` POR REQUISIÇÃO
(`django/core/handlers/asgi.py`) e executa a view numa thread do executor. Uma
view `async def` é chamada direto no event loop, e o banco é falado pelo pool
assíncrono do psycopg. É essa camada — e só ela — que o experimento 08 mede.
"""

import json
from datetime import UTC, datetime

from django.http import HttpRequest, HttpResponse

from crebitos.db_async import pool
from crebitos.hacks import cliente_existe
from crebitos.models import (
    QTD_TRANSACOES_EXTRATO,
    TransacaoInvalida,
    validar_payload,
)
from crebitos.views import _iso, _json, _vazio

# SQL literal, e não construído a partir de `_meta.db_table` como em
# `models.py`: aqui não há ORM no caminho, então derivar o nome da tabela
# custaria import de modelo sem comprar nada. É o mesmo texto que o
# `_aplicar_delta` gera — `tests_async.py` compara os dois.
_SQL_DEBITO = (
    "UPDATE \"crebitos_cliente\" SET saldo = saldo + %s"
    " WHERE id = %s AND saldo + %s >= -limite"
    " RETURNING saldo, limite"
)
_SQL_CREDITO = (
    "UPDATE \"crebitos_cliente\" SET saldo = saldo + %s"
    " WHERE id = %s"
    " RETURNING saldo, limite"
)
_SQL_INSERT = (
    "INSERT INTO \"crebitos_transacao\""
    " (cliente_id, valor, tipo, descricao, realizada_em)"
    " VALUES (%s, %s, %s, %s, %s)"
)
_SQL_CLIENTE = "SELECT saldo, limite FROM \"crebitos_cliente\" WHERE id = %s"
_SQL_EXTRATO = (
    "SELECT valor, tipo, descricao, realizada_em FROM \"crebitos_transacao\""
    f" WHERE cliente_id = %s ORDER BY id DESC LIMIT {QTD_TRANSACOES_EXTRATO}"
)


async def transacoes(request: HttpRequest, id_cliente: int) -> HttpResponse:
    """`POST /clientes/{id}/transacoes` -> 200 `{limite, saldo}` | 422 | 404."""
    if request.method != "POST":
        return _vazio(405)

    # HACK DA RINHA: resolve o 404 sem tocar no banco. Idêntico ao síncrono.
    if not cliente_existe(id_cliente):
        return _vazio(404)

    try:
        corpo = json.loads(request.body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return _vazio(422)
    if not isinstance(corpo, dict):
        return _vazio(422)

    try:
        valor, tipo, descricao = validar_payload(
            corpo.get("valor"), corpo.get("tipo"), corpo.get("descricao")
        )
    except TransacaoInvalida:
        return _vazio(422)

    delta = valor if tipo == "c" else -valor
    conexoes = await pool()
    async with conexoes.connection() as conn:
        # UPDATE e INSERT precisam do mesmo BEGIN: um saldo debitado sem a
        # transação correspondente é justamente a inconsistência que o Gatling
        # procura. O pool está em autocommit, então o bloco é explícito.
        async with conn.transaction():
            async with conn.cursor() as cur:
                if tipo == "d":
                    await cur.execute(_SQL_DEBITO, (delta, id_cliente, delta))
                else:
                    await cur.execute(_SQL_CREDITO, (delta, id_cliente))
                linha = await cur.fetchone()
                if linha is None:
                    # O hack acima já garantiu que o cliente existe, então zero
                    # linhas só pode ser limite estourado.
                    return _vazio(422)
                saldo, limite = linha
                await cur.execute(
                    _SQL_INSERT,
                    # `realizada_em` calculado no Python, como no síncrono: o
                    # `now()` do Postgres devolve o instante de INÍCIO da
                    # transação, idêntico para tudo dentro do mesmo BEGIN.
                    (id_cliente, valor, tipo, descricao, datetime.now(UTC)),
                )

    return _json({"limite": limite, "saldo": saldo})


async def extrato(request: HttpRequest, id_cliente: int) -> HttpResponse:
    """`GET /clientes/{id}/extrato` -> 200 | 404."""
    if request.method != "GET":
        return _vazio(405)

    if not cliente_existe(id_cliente):
        return _vazio(404)

    conexoes = await pool()
    async with conexoes.connection() as conn:
        # Duas queries, e não a query única do FastAPI (`EXTRATO_QUERY=unica`),
        # de propósito: aqui a variável em teste é async vs. síncrono. Trocar
        # também a forma da consulta misturaria dois efeitos que o experimento
        # `fastapi/01` já mediu separado (1,25x).
        async with conn.cursor() as cur:
            await cur.execute(_SQL_CLIENTE, (id_cliente,))
            cliente = await cur.fetchone()
            if cliente is None:
                return _vazio(404)
            await cur.execute(_SQL_EXTRATO, (id_cliente,))
            ultimas = await cur.fetchall()

    saldo, limite = cliente
    return _json(
        {
            "saldo": {
                "total": saldo,
                # Instante da consulta, não uma coluna do banco.
                "data_extrato": _iso(datetime.now(UTC)),
                "limite": limite,
            },
            "ultimas_transacoes": [
                {
                    "valor": valor,
                    "tipo": tipo,
                    "descricao": descricao,
                    "realizada_em": _iso(realizada_em),
                }
                for valor, tipo, descricao, realizada_em in ultimas
            ],
        }
    )
