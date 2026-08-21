"""Atalhos que só existem porque isto é uma competição.

Nada aqui sobreviveria a uma aplicação real. Está isolado neste módulo
justamente para ser fácil de ligar/desligar numa comparação A/B e fácil de
apagar se o projeto virar outra coisa.

Catálogo e justificativa: `.claude/docs/05-hacks-da-competicao.md`.
"""

# O README fixa exatamente 5 clientes (IDs 1 a 5), criados na carga inicial, e
# proíbe cadastrar o ID 6 — parte do teste é justamente confirmar que ele
# devolve 404. Não existe endpoint de cadastro, então o conjunto de IDs válidos
# é conhecido em tempo de compilação.
IDS_VALIDOS: frozenset[int] = frozenset(range(1, 6))


def cliente_existe(id_cliente: int) -> bool:
    """Responde se o cliente existe **sem consultar o banco**.

    Economiza um round-trip em todo request que chega com ID inválido, e mais
    importante: desambigua o `UPDATE ... RETURNING` que devolve zero linhas
    (cliente inexistente vs. limite estourado) antes de tocar no banco.

    Numa aplicação real isto é indefensável — o conjunto de clientes muda. Aqui
    ele é imutável por regra do desafio.
    """
    return id_cliente in IDS_VALIDOS
