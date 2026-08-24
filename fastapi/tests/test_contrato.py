"""O contrato HTTP da Rinha, endpoint a endpoint.

Porte de `django/crebitos/tests.py`. Os casos são os mesmos de propósito: se o
FastAPI passasse num conjunto de testes mais frouxo, a comparação entre os dois
projetos mediria a régua, não a implementação.

Fonte dos casos: `.claude/docs/02-regras.md`, seções 1 e 6.
"""

import asyncio

import pytest
from httpx import AsyncClient

LIMITES = {1: 100_000, 2: 80_000, 3: 1_000_000, 4: 10_000_000, 5: 500_000}


# --------------------------------------------------------------------------
# POST /clientes/{id}/transacoes
# --------------------------------------------------------------------------

async def test_credito_devolve_200_com_limite_e_saldo(cliente: AsyncClient):
    resposta = await cliente.post(
        "/clientes/1/transacoes", json={"valor": 1000, "tipo": "c", "descricao": "toma"}
    )
    # 200 obrigatoriamente, nunca 201 — o README é explícito.
    assert resposta.status_code == 200
    assert resposta.json() == {"limite": 100_000, "saldo": 1000}


async def test_debito_devolve_saldo_negativo(cliente: AsyncClient):
    resposta = await cliente.post(
        "/clientes/1/transacoes", json={"valor": 1000, "tipo": "d", "descricao": "paga"}
    )
    assert resposta.status_code == 200
    assert resposta.json() == {"limite": 100_000, "saldo": -1000}


async def test_debito_no_limite_exato_e_permitido(cliente: AsyncClient):
    """Saldo -limite é válido; -limite-1 não. A fronteira é onde mora o bug."""
    resposta = await cliente.post(
        "/clientes/2/transacoes", json={"valor": 80_000, "tipo": "d", "descricao": "no fio"}
    )
    assert resposta.status_code == 200
    assert resposta.json()["saldo"] == -80_000


async def test_debito_um_centavo_alem_do_limite_e_recusado(cliente: AsyncClient):
    resposta = await cliente.post(
        "/clientes/2/transacoes", json={"valor": 80_001, "tipo": "d", "descricao": "estoura"}
    )
    assert resposta.status_code == 422


async def test_debito_recusado_nao_aplica_a_transacao(cliente: AsyncClient):
    """422 não pode deixar rastro: nem no saldo, nem no extrato."""
    await cliente.post(
        "/clientes/2/transacoes", json={"valor": 80_001, "tipo": "d", "descricao": "estoura"}
    )
    extrato = (await cliente.get("/clientes/2/extrato")).json()
    assert extrato["saldo"]["total"] == 0
    assert extrato["ultimas_transacoes"] == []


async def test_credito_nao_tem_teto(cliente: AsyncClient):
    """O limite restringe o saldo por baixo, não por cima."""
    resposta = await cliente.post(
        "/clientes/2/transacoes",
        json={"valor": 999_999, "tipo": "c", "descricao": "herança"},
    )
    assert resposta.status_code == 200
    assert resposta.json()["saldo"] == 999_999


async def test_cliente_inexistente_devolve_404(cliente: AsyncClient):
    resposta = await cliente.post(
        "/clientes/6/transacoes", json={"valor": 1, "tipo": "c", "descricao": "x"}
    )
    assert resposta.status_code == 404


@pytest.mark.parametrize(
    "payload",
    [
        pytest.param({"valor": 1.2, "tipo": "c", "descricao": "x"}, id="valor-fracionario"),
        pytest.param({"valor": "10", "tipo": "c", "descricao": "x"}, id="valor-string"),
        pytest.param({"valor": True, "tipo": "c", "descricao": "x"}, id="valor-booleano"),
        pytest.param({"valor": 0, "tipo": "c", "descricao": "x"}, id="valor-zero"),
        pytest.param({"valor": -1, "tipo": "c", "descricao": "x"}, id="valor-negativo"),
        pytest.param({"valor": 1, "tipo": "x", "descricao": "x"}, id="tipo-invalido"),
        pytest.param({"valor": 1, "tipo": "C", "descricao": "x"}, id="tipo-maiusculo"),
        pytest.param({"valor": 1, "tipo": "c", "descricao": ""}, id="descricao-vazia"),
        pytest.param({"valor": 1, "tipo": "c", "descricao": None}, id="descricao-nula"),
        pytest.param(
            {"valor": 1, "tipo": "c", "descricao": "123456789 e mais um pouco"},
            id="descricao-longa",
        ),
        pytest.param({"tipo": "c", "descricao": "x"}, id="sem-valor"),
        pytest.param({"valor": 1, "descricao": "x"}, id="sem-tipo"),
        pytest.param({"valor": 1, "tipo": "c"}, id="sem-descricao"),
    ],
)
async def test_payload_invalido_devolve_422(cliente: AsyncClient, payload: dict):
    resposta = await cliente.post("/clientes/1/transacoes", json=payload)
    assert resposta.status_code == 422


async def test_corpo_nao_json_devolve_422(cliente: AsyncClient):
    resposta = await cliente.post(
        "/clientes/1/transacoes",
        content=b"isto nao e json",
        headers={"Content-Type": "application/json"},
    )
    assert resposta.status_code == 422


async def test_corpo_json_que_nao_e_objeto_devolve_422(cliente: AsyncClient):
    resposta = await cliente.post(
        "/clientes/1/transacoes",
        content=b"[1, 2, 3]",
        headers={"Content-Type": "application/json"},
    )
    assert resposta.status_code == 422


async def test_descricao_de_dez_caracteres_e_valida(cliente: AsyncClient):
    """10 é o teto inclusivo. Um teste de fronteira do lado que deve passar."""
    resposta = await cliente.post(
        "/clientes/1/transacoes",
        json={"valor": 1, "tipo": "c", "descricao": "1234567890"},
    )
    assert resposta.status_code == 200


# --------------------------------------------------------------------------
# GET /clientes/{id}/extrato
# --------------------------------------------------------------------------

@pytest.mark.parametrize("id_cliente", sorted(LIMITES))
async def test_extrato_inicial_de_cada_cliente(cliente: AsyncClient, id_cliente: int):
    resposta = await cliente.get(f"/clientes/{id_cliente}/extrato")
    assert resposta.status_code == 200
    corpo = resposta.json()
    assert corpo["saldo"]["total"] == 0
    assert corpo["saldo"]["limite"] == LIMITES[id_cliente]
    assert corpo["ultimas_transacoes"] == []
    # `data_extrato` é o instante da consulta, não uma coluna do banco.
    assert corpo["saldo"]["data_extrato"].endswith("Z")


async def test_extrato_de_cliente_inexistente_devolve_404(cliente: AsyncClient):
    assert (await cliente.get("/clientes/6/extrato")).status_code == 404


async def test_extrato_ordena_da_mais_recente_para_a_mais_antiga(cliente: AsyncClient):
    """A ordem é verificada pelo Gatling em duas transações consecutivas.

    Sob carga os timestamps empatam, e é por isso que a query ordena por `id` e
    não por `realizada_em`. Este teste é a versão determinística daquilo.
    """
    await cliente.post(
        "/clientes/1/transacoes", json={"valor": 1, "tipo": "c", "descricao": "toma"}
    )
    await cliente.post(
        "/clientes/1/transacoes", json={"valor": 1, "tipo": "d", "descricao": "devolve"}
    )
    ultimas = (await cliente.get("/clientes/1/extrato")).json()["ultimas_transacoes"]
    assert [t["descricao"] for t in ultimas] == ["devolve", "toma"]
    assert ultimas[0]["tipo"] == "d"
    assert ultimas[1]["tipo"] == "c"


async def test_extrato_traz_no_maximo_dez_transacoes(cliente: AsyncClient):
    for i in range(15):
        await cliente.post(
            "/clientes/1/transacoes",
            json={"valor": 1, "tipo": "c", "descricao": f"t{i}"},
        )
    ultimas = (await cliente.get("/clientes/1/extrato")).json()["ultimas_transacoes"]
    assert len(ultimas) == 10
    # As 10 MAIS RECENTES, não as 10 primeiras.
    assert [t["descricao"] for t in ultimas] == [f"t{i}" for i in range(14, 4, -1)]


async def test_extrato_registra_valor_positivo_com_o_sinal_no_tipo(cliente: AsyncClient):
    """`valor` é sempre positivo; o sinal vive em `tipo`."""
    await cliente.post(
        "/clientes/1/transacoes", json={"valor": 50, "tipo": "d", "descricao": "paga"}
    )
    corpo = (await cliente.get("/clientes/1/extrato")).json()
    assert corpo["saldo"]["total"] == -50
    assert corpo["ultimas_transacoes"][0] == {
        "valor": 50,
        "tipo": "d",
        "descricao": "paga",
        "realizada_em": corpo["ultimas_transacoes"][0]["realizada_em"],
    }
    assert corpo["ultimas_transacoes"][0]["realizada_em"].endswith("Z")


async def test_read_your_writes(cliente: AsyncClient):
    """O POST responde um saldo; os 5 GETs paralelos seguintes têm de vê-lo.

    Isto é exatamente a fase 2 do Gatling (`.resources(...)` com 5 extratos
    simultâneos após um crédito). Com duas instâncias de API e cache em memória
    de processo, é aqui que a implementação quebra.
    """
    saldo_do_post = (
        await cliente.post(
            "/clientes/1/transacoes",
            json={"valor": 777, "tipo": "c", "descricao": "danada"},
        )
    ).json()["saldo"]

    extratos = await asyncio.gather(
        *(cliente.get("/clientes/1/extrato") for _ in range(5))
    )
    for resposta in extratos:
        corpo = resposta.json()
        assert corpo["saldo"]["total"] == saldo_do_post
        assert corpo["ultimas_transacoes"][0]["descricao"] == "danada"
