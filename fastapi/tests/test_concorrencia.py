"""O teste que decide o resultado: 25 débitos simultâneos.

É a fase 1 da simulação oficial (`.claude/docs/02-regras.md`, seção 6). Uma
implementação com read-then-write não atômico passa em todos os testes de
contrato e morre aqui — e na Rinha isso custa USD 803,01 por inconsistência.

Estes testes valem para qualquer variante de `EXTRATO_QUERY` ou `VALIDACAO`: o
que está sob teste é o `UPDATE ... WHERE saldo + $1 >= -limite RETURNING`.
"""

import asyncio

from httpx import AsyncClient


async def test_vinte_e_cinco_debitos_simultaneos_somam_exatamente_25(
    cliente: AsyncClient,
):
    respostas = await asyncio.gather(
        *(
            cliente.post(
                "/clientes/1/transacoes",
                json={"valor": 1, "tipo": "d", "descricao": "d"},
            )
            for _ in range(25)
        )
    )
    assert [r.status_code for r in respostas] == [200] * 25

    corpo = (await cliente.get("/clientes/1/extrato")).json()
    # Exatamente -25. Qualquer lost update aparece como um valor MAIOR.
    assert corpo["saldo"]["total"] == -25
    assert len(corpo["ultimas_transacoes"]) == 10


async def test_creditos_simultaneos_devolvem_o_saldo_a_zero(cliente: AsyncClient):
    await asyncio.gather(
        *(
            cliente.post(
                "/clientes/1/transacoes",
                json={"valor": 1, "tipo": "d", "descricao": "d"},
            )
            for _ in range(25)
        )
    )
    await asyncio.gather(
        *(
            cliente.post(
                "/clientes/1/transacoes",
                json={"valor": 1, "tipo": "c", "descricao": "c"},
            )
            for _ in range(25)
        )
    )
    assert (await cliente.get("/clientes/1/extrato")).json()["saldo"]["total"] == 0


async def test_concorrencia_no_limite_nunca_deixa_saldo_abaixo_do_limite(
    cliente: AsyncClient,
):
    """O caso adversarial: mais débitos do que o limite comporta, todos juntos.

    Cliente 2 tem limite 80.000. Cem débitos simultâneos de 1.000 somam 100.000
    — 20 têm de ser recusados. O que NÃO pode acontecer, em hipótese alguma, é
    o saldo terminar abaixo de -80.000.
    """
    respostas = await asyncio.gather(
        *(
            cliente.post(
                "/clientes/2/transacoes",
                json={"valor": 1000, "tipo": "d", "descricao": "d"},
            )
            for _ in range(100)
        )
    )
    aceitos = sum(r.status_code == 200 for r in respostas)
    recusados = sum(r.status_code == 422 for r in respostas)

    assert aceitos + recusados == 100
    assert aceitos == 80
    assert recusados == 20

    corpo = (await cliente.get("/clientes/2/extrato")).json()
    assert corpo["saldo"]["total"] == -80_000
    # A regra que a Rinha multa: saldo nunca abaixo de -limite.
    assert corpo["saldo"]["total"] >= -corpo["saldo"]["limite"]


async def test_saldo_e_extrato_nao_divergem_sob_concorrencia(cliente: AsyncClient):
    """O `UPDATE` e o `INSERT` são atômicos entre si.

    Se o `UPDATE` confirmasse sem o `INSERT`, existiria saldo sem lastro no
    extrato — e o Gatling compara os dois. Aqui a checagem é a soma completa,
    possível porque o teste controla quantas transações existem.
    """
    await asyncio.gather(
        *(
            cliente.post(
                "/clientes/3/transacoes",
                json={"valor": 7, "tipo": "c" if i % 2 else "d", "descricao": "mix"},
            )
            for i in range(40)
        )
    )
    corpo = (await cliente.get("/clientes/3/extrato")).json()
    # 20 créditos e 20 débitos de 7 se anulam.
    assert corpo["saldo"]["total"] == 0
