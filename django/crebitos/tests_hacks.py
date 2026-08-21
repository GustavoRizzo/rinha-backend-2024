"""Testes dos atalhos que só existem por ser uma competição.

Estes testes **não** descrevem um sistema de contas correto. Eles fixam
comportamentos que dependem de premissas do desafio (conjunto de clientes
imutável, integridade garantida pelo fluxo em vez do banco). Se o projeto
deixar de ser a Rinha, este arquivo inteiro deve ser apagado junto com
`crebitos/hacks.py`.

Catálogo e justificativa: `.claude/docs/05-hacks-da-competicao.md`.
"""

from django.test import TestCase

from crebitos.hacks import IDS_VALIDOS, cliente_existe
from crebitos.models import Cliente, Transacao


class ClientesHardcodedTest(TestCase):
    """O conjunto de clientes é conhecido em tempo de compilação.

    Premissa: o README fixa 5 clientes (IDs 1..5) criados na carga inicial e não
    existe endpoint de cadastro. Numa aplicação real isso seria indefensável.
    """

    def test_ids_validos_sao_exatamente_os_cinco_do_readme(self) -> None:
        self.assertEqual(IDS_VALIDOS, {1, 2, 3, 4, 5})

    def test_id_seis_nao_existe(self) -> None:
        # Parte explícita do teste da Rinha: o ID 6 tem que devolver 404, e o
        # README proíbe cadastrá-lo.
        self.assertFalse(cliente_existe(6))

    def test_ids_fora_da_faixa_sao_rejeitados(self) -> None:
        for id_cliente in (0, -1, 6, 999, 2**31):
            with self.subTest(id_cliente=id_cliente):
                self.assertFalse(cliente_existe(id_cliente))

    def test_ids_da_faixa_sao_aceitos(self) -> None:
        for id_cliente in range(1, 6):
            with self.subTest(id_cliente=id_cliente):
                self.assertTrue(cliente_existe(id_cliente))

    def test_verificacao_nao_consulta_o_banco(self) -> None:
        # É este o ganho: zero round-trips para responder 404. Se este teste
        # falhar, o atalho perdeu a razão de existir.
        with self.assertNumQueries(0):
            cliente_existe(6)
            cliente_existe(1)

    def test_atalho_mente_se_o_banco_divergir(self) -> None:
        # Documenta o acoplamento: o atalho não olha o banco, então um cliente
        # gravado fora da faixa fica invisível. É aceitável só porque o desafio
        # garante que isso nunca acontece.
        Cliente.objects.create(pk=6, limite=1, saldo=0)
        self.assertTrue(Cliente.objects.filter(pk=6).exists())
        self.assertFalse(cliente_existe(6))


class SemForeignKeyNoBancoTest(TestCase):
    """`Transacao.cliente` é um vínculo lógico, sem constraint no banco.

    Premissa: uma FK real faria cada INSERT tomar um lock de chave na linha do
    cliente — 5 linhas concentrando ~330 writes/s. A integridade vem do fluxo:
    só inserimos depois do UPDATE condicional ter dado match.
    """

    def test_banco_aceita_transacao_orfa(self) -> None:
        # Numa aplicação real isto seria um bug gritante (IntegrityError
        # esperado). Aqui é a consequência aceita conscientemente.
        Transacao.objects.create(cliente_id=999, valor=1, tipo="c", descricao="orfa")
        self.assertEqual(Transacao.objects.filter(cliente_id=999).count(), 1)

    def test_nenhuma_constraint_de_fk_no_ddl(self) -> None:
        campo = Transacao._meta.get_field("cliente")
        self.assertFalse(campo.db_constraint)

    def test_fk_nao_cria_indice_proprio(self) -> None:
        # O índice útil é o composto (cliente, -id); um índice simples em
        # cliente seria peso morto em cada INSERT.
        campo = Transacao._meta.get_field("cliente")
        self.assertFalse(campo.db_index)

    def test_indice_do_extrato_existe_e_e_composto(self) -> None:
        indices = {i.name: i.fields for i in Transacao._meta.indexes}
        self.assertEqual(indices["idx_transacao_extrato"], ["cliente", "-id"])


class FixtureDosCincoClientesTest(TestCase):
    """A carga inicial precisa casar exatamente com a tabela do README.

    Se a fixture divergir, o teste do Gatling acusa saldo inconsistente — e o
    atalho de IDs em memória passa a mentir.
    """

    fixtures = ["clientes.json"]

    # id -> limite, direto da tabela "Cadastro Inicial de Clientes".
    ESPERADO = {1: 100000, 2: 80000, 3: 1000000, 4: 10000000, 5: 500000}

    def test_fixture_cria_exatamente_cinco_clientes(self) -> None:
        self.assertEqual(Cliente.objects.count(), 5)

    def test_limites_conferem_com_o_readme(self) -> None:
        limites = dict(Cliente.objects.values_list("pk", "limite"))
        self.assertEqual(limites, self.ESPERADO)

    def test_todos_comecam_com_saldo_zero(self) -> None:
        self.assertEqual(list(Cliente.objects.values_list("saldo", flat=True)), [0] * 5)

    def test_fixture_nao_cria_o_cliente_seis(self) -> None:
        # O README proíbe explicitamente: parte do teste é o 404 no ID 6.
        self.assertFalse(Cliente.objects.filter(pk=6).exists())

    def test_fixture_e_o_atalho_concordam(self) -> None:
        # A trava que impede a fixture e `hacks.IDS_VALIDOS` de divergirem.
        self.assertEqual(set(Cliente.objects.values_list("pk", flat=True)), IDS_VALIDOS)


class EndpointsComAtalhoTest(TestCase):
    """O atalho de IDs ligado nas views."""

    fixtures = ["clientes.json"]

    def test_cliente_seis_devolve_404_nos_dois_endpoints(self) -> None:
        self.assertEqual(self.client.get("/clientes/6/extrato").status_code, 404)
        resposta = self.client.post(
            "/clientes/6/transacoes",
            data='{"valor":1,"tipo":"c","descricao":"x"}',
            content_type="application/json",
        )
        self.assertEqual(resposta.status_code, 404)

    def test_404_de_cliente_inexistente_nao_consulta_o_banco(self) -> None:
        # É o ganho inteiro do atalho: nenhum round-trip no caminho de 404.
        with self.assertNumQueries(0):
            self.client.get("/clientes/6/extrato")

    def test_404_vem_antes_da_validacao_de_payload(self) -> None:
        # Consequência da ordem escolhida: no caso conflitante (ID inexistente
        # COM payload inválido) ganha o 404. O README não define precedência e o
        # Gatling não exercita esse caso.
        resposta = self.client.post(
            "/clientes/6/transacoes", data="{lixo", content_type="application/json"
        )
        self.assertEqual(resposta.status_code, 404)
