"""Configuração por variável de ambiente.

Convenção do projeto (ver `CLAUDE.md`): configurações alternativas são
**variáveis de ambiente, não branches**. Elas convivem no mesmo commit, e é
isso que torna a comparação A/B possível — `bench-stack.sh` liga uma de cada
vez sem trocar de código.
"""

import os

# --- banco ---------------------------------------------------------------

DB_HOST: str = os.environ.get("DB_HOST", "localhost")
DB_PORT: int = int(os.environ.get("DB_PORT", "5432"))
DB_NAME: str = os.environ.get("DB_NAME", "rinha")
DB_USER: str = os.environ.get("DB_USER", "rinha")
DB_PASSWORD: str = os.environ.get("DB_PASSWORD", "rinha")

# Cada conexão no Postgres é um PROCESSO, e `postgresql.conf` fixa
# `max_connections = 20` para duas APIs. Teto por instância deliberadamente
# baixo — a conta é 2 APIs x DB_POOL_MAX + folga de manutenção.
#
# Diferença estrutural para o Django (ver `performance/django/06`, seção 7): lá
# o ASGI criava UMA conexão por requisição concorrente, porque as conexões são
# thread-local e cada request ganhava sua própria thread. Aqui não existe thread
# por requisição: o pool é o único mecanismo de concorrência com o banco, e
# `pool.acquire()` enfileira em vez de abrir conexão nova.
DB_POOL_MIN: int = int(os.environ.get("DB_POOL_MIN", "2"))
DB_POOL_MAX: int = int(os.environ.get("DB_POOL_MAX", "8"))

# --- variantes medidas ---------------------------------------------------

# `manual`  — as mesmas 6 verificações do Django, em Python puro.
# `pydantic` — `TypeAdapter.validate_json`, que faz parsing E validação no
#              núcleo Rust do pydantic-core, sem passar por `orjson.loads`.
# Hipótese em aberto: para 3 campos, o custo de construir o modelo pode comer o
# ganho do parser. É medição, não fé.
VALIDACAO: str = os.environ.get("VALIDACAO", "manual")

# `unica` — uma query só, com o array de transações já serializado em JSON pelo
#           Postgres e embutido na resposta sem passar pelo Python. **Padrão**
#           desde o experimento `performance/fastapi/01`: 1,25x, com teste
#           provando que as duas variantes produzem os mesmos bytes.
# `duas`   — um SELECT do cliente, outro das 10 transações. Foi o padrão até o
#            experimento 01, porque espelha o que o Django faz; continua
#            disponível porque é a linha de base daquela comparação.
EXTRATO_QUERY: str = os.environ.get("EXTRATO_QUERY", "unica")

# `orjson` — serializador em Rust.
# `stdlib` — `json.dumps`, para medir quanto o orjson vale num payload de 2
#            campos (a hipótese é: quase nada no POST, algo no extrato).
SERIALIZACAO: str = os.environ.get("SERIALIZACAO", "orjson")

# Aborta na subida se o banco não tiver exatamente os 5 clientes do README.
# Equivalente ao `manage.py verificar_clientes` do Django: falhar aqui é muito
# melhor que descobrir a divergência no relatório da carga.
VERIFICAR_CLIENTES: bool = os.environ.get("VERIFICAR_CLIENTES", "1") == "1"


def _validar_opcoes() -> None:
    """Aborta com nome de variável e valor recebido.

    Regra do projeto: todo componente de medição deve abortar quando não
    reconhecer o que está lendo. Um `VALIDACAO=pydatnic` com typo cairia
    silenciosamente no caminho manual e produziria um número plausível —
    exatamente o modo de falha que já custou três bugs a este projeto.
    """
    for nome, valor, aceitos in (
        ("VALIDACAO", VALIDACAO, {"manual", "pydantic"}),
        ("EXTRATO_QUERY", EXTRATO_QUERY, {"duas", "unica"}),
        ("SERIALIZACAO", SERIALIZACAO, {"orjson", "stdlib"}),
    ):
        if valor not in aceitos:
            raise SystemExit(
                f"{nome}={valor!r} desconhecido; aceitos: {sorted(aceitos)}"
            )


_validar_opcoes()
