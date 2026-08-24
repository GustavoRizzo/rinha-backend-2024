"""Os dois endpoints do contrato da Rinha, em FastAPI.

Handlers recebem `Request` e devolvem `Response` crus — sem `response_model`,
sem serializer do pydantic na saída. Não é preguiça: `response_model` faria o
FastAPI **revalidar** o que a aplicação acabou de produzir, e são dois endpoints
sem autenticação, sem negociação de conteúdo e sem paginação. Mesma decisão
tomada no Django (views de função, `HttpResponse` cru); mantê-la é o que faz a
comparação medir o framework e não o estilo de quem escreveu.

O que este projeto testa de novo, e o `django/06` não pôde testar: **async de
ponta a ponta**. Lá o uvicorn servia views síncronas, que o Django empurrava
para um pool de threads.
"""

import json
from contextlib import asynccontextmanager
from datetime import UTC, datetime

import asyncpg
import orjson
from fastapi import FastAPI, Request, Response

from app import config, db, dominio
from app.hacks import cliente_existe

# --------------------------------------------------------------------------
# Respostas
# --------------------------------------------------------------------------

# O corpo de 404 e 422 não é testado pela Rinha ("você pode escolher como o
# representar"), então não gastamos CPU nem bytes serializando mensagem alguma.
#
# Ao contrário do Django, estas instâncias são compartilhadas entre requests: o
# `Response` do Starlette é imutável depois de construído e o servidor não o
# muta ao enviar — não há o problema de estado sujo que obrigava o Django a
# construir uma resposta nova por chamada.
RESPOSTA_404 = Response(status_code=404)
RESPOSTA_422 = Response(status_code=422)

_TIPO_JSON = "application/json"


def _serializar(payload: dict[str, object]) -> bytes:
    if config.SERIALIZACAO == "orjson":
        return orjson.dumps(payload)
    return json.dumps(payload, separators=(",", ":")).encode()


def _agora_iso() -> str:
    """Formata como o README: `2024-01-17T02:34:41.217753Z`.

    `isoformat()` sozinho produz `+00:00`; o contrato mostra `Z`. O Gatling não
    verifica o formato, mas seguir o exemplo é de graça.
    """
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


# --------------------------------------------------------------------------
# Ciclo de vida
# --------------------------------------------------------------------------

@asynccontextmanager
async def ciclo_de_vida(app: FastAPI):
    pool = await db.criar_pool()
    if config.VERIFICAR_CLIENTES:
        await db.verificar_clientes(pool)
    # Guardado em atributo do módulo, e não em `app.state`, porque o caminho
    # quente lê isto em toda requisição: um global é um LOAD_GLOBAL, enquanto
    # `request.app.state.pool` são três buscas de atributo.
    global _pool
    _pool = pool
    try:
        yield
    finally:
        await pool.close()


_pool: asyncpg.Pool | None = None

app = FastAPI(lifespan=ciclo_de_vida, docs_url=None, redoc_url=None, openapi_url=None)


# --------------------------------------------------------------------------
# Endpoints
# --------------------------------------------------------------------------

@app.post("/clientes/{id_cliente}/transacoes")
async def transacoes(id_cliente: int, request: Request) -> Response:
    """`POST /clientes/{id}/transacoes` -> 200 `{limite, saldo}` | 422 | 404."""
    # HACK DA RINHA: resolve o 404 sem tocar no banco. Ver `app/hacks.py`.
    if not cliente_existe(id_cliente):
        return RESPOSTA_404

    corpo_bruto = await request.body()
    try:
        if config.VALIDACAO == "pydantic":
            valor, tipo, descricao = dominio.validar_pydantic(corpo_bruto)
        else:
            valor, tipo, descricao = dominio.validar_manual(orjson.loads(corpo_bruto))
    except (dominio.TransacaoInvalida, orjson.JSONDecodeError):
        return RESPOSTA_422

    assert _pool is not None
    try:
        limite, saldo = await dominio.transacao(_pool, id_cliente, valor, tipo, descricao)
    except dominio.TransacaoInvalida:
        return RESPOSTA_422
    except dominio.ClienteNaoEncontrado:
        return RESPOSTA_404

    return Response(
        _serializar({"limite": limite, "saldo": saldo}), media_type=_TIPO_JSON
    )


@app.get("/clientes/{id_cliente}/extrato")
async def extrato(id_cliente: int) -> Response:
    """`GET /clientes/{id}/extrato` -> 200 | 404."""
    # HACK DA RINHA: mesmo atalho do endpoint acima.
    if not cliente_existe(id_cliente):
        return RESPOSTA_404

    assert _pool is not None
    try:
        if config.EXTRATO_QUERY == "unica":
            corpo = await _extrato_unico(id_cliente)
        else:
            corpo = await _extrato_duplo(id_cliente)
    except dominio.ClienteNaoEncontrado:
        return RESPOSTA_404

    return Response(corpo, media_type=_TIPO_JSON)


async def _extrato_duplo(id_cliente: int) -> bytes:
    assert _pool is not None
    saldo, limite, ultimas = await dominio.extrato_duas_queries(_pool, id_cliente)
    return _serializar(
        {
            "saldo": {
                # Instante da consulta, não uma coluna do banco.
                "total": saldo,
                "data_extrato": _agora_iso(),
                "limite": limite,
            },
            "ultimas_transacoes": [
                {
                    "valor": t["valor"],
                    "tipo": t["tipo"],
                    "descricao": t["descricao"],
                    "realizada_em": t["realizada_em"]
                    .isoformat()
                    .replace("+00:00", "Z"),
                }
                for t in ultimas
            ],
        }
    )


async def _extrato_unico(id_cliente: int) -> bytes:
    """Concatena a string JSON que o Postgres já montou.

    Formatação de string em vez de `orjson.dumps`: as transações já são JSON
    válido vindo do banco, e desserializá-las só para re-serializar seria pagar
    o trabalho duas vezes. O resultado é byte a byte igual ao da outra variante.
    """
    assert _pool is not None
    saldo, limite, ultimas = await dominio.extrato_query_unica(_pool, id_cliente)
    return (
        f'{{"saldo":{{"total":{saldo},"data_extrato":"{_agora_iso()}",'
        f'"limite":{limite}}},"ultimas_transacoes":{ultimas}}}'
    ).encode()
