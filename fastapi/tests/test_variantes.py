"""As variantes medidas precisam ser indistinguíveis pela resposta.

Se `EXTRATO_QUERY=unica` fosse mais rápida *e* devolvesse outra coisa, o número
não valeria nada. Este arquivo é o que autoriza a comparação: as duas variantes
produzem **os mesmos bytes**.
"""

import asyncio

import pytest
from httpx import AsyncClient

from app import config, dominio, main


async def test_as_duas_variantes_de_extrato_produzem_os_mesmos_bytes(
    cliente: AsyncClient, monkeypatch: pytest.MonkeyPatch
):
    for i in range(3):
        await cliente.post(
            "/clientes/1/transacoes",
            # Aspas e barra invertida na descrição: é o que o `to_json` do
            # Postgres precisa escapar igual ao orjson. Sem este caso, a
            # variante `unica` poderia gerar JSON inválido e ninguém veria.
            json={"valor": 10 + i, "tipo": "c", "descricao": 'a"b\\c'},
        )

    monkeypatch.setattr(config, "EXTRATO_QUERY", "duas")
    duas = await main._extrato_duplo(1)

    monkeypatch.setattr(config, "EXTRATO_QUERY", "unica")
    unica = await main._extrato_unico(1)

    # `data_extrato` é o instante da consulta e difere entre as duas chamadas;
    # comparar o resto byte a byte é o que interessa.
    def sem_data(corpo: bytes) -> bytes:
        inicio = corpo.index(b'"data_extrato":"')
        fim = corpo.index(b'"', inicio + len(b'"data_extrato":"') + 1)
        return corpo[:inicio] + corpo[fim:]

    assert sem_data(duas) == sem_data(unica)


async def test_extrato_vazio_nas_duas_variantes(cliente: AsyncClient):
    """O `COALESCE(..., '[]')` da query única: sem ele, viria `null`."""
    duas = await main._extrato_duplo(4)
    unica = await main._extrato_unico(4)
    assert b'"ultimas_transacoes":[]' in duas
    assert b'"ultimas_transacoes":[]' in unica


@pytest.mark.parametrize(
    "payload",
    [
        {"valor": 1.2, "tipo": "c", "descricao": "x"},
        {"valor": True, "tipo": "c", "descricao": "x"},
        {"valor": 0, "tipo": "c", "descricao": "x"},
        {"valor": 1, "tipo": "x", "descricao": "x"},
        {"valor": 1, "tipo": "c", "descricao": ""},
        {"valor": 1, "tipo": "c", "descricao": None},
        {"valor": 1, "tipo": "c", "descricao": "12345678901"},
        {"tipo": "c", "descricao": "x"},
    ],
)
def test_pydantic_recusa_exatamente_o_que_o_validador_manual_recusa(payload: dict):
    """O ponto de atenção é o modo strict.

    No modo padrão (lax) o pydantic **coage** `1.2` para `1` e `True` para `1`,
    e a Rinha exige 422 nos dois. Se este teste falhar depois de um upgrade, a
    causa mais provável é o `strict=True` ter deixado de valer.
    """
    import orjson

    validador = dominio._construir_validador_pydantic()

    from pydantic import ValidationError

    with pytest.raises(ValidationError):
        validador.validate_json(orjson.dumps(payload))

    with pytest.raises(dominio.TransacaoInvalida):
        dominio.validar_manual(payload)


@pytest.mark.parametrize(
    "payload",
    [
        {"valor": 1, "tipo": "c", "descricao": "x"},
        {"valor": 99999, "tipo": "d", "descricao": "1234567890"},
    ],
)
def test_pydantic_aceita_exatamente_o_que_o_validador_manual_aceita(payload: dict):
    import orjson

    validador = dominio._construir_validador_pydantic()
    modelo = validador.validate_json(orjson.dumps(payload))
    manual = dominio.validar_manual(payload)

    assert (modelo.valor, modelo.tipo, modelo.descricao) == manual


async def test_serializacao_stdlib_e_orjson_produzem_os_mesmos_bytes(
    monkeypatch: pytest.MonkeyPatch,
):
    payload = {"limite": 100_000, "saldo": -9098}

    monkeypatch.setattr(config, "SERIALIZACAO", "orjson")
    com_orjson = main._serializar(payload)

    monkeypatch.setattr(config, "SERIALIZACAO", "stdlib")
    com_stdlib = main._serializar(payload)

    assert com_orjson == com_stdlib == b'{"limite":100000,"saldo":-9098}'
