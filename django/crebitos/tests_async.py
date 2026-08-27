"""Testes do caminho `VIEWS_ASYNC=1` (experimento 08).

A propriedade que importa aqui é uma só: **as views async não podem divergir das
síncronas**. Elas existem para medir uma diferença de caminho de execução, e o
experimento perde o sentido se também mudarem o SQL ou os bytes da resposta.

O que NÃO dá para testar aqui: a execução de verdade contra o Postgres. Estes
testes rodam contra o SQLite do `manage.py test`, e o pool assíncrono do psycopg
fala Postgres. A cobertura funcional do caminho async vem do
`scripts/smoke-test.sh` com a stack de pé e das asserções de consistência do
Gatling.
"""

from django.db import connection
from django.test import SimpleTestCase

from crebitos import views_async
from crebitos.models import Cliente


def _sql_do_orm(checar_limite: bool) -> str:
    """Reproduz o texto que `Cliente._aplicar_delta` monta em runtime."""
    tabela = connection.ops.quote_name(Cliente._meta.db_table)
    condicao = " AND saldo + %s >= -limite" if checar_limite else ""
    return (
        f"UPDATE {tabela} SET saldo = saldo + %s"
        f" WHERE id = %s{condicao}"
        f" RETURNING saldo, limite"
    )


class SqlEquivalenteTest(SimpleTestCase):
    """O SQL literal das views async é o mesmo que o caminho síncrono gera.

    As views async escrevem o SQL à mão porque não têm ORM no caminho. Isso é
    uma duplicação deliberada, e duplicação sem teste envelhece mal: uma
    alteração no `_aplicar_delta` que não chegasse aqui faria os dois braços do
    experimento medirem queries diferentes — e o número continuaria plausível.
    """

    def test_debito_usa_o_mesmo_update_condicional(self) -> None:
        self.assertEqual(views_async._SQL_DEBITO, _sql_do_orm(checar_limite=True))

    def test_credito_usa_o_mesmo_update_sem_condicao(self) -> None:
        self.assertEqual(views_async._SQL_CREDITO, _sql_do_orm(checar_limite=False))

    def test_a_condicao_de_limite_esta_no_proprio_update(self) -> None:
        # É o que impede o lost update. Se algum dia virar SELECT + UPDATE, o
        # teste de consistência do Gatling falha — mas só depois de 4 minutos.
        self.assertIn("saldo + %s >= -limite", views_async._SQL_DEBITO)

    def test_extrato_ordena_por_id_decrescente(self) -> None:
        # `-id` e não `-realizada_em`: sob 340 req/s os timestamps empatam e o
        # Gatling compara `ultimas_transacoes[0]` e `[1]`.
        self.assertIn("ORDER BY id DESC", views_async._SQL_EXTRATO)
        self.assertIn("LIMIT 10", views_async._SQL_EXTRATO)


class ContratoDasViewsTest(SimpleTestCase):
    """As duas views async precisam ser corrotinas de verdade.

    Um `def` no lugar de um `async def` não quebraria nada visivelmente: o
    Django envolveria a view em `sync_to_async` (`base.py`, `adapt_method_mode`)
    e o experimento voltaria a medir o experimento 06 sem avisar.
    """

    def test_as_views_sao_corrotinas(self) -> None:
        import inspect

        for view in (views_async.transacoes, views_async.extrato):
            with self.subTest(view=view.__name__):
                self.assertTrue(inspect.iscoroutinefunction(view))
