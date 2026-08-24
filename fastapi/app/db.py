"""Pool de conexões asyncpg e a verificação de carga inicial.

Não há migrações aqui, de propósito. O schema e os 5 clientes vêm de
`infra/sql/` — os MESMOS arquivos que a stack Django usa — executados uma única
vez pela imagem do Postgres na criação do volume. Duas razões:

1. Com duas APIs, deixá-las aplicar o schema é uma corrida.
2. Reusar `infra/sql/ddl.sql` é o que mantém *uma variável por vez* na
   comparação com o Django: mesmas tabelas, mesmo índice, mesmos dados.
"""

import asyncpg

from app import config

# Os 5 clientes do README. Ver `.claude/docs/02-regras.md`, seção 2 — e a
# advertência de NÃO cadastrar o cliente 6, cujo 404 é parte do teste.
CLIENTES_ESPERADOS: dict[int, int] = {
    1: 100_000,
    2: 80_000,
    3: 1_000_000,
    4: 10_000_000,
    5: 500_000,
}


async def criar_pool() -> asyncpg.Pool:
    pool = await asyncpg.create_pool(
        host=config.DB_HOST,
        port=config.DB_PORT,
        database=config.DB_NAME,
        user=config.DB_USER,
        password=config.DB_PASSWORD,
        min_size=config.DB_POOL_MIN,
        max_size=config.DB_POOL_MAX,
        # As conexões vivem pelo tempo de vida do processo. O experimento
        # `django/04` mediu 4,75x de diferença entre conexão persistente e uma
        # conexão nova por requisição — cada conexão no Postgres é um processo
        # do sistema operacional, não um handle barato.
        max_inactive_connection_lifetime=0,
        command_timeout=5,
    )
    if pool is None:  # pragma: no cover - a API do asyncpg permite None
        raise RuntimeError("asyncpg.create_pool devolveu None")
    return pool


async def verificar_clientes(pool: asyncpg.Pool) -> None:
    """Aborta a subida se a carga inicial não bater com o README.

    Equivalente ao `manage.py verificar_clientes` do Django. Falhar aqui é muito
    melhor que descobrir a divergência no relatório da carga — um banco com
    saldo residual produz "inconsistências" que não são da aplicação.
    """
    linhas = await pool.fetch("SELECT id, limite, saldo FROM crebitos_cliente ORDER BY id")
    encontrados = {linha["id"]: (linha["limite"], linha["saldo"]) for linha in linhas}

    problemas: list[str] = []
    for id_cliente, limite in CLIENTES_ESPERADOS.items():
        if id_cliente not in encontrados:
            problemas.append(f"cliente {id_cliente} ausente")
            continue
        limite_real, saldo_real = encontrados[id_cliente]
        if limite_real != limite:
            problemas.append(
                f"cliente {id_cliente}: limite {limite_real}, esperado {limite}"
            )
        if saldo_real != 0:
            problemas.append(f"cliente {id_cliente}: saldo {saldo_real}, esperado 0")

    # O cliente 6 não pode existir: o Gatling verifica que ele devolve 404.
    for id_cliente in encontrados.keys() - CLIENTES_ESPERADOS.keys():
        problemas.append(f"cliente {id_cliente} não deveria existir")

    if problemas:
        raise RuntimeError(
            "carga inicial divergente do README:\n  " + "\n  ".join(problemas)
        )
