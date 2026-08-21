"""Modelo de domínio dos crébitos.

Duas tabelas, e a decisão central é a desnormalização do `saldo` em `Cliente`:
ele é a fonte da verdade, não um `SUM(transacoes.valor)`. Isso permite resolver
débito+validação de limite num único `UPDATE ... WHERE ... RETURNING`, que é o
que impede o *lost update* sob concorrência (ver `.claude/docs/01-fundamentos.md`,
seção 4).
"""

from typing import Literal, cast

from django.db import connection, models, transaction
from django.utils import timezone

# `c` para crédito, `d` para débito — não há terceiro caso.
TipoTransacao = Literal["c", "d"]

# Limites do contrato (README da Rinha, seção "Transações").
TIPOS_VALIDOS: tuple[TipoTransacao, ...] = ("c", "d")
DESCRICAO_TAMANHO_MAX: int = 10
QTD_TRANSACOES_EXTRATO: int = 10


class ClienteNaoEncontrado(Exception):
    """ID de cliente inexistente. A view traduz para HTTP 404."""


class TransacaoInvalida(Exception):
    """Payload fora da especificação, ou débito que estouraria o limite.

    A Rinha usa o mesmo status (422) para os dois casos e não testa o corpo da
    resposta, então não vale a pena separar em duas exceções.
    """


def validar_payload(
    valor: object, tipo: object, descricao: object
) -> tuple[int, TipoTransacao, str]:
    """Valida os campos de uma transação e devolve os valores já estreitados.

    Os parâmetros são `object` porque vêm de JSON arbitrário — validar é
    justamente descobrir de que tipo se trata. Devolver a tupla em vez de só
    levantar exceção faz o estreitamento sobreviver ao retorno: quem chama
    passa a trabalhar com `int` e `Literal` de verdade, sem `cast` espalhado.

    Roda antes de qualquer acesso ao banco: payload inválido não merece um
    round-trip.

    Levanta `TransacaoInvalida` em qualquer campo fora da especificação.
    """
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


class Cliente(models.Model):
    # Sem coluna `nome`: o exemplo do README a cadastra, mas nenhum endpoint a
    # retorna. São 5 linhas fixas, criadas na carga inicial — nunca em runtime.
    limite = models.IntegerField()
    saldo = models.IntegerField(default=0)

    def __str__(self) -> str:
        return f"Cliente {self.pk} (limite={self.limite}, saldo={self.saldo})"

    @classmethod
    def transacao(
        cls, id_cliente: int, valor: object, tipo: object, descricao: object
    ) -> tuple[int, int]:
        """Aplica uma transação e devolve `(limite, saldo)` já atualizados.

        `valor`, `tipo` e `descricao` chegam como `object` porque vêm direto do
        JSON da requisição; `validar_payload` os estreita.

        Ordem das validações: payload (mais barato) -> existência do cliente ->
        limite. O README não define precedência entre 422 e 404 e o teste de
        carga não exercita o caso conflitante.
        """
        valor, tipo, descricao = validar_payload(valor, tipo, descricao)

        delta = valor if tipo == "c" else -valor
        with transaction.atomic():
            resultado = cls._aplicar_delta(id_cliente, delta, checar_limite=(tipo == "d"))
            if resultado is None:
                # Zero linhas afetadas é ambíguo: cliente inexistente ou limite
                # estourado. Desambiguamos com uma segunda query — que só roda
                # no caminho de erro, nunca no caminho quente.
                if not cls.objects.filter(pk=id_cliente).exists():
                    raise ClienteNaoEncontrado(id_cliente)
                raise TransacaoInvalida("saldo ficaria abaixo do limite")

            saldo, limite = resultado
            Transacao.objects.create(
                cliente_id=id_cliente,
                valor=valor,
                tipo=tipo,
                descricao=descricao,
            )
        return limite, saldo

    @classmethod
    def _aplicar_delta(
        cls, id_cliente: int, delta: int, checar_limite: bool
    ) -> tuple[int, int] | None:
        """`UPDATE ... RETURNING` atômico. Devolve `(saldo, limite)` ou `None`.

        SQL cru de propósito: o ORM não expõe `RETURNING` num `update()`, e usar
        `.update()` + `.get()` custaria dois round-trips no caminho mais quente
        do sistema. A condição do limite vive dentro do próprio `UPDATE`, então
        não existe janela entre ler e gravar — é o que impede o lost update.
        """
        tabela = connection.ops.quote_name(cls._meta.db_table)
        condicao_limite = " AND saldo + %s >= -limite" if checar_limite else ""
        parametros: list[int] = [delta, id_cliente] + ([delta] if checar_limite else [])

        with connection.cursor() as cursor:
            cursor.execute(
                f"UPDATE {tabela} SET saldo = saldo + %s"
                f" WHERE id = %s{condicao_limite}"
                f" RETURNING saldo, limite",
                parametros,
            )
            linha = cursor.fetchone()
        return linha

    @classmethod
    def extrato(cls, id_cliente: int) -> tuple["Cliente", list["Transacao"]]:
        """Devolve `(cliente, ultimas_transacoes)`.

        `data_extrato` não é modelado: é o instante da consulta, calculado na
        serialização da resposta.
        """
        try:
            cliente = cls.objects.get(pk=id_cliente)
        except cls.DoesNotExist:
            raise ClienteNaoEncontrado(id_cliente) from None
        return cliente, list(cliente.transacoes.all()[:QTD_TRANSACOES_EXTRATO])


class Transacao(models.Model):
    # `db_constraint=False`: relacionamento lógico, sem FK no banco. Uma FK real
    # faria cada INSERT tomar um `FOR KEY SHARE` na linha do cliente — e são 5
    # linhas recebendo ~330 writes/s, exatamente o ponto de maior contenção. A
    # integridade já vem do fluxo: só inserimos depois do UPDATE ter dado match.
    # `db_index=False` porque o índice útil é o composto declarado em Meta; o
    # índice simples que o Django criaria por padrão seria peso morto.
    cliente = models.ForeignKey(
        Cliente,
        on_delete=models.DO_NOTHING,
        related_name="transacoes",
        db_constraint=False,
        db_index=False,
    )
    # Valor sempre positivo; o sinal vive em `tipo`. O extrato devolve os dois
    # campos separados, então guardar negativo obrigaria a converter na leitura.
    valor = models.IntegerField()
    tipo = models.CharField(max_length=1)
    descricao = models.CharField(max_length=DESCRICAO_TAMANHO_MAX)
    # `timezone.now` (por linha, no Python) e não `now()` do Postgres, que
    # devolve o timestamp de *início da transação* — idêntico para tudo dentro
    # do mesmo BEGIN.
    realizada_em = models.DateTimeField(default=timezone.now)

    class Meta:
        # O README exige ordem decrescente por data/hora e o Gatling verifica
        # `ultimas_transacoes[0]` e `[1]` de duas transações feitas em sequência
        # imediata — sob 340 req/s os timestamps empatam. `-id` é monotônico e
        # consistente com a ordem cronológica, então serve de desempate estável.
        ordering = ["-id"]
        indexes = [
            # Único padrão de leitura que existe: as N últimas de um cliente.
            models.Index(fields=["cliente", "-id"], name="idx_transacao_extrato"),
        ]
