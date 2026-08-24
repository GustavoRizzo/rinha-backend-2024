"""Regras de negócio dos crébitos, portadas de `django/crebitos/models.py`.

A decisão central é a mesma, e é o que faz o teste de concorrência passar: o
`saldo` é **desnormalizado** em `crebitos_cliente` e é a fonte da verdade, não
um `SUM(transacoes.valor)`. Isso permite resolver débito + validação de limite
num único `UPDATE ... WHERE ... RETURNING`, sem janela entre ler e gravar.

O que mudou em relação ao Django: nada de semântica. Sumiram o ORM e a camada
de modelos — mas o Django já executava SQL cru no caminho quente, então não há
economia de ORM a colher aqui (ver `performance/fastapi/00-indice.md`,
"Previsão registrada"). O que muda de verdade é a ausência de thread por
requisição.
"""

from datetime import UTC, datetime
from typing import Literal, cast

import asyncpg

from app import config

# `c` para crédito, `d` para débito — não há terceiro caso.
TipoTransacao = Literal["c", "d"]

# Limites do contrato (README da Rinha, seção "Transações").
TIPOS_VALIDOS: frozenset[str] = frozenset(("c", "d"))
DESCRICAO_TAMANHO_MAX: int = 10
QTD_TRANSACOES_EXTRATO: int = 10


class ClienteNaoEncontrado(Exception):
    """ID de cliente inexistente. O endpoint traduz para HTTP 404."""


class TransacaoInvalida(Exception):
    """Payload fora da especificação, ou débito que estouraria o limite.

    A Rinha usa o mesmo status (422) para os dois casos e não testa o corpo da
    resposta, então não vale a pena separar em duas exceções.
    """


# --------------------------------------------------------------------------
# Validação — duas implementações, escolhidas por `VALIDACAO`
# --------------------------------------------------------------------------

def validar_manual(corpo: object) -> tuple[int, TipoTransacao, str]:
    """As mesmas 6 verificações do Django, sobre um dict já desserializado.

    Devolver a tupla em vez de só levantar exceção faz o estreitamento de tipo
    sobreviver ao retorno: quem chama passa a trabalhar com `int` e `Literal` de
    verdade, sem `cast` espalhado.
    """
    if not isinstance(corpo, dict):
        raise TransacaoInvalida("corpo deve ser um objeto JSON")

    valor = corpo.get("valor")
    tipo = corpo.get("tipo")
    descricao = corpo.get("descricao")

    # `bool` é subclasse de `int` em Python — `isinstance(True, int)` é True.
    # Sem este teste, `{"valor": true}` viraria um crédito de 1 centavo.
    if isinstance(valor, bool) or not isinstance(valor, int):
        raise TransacaoInvalida("valor deve ser um inteiro")
    if valor <= 0:
        raise TransacaoInvalida("valor deve ser positivo")
    if tipo not in TIPOS_VALIDOS:
        raise TransacaoInvalida("tipo deve ser 'c' ou 'd'")
    # "string de 1 a 10 caracteres": None e "" são tão inválidos quanto o >10.
    if not isinstance(descricao, str):
        raise TransacaoInvalida("descricao deve ser uma string")
    if not 1 <= len(descricao) <= DESCRICAO_TAMANHO_MAX:
        raise TransacaoInvalida("descricao deve ter de 1 a 10 caracteres")

    # O `in` acima garante o valor em runtime, mas não estreita o tipo estático.
    return valor, cast(TipoTransacao, tipo), descricao


def _construir_validador_pydantic():
    """Monta o `TypeAdapter` uma única vez, na importação do módulo.

    `strict=True` é o que faz `{"valor": 1.2}` e `{"valor": true}` serem
    rejeitados: no modo padrão (lax) o pydantic **coage** float para int e bool
    para int, e o teste da Rinha exige 422 nos dois casos.
    """
    from pydantic import BaseModel, ConfigDict, Field, TypeAdapter

    class PayloadTransacao(BaseModel):
        model_config = ConfigDict(strict=True, extra="ignore")

        valor: int = Field(gt=0)
        tipo: TipoTransacao
        descricao: str = Field(min_length=1, max_length=DESCRICAO_TAMANHO_MAX)

    return TypeAdapter(PayloadTransacao)


_adaptador_pydantic = (
    _construir_validador_pydantic() if config.VALIDACAO == "pydantic" else None
)


def validar_pydantic(corpo_bruto: bytes) -> tuple[int, TipoTransacao, str]:
    """Faz parsing E validação no núcleo Rust, sem `orjson.loads` antes.

    Recebe os bytes crus de propósito: passar por um dict Python primeiro
    jogaria fora metade da vantagem do pydantic-core, e o comparativo ficaria
    injusto com ele.
    """
    from pydantic import ValidationError

    assert _adaptador_pydantic is not None
    try:
        payload = _adaptador_pydantic.validate_json(corpo_bruto)
    except ValidationError as erro:
        raise TransacaoInvalida(str(erro)) from None
    return payload.valor, payload.tipo, payload.descricao


# --------------------------------------------------------------------------
# SQL
# --------------------------------------------------------------------------

# `RETURNING` no próprio `UPDATE`, e a condição do limite DENTRO da cláusula
# `WHERE`: não existe janela entre ler o saldo e gravá-lo, então não existe
# lost update. É o que a fase 1 do Gatling verifica (25 débitos simultâneos ->
# saldo exatamente -25). Ver `.claude/docs/01-fundamentos.md`, seção 4.
SQL_DEBITO = """
    UPDATE crebitos_cliente SET saldo = saldo + $1
     WHERE id = $2 AND saldo + $1 >= -limite
 RETURNING saldo, limite
"""

# Crédito não tem teto: o limite só restringe o saldo por baixo.
SQL_CREDITO = """
    UPDATE crebitos_cliente SET saldo = saldo + $1
     WHERE id = $2
 RETURNING saldo, limite
"""

SQL_INSERIR_TRANSACAO = """
    INSERT INTO crebitos_transacao (cliente_id, valor, tipo, descricao, realizada_em)
         VALUES ($1, $2, $3, $4, $5)
"""

SQL_CLIENTE = "SELECT saldo, limite FROM crebitos_cliente WHERE id = $1"

# `ORDER BY id DESC` e não `realizada_em DESC`: sob 340 req/s os timestamps
# empatam, e o Gatling verifica `ultimas_transacoes[0]` e `[1]` de duas
# transações feitas em sequência imediata. O `id` é monotônico e consistente com
# a ordem cronológica, então serve de desempate estável. É também exatamente o
# índice que existe (`idx_transacao_extrato`, em `cliente_id, id DESC`).
SQL_ULTIMAS_TRANSACOES = f"""
    SELECT valor, tipo, descricao, realizada_em
      FROM crebitos_transacao
     WHERE cliente_id = $1
  ORDER BY id DESC
     LIMIT {QTD_TRANSACOES_EXTRATO}
"""

# Variante `EXTRATO_QUERY=unica`: um round-trip só, e o array de transações já
# volta como texto JSON pronto — o Python o embute na resposta sem desserializar
# e re-serializar 10 objetos.
#
# O JSON é montado por concatenação, e não com `json_agg`, porque `json_agg`
# insere espaços e quebras de linha entre os elementos e `json_build_object`
# separa chave e valor com `" : "`. Nenhum dos dois é errado — o Gatling faz
# parsing e não liga para espaço em branco — mas nós ligamos: as duas variantes
# precisam produzir **os mesmos bytes** para que a diferença medida seja o custo
# da query, e não o tamanho do corpo trafegado.
#
# `to_json(t.descricao)` em vez de aspas na mão: é ele que escapa aspas e barras
# invertidas dentro da descrição. Os outros campos não precisam — `valor` é
# inteiro, `tipo` é um único caractere de um conjunto de dois, e `realizada_em`
# sai do `to_char` num formato fixo.
#
# `to_char` existe porque um timestamptz em JSON sai com `+00:00`, e o contrato
# do README mostra `Z`.
SQL_EXTRATO_UNICO = f"""
    SELECT c.saldo,
           c.limite,
           COALESCE((
               SELECT '[' || string_agg(
                          '{{"valor":' || t.valor
                       || ',"tipo":"' || t.tipo
                       || '","descricao":' || to_json(t.descricao)::text
                       || ',"realizada_em":"' || to_char(
                              t.realizada_em AT TIME ZONE 'UTC',
                              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
                       || '"}}', ',' ORDER BY t.id DESC) || ']'
                 FROM (SELECT id, valor, tipo, descricao, realizada_em
                         FROM crebitos_transacao
                        WHERE cliente_id = c.id
                     ORDER BY id DESC
                        LIMIT {QTD_TRANSACOES_EXTRATO}) t
           ), '[]') AS ultimas
      FROM crebitos_cliente c
     WHERE c.id = $1
"""


# --------------------------------------------------------------------------
# Operações
# --------------------------------------------------------------------------

async def transacao(
    pool: asyncpg.Pool,
    id_cliente: int,
    valor: int,
    tipo: TipoTransacao,
    descricao: str,
) -> tuple[int, int]:
    """Aplica uma transação e devolve `(limite, saldo)` já atualizados.

    A validação do payload acontece antes, no endpoint: payload inválido não
    merece nem um `acquire()` do pool, quanto mais um round-trip.
    """
    delta = valor if tipo == "c" else -valor
    sql = SQL_CREDITO if tipo == "c" else SQL_DEBITO
    agora = datetime.now(UTC)

    async with pool.acquire() as conexao:
        # A transação garante que não exista `UPDATE` confirmado sem o `INSERT`
        # correspondente — seria um saldo sem lastro no extrato, e o Gatling
        # compara os dois.
        async with conexao.transaction():
            linha = await conexao.fetchrow(sql, delta, id_cliente)
            if linha is None:
                # Zero linhas afetadas é ambíguo: cliente inexistente ou limite
                # estourado. Aqui, ao contrário do Django, não gastamos uma
                # segunda query para desambiguar — o endpoint já barrou os IDs
                # inválidos com `hacks.cliente_existe` antes de tocar no banco.
                raise TransacaoInvalida("saldo ficaria abaixo do limite")

            await conexao.execute(
                SQL_INSERIR_TRANSACAO, id_cliente, valor, tipo, descricao, agora
            )

    return linha["limite"], linha["saldo"]


async def extrato_duas_queries(
    pool: asyncpg.Pool, id_cliente: int
) -> tuple[int, int, list[asyncpg.Record]]:
    """Espelha o Django: um SELECT do cliente, outro das transações.

    As duas na MESMA conexão. Não é por consistência — em `read committed` cada
    statement já enxerga o último commit, que é o que o teste de
    read-your-writes exige — e sim para não pagar dois `acquire()` do pool.
    """
    async with pool.acquire() as conexao:
        cliente = await conexao.fetchrow(SQL_CLIENTE, id_cliente)
        if cliente is None:
            raise ClienteNaoEncontrado(id_cliente)
        ultimas = await conexao.fetch(SQL_ULTIMAS_TRANSACOES, id_cliente)
    return cliente["saldo"], cliente["limite"], ultimas


async def extrato_query_unica(
    pool: asyncpg.Pool, id_cliente: int
) -> tuple[int, int, str]:
    """Um round-trip, com as transações já em JSON pronto para concatenar."""
    linha = await pool.fetchrow(SQL_EXTRATO_UNICO, id_cliente)
    if linha is None:
        raise ClienteNaoEncontrado(id_cliente)
    return linha["saldo"], linha["limite"], linha["ultimas"]
