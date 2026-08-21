"""Testes do domínio de crébitos.

Tudo aqui continuaria fazendo sentido num sistema de contas de verdade. Os
testes que só existem por causa dos atalhos da competição estão em
`tests_hacks.py`.
"""

import json
from datetime import datetime

from django.test import TestCase
from django.utils import timezone

from crebitos.models import (
    Cliente,
    ClienteNaoEncontrado,
    Transacao,
    TransacaoInvalida,
    validar_payload,
)


class ValidarPayloadTest(TestCase):
    """Regras do payload de `POST /clientes/{id}/transacoes`."""

    def test_payload_valido_nao_levanta(self) -> None:
        validar_payload(1000, "c", "descricao")

    def test_valor_precisa_ser_inteiro(self) -> None:
        for valor in (10.5, "1000", None, [1]):
            with self.subTest(valor=valor), self.assertRaises(TransacaoInvalida):
                validar_payload(valor, "c", "ok")

    def test_valor_float_com_parte_fracionaria_zero_tambem_e_invalido(self) -> None:
        # 1000.0 é float; o contrato fala em centavos inteiros.
        with self.assertRaises(TransacaoInvalida):
            validar_payload(1000.0, "c", "ok")

    def test_booleano_nao_conta_como_inteiro(self) -> None:
        # `bool` é subclasse de `int`; sem tratamento explícito, `true` viraria
        # uma transação de 1 centavo.
        for valor in (True, False):
            with self.subTest(valor=valor), self.assertRaises(TransacaoInvalida):
                validar_payload(valor, "c", "ok")

    def test_valor_precisa_ser_positivo(self) -> None:
        for valor in (0, -1):
            with self.subTest(valor=valor), self.assertRaises(TransacaoInvalida):
                validar_payload(valor, "c", "ok")

    def test_tipo_precisa_ser_c_ou_d(self) -> None:
        for tipo in ("x", "C", "D", "", None, "cd"):
            with self.subTest(tipo=tipo), self.assertRaises(TransacaoInvalida):
                validar_payload(100, tipo, "ok")

    def test_descricao_no_limite_de_dez_caracteres_e_valida(self) -> None:
        validar_payload(100, "c", "a" * 10)

    def test_descricao_longa_demais(self) -> None:
        with self.assertRaises(TransacaoInvalida):
            validar_payload(100, "c", "a" * 11)

    def test_descricao_vazia_ou_ausente(self) -> None:
        # "string de 1 a 10 caracteres" exclui "" e null.
        for descricao in ("", None):
            with self.subTest(descricao=descricao), self.assertRaises(TransacaoInvalida):
                validar_payload(100, "c", descricao)


class TransacaoTest(TestCase):
    @classmethod
    def setUpTestData(cls) -> None:
        cls.cliente = Cliente.objects.create(pk=1, limite=100000, saldo=0)

    def saldo_atual(self) -> int:
        return Cliente.objects.get(pk=self.cliente.pk).saldo

    def test_credito_aumenta_o_saldo(self) -> None:
        limite, saldo = Cliente.transacao(1, 1000, "c", "salario")
        self.assertEqual((limite, saldo), (100000, 1000))
        self.assertEqual(self.saldo_atual(), 1000)

    def test_debito_diminui_o_saldo(self) -> None:
        limite, saldo = Cliente.transacao(1, 1000, "d", "cafe")
        self.assertEqual((limite, saldo), (100000, -1000))
        self.assertEqual(self.saldo_atual(), -1000)

    def test_credito_nao_tem_teto(self) -> None:
        Cliente.transacao(1, 10_000_000, "c", "premio")
        self.assertEqual(self.saldo_atual(), 10_000_000)

    def test_debito_que_zera_exatamente_o_limite_e_permitido(self) -> None:
        # saldo == -limite é o extremo válido: "nunca menor que o limite".
        limite, saldo = Cliente.transacao(1, 100000, "d", "no limite")
        self.assertEqual(saldo, -limite)

    def test_debito_um_centavo_alem_do_limite_e_recusado(self) -> None:
        with self.assertRaises(TransacaoInvalida):
            Cliente.transacao(1, 100001, "d", "estouro")

    def test_debito_recusado_nao_altera_o_saldo(self) -> None:
        Cliente.transacao(1, 100000, "d", "no limite")
        with self.assertRaises(TransacaoInvalida):
            Cliente.transacao(1, 1, "d", "estouro")
        self.assertEqual(self.saldo_atual(), -100000)

    def test_debito_recusado_nao_registra_transacao(self) -> None:
        with self.assertRaises(TransacaoInvalida):
            Cliente.transacao(1, 100001, "d", "estouro")
        self.assertEqual(Transacao.objects.count(), 0)

    def test_payload_invalido_nao_toca_no_banco(self) -> None:
        with self.assertNumQueries(0), self.assertRaises(TransacaoInvalida):
            Cliente.transacao(1, -1, "d", "invalido")

    def test_transacao_e_registrada_com_valor_positivo(self) -> None:
        # O sinal vive em `tipo`; o extrato devolve os dois campos separados.
        Cliente.transacao(1, 1000, "d", "cafe")
        registro = Transacao.objects.get()
        self.assertEqual(registro.valor, 1000)
        self.assertEqual(registro.tipo, "d")
        self.assertEqual(registro.descricao, "cafe")
        self.assertIsNotNone(registro.realizada_em)

    def test_saldo_e_registro_sao_atomicos(self) -> None:
        Cliente.transacao(1, 300, "c", "a")
        Cliente.transacao(1, 100, "d", "b")
        self.assertEqual(self.saldo_atual(), 200)
        self.assertEqual(Transacao.objects.count(), 2)

    def test_cliente_inexistente(self) -> None:
        with self.assertRaises(ClienteNaoEncontrado):
            Cliente.transacao(99, 100, "c", "fantasma")


class ExtratoTest(TestCase):
    @classmethod
    def setUpTestData(cls) -> None:
        cls.cliente = Cliente.objects.create(pk=1, limite=100000, saldo=0)

    def test_extrato_de_cliente_sem_transacoes(self) -> None:
        cliente, transacoes = Cliente.extrato(1)
        self.assertEqual(cliente.saldo, 0)
        self.assertEqual(cliente.limite, 100000)
        self.assertEqual(transacoes, [])

    def test_extrato_traz_saldo_total_e_nao_apenas_o_das_ultimas(self) -> None:
        for _ in range(15):
            Cliente.transacao(1, 100, "c", "x")
        cliente, transacoes = Cliente.extrato(1)
        self.assertEqual(cliente.saldo, 1500)
        self.assertEqual(len(transacoes), 10)

    def test_extrato_limita_a_dez_transacoes(self) -> None:
        for i in range(12):
            Cliente.transacao(1, 100, "c", f"t{i}")
        _, transacoes = Cliente.extrato(1)
        self.assertEqual(len(transacoes), 10)

    def test_extrato_vem_da_mais_recente_para_a_mais_antiga(self) -> None:
        for i in range(3):
            Cliente.transacao(1, 100, "c", f"t{i}")
        _, transacoes = Cliente.extrato(1)
        self.assertEqual([t.descricao for t in transacoes], ["t2", "t1", "t0"])

    def test_ordem_e_estavel_quando_os_timestamps_empatam(self) -> None:
        # Reproduz o cenário que o Gatling verifica: um crédito seguido de um
        # débito imediato, com timestamps idênticos. A ordem tem que sair pela
        # sequência de inserção, não pelo relógio.
        instante = timezone.now()
        Transacao.objects.create(
            cliente=self.cliente, valor=1, tipo="c", descricao="toma", realizada_em=instante
        )
        Transacao.objects.create(
            cliente=self.cliente, valor=1, tipo="d", descricao="devolve", realizada_em=instante
        )
        _, transacoes = Cliente.extrato(1)
        self.assertEqual([t.descricao for t in transacoes], ["devolve", "toma"])

    def test_extrato_nao_mistura_clientes(self) -> None:
        outro = Cliente.objects.create(pk=2, limite=80000, saldo=0)
        Cliente.transacao(1, 100, "c", "meu")
        Cliente.transacao(outro.pk, 100, "c", "dele")
        _, transacoes = Cliente.extrato(1)
        self.assertEqual([t.descricao for t in transacoes], ["meu"])

    def test_extrato_enxerga_transacao_recem_gravada(self) -> None:
        # read-your-writes: o Gatling faz um POST e 5 GETs paralelos exigindo
        # que todos já vejam a transação.
        Cliente.transacao(1, 1, "c", "danada")
        _, transacoes = Cliente.extrato(1)
        self.assertEqual(transacoes[0].descricao, "danada")

    def test_cliente_inexistente(self) -> None:
        with self.assertRaises(ClienteNaoEncontrado):
            Cliente.extrato(99)


class EndpointTransacoesTest(TestCase):
    """`POST /clientes/{id}/transacoes` — contrato HTTP."""

    @classmethod
    def setUpTestData(cls) -> None:
        Cliente.objects.create(pk=1, limite=100000, saldo=0)

    def post(self, id_cliente=1, **corpo):
        return self.client.post(
            f"/clientes/{id_cliente}/transacoes",
            data=json.dumps(corpo),
            content_type="application/json",
        )

    def test_credito_devolve_200_com_limite_e_saldo(self) -> None:
        resposta = self.post(valor=1000, tipo="c", descricao="salario")
        self.assertEqual(resposta.status_code, 200)
        self.assertEqual(resposta.json(), {"limite": 100000, "saldo": 1000})

    def test_debito_devolve_o_saldo_negativo(self) -> None:
        resposta = self.post(valor=1000, tipo="d", descricao="cafe")
        self.assertEqual(resposta.json()["saldo"], -1000)

    def test_resposta_contem_apenas_limite_e_saldo(self) -> None:
        resposta = self.post(valor=1, tipo="c", descricao="x")
        self.assertEqual(set(resposta.json()), {"limite", "saldo"})

    def test_limite_estourado_devolve_422(self) -> None:
        self.assertEqual(self.post(valor=100001, tipo="d", descricao="x").status_code, 422)

    def test_payload_invalido_devolve_422(self) -> None:
        casos = [
            {"valor": 1.5, "tipo": "c", "descricao": "x"},
            {"valor": -1, "tipo": "c", "descricao": "x"},
            {"valor": 0, "tipo": "c", "descricao": "x"},
            {"valor": True, "tipo": "c", "descricao": "x"},
            {"valor": "100", "tipo": "c", "descricao": "x"},
            {"valor": 100, "tipo": "x", "descricao": "x"},
            {"valor": 100, "tipo": "c", "descricao": ""},
            {"valor": 100, "tipo": "c", "descricao": "a" * 11},
        ]
        for corpo in casos:
            with self.subTest(corpo=corpo):
                self.assertEqual(self.post(**corpo).status_code, 422)

    def test_campos_ausentes_devolvem_422(self) -> None:
        for corpo in ({}, {"valor": 100}, {"tipo": "c"}, {"valor": 100, "tipo": "c"}):
            with self.subTest(corpo=corpo):
                self.assertEqual(self.post(**corpo).status_code, 422)

    def test_json_malformado_devolve_422(self) -> None:
        resposta = self.client.post(
            "/clientes/1/transacoes", data="{nao e json", content_type="application/json"
        )
        self.assertEqual(resposta.status_code, 422)

    def test_json_que_nao_e_objeto_devolve_422(self) -> None:
        for bruto in ("[]", '"texto"', "42", "null"):
            with self.subTest(bruto=bruto):
                resposta = self.client.post(
                    "/clientes/1/transacoes", data=bruto, content_type="application/json"
                )
                self.assertEqual(resposta.status_code, 422)

    def test_get_no_endpoint_de_transacoes_nao_e_permitido(self) -> None:
        self.assertEqual(self.client.get("/clientes/1/transacoes").status_code, 405)

    def test_erros_tem_corpo_vazio(self) -> None:
        # O README diz que o corpo de 404/422 não é testado; não serializamos nada.
        self.assertEqual(self.post(valor=100001, tipo="d", descricao="x").content, b"")


class EndpointExtratoTest(TestCase):
    """`GET /clientes/{id}/extrato` — contrato HTTP."""

    @classmethod
    def setUpTestData(cls) -> None:
        Cliente.objects.create(pk=1, limite=100000, saldo=0)

    def test_extrato_vazio(self) -> None:
        resposta = self.client.get("/clientes/1/extrato")
        self.assertEqual(resposta.status_code, 200)
        corpo = resposta.json()
        self.assertEqual(corpo["saldo"]["total"], 0)
        self.assertEqual(corpo["saldo"]["limite"], 100000)
        self.assertEqual(corpo["ultimas_transacoes"], [])

    def test_formato_do_extrato(self) -> None:
        Cliente.transacao(1, 10, "c", "descricao")
        corpo = self.client.get("/clientes/1/extrato").json()
        self.assertEqual(set(corpo), {"saldo", "ultimas_transacoes"})
        self.assertEqual(set(corpo["saldo"]), {"total", "data_extrato", "limite"})
        self.assertEqual(
            set(corpo["ultimas_transacoes"][0]),
            {"valor", "tipo", "descricao", "realizada_em"},
        )

    def test_datas_seguem_o_formato_do_contrato(self) -> None:
        # `2024-01-17T02:34:41.217753Z` — sufixo Z, não `+00:00`.
        Cliente.transacao(1, 10, "c", "x")
        corpo = self.client.get("/clientes/1/extrato").json()
        self.assertRegex(corpo["saldo"]["data_extrato"], r"^\d{4}-\d{2}-\d{2}T[\d:.]+Z$")
        self.assertRegex(
            corpo["ultimas_transacoes"][0]["realizada_em"], r"^\d{4}-\d{2}-\d{2}T[\d:.]+Z$"
        )

    def test_data_extrato_e_o_instante_da_consulta(self) -> None:
        antes = timezone.now()
        corpo = self.client.get("/clientes/1/extrato").json()
        depois = timezone.now()
        consulta = datetime.fromisoformat(corpo["saldo"]["data_extrato"])
        self.assertLessEqual(antes, consulta)
        self.assertLessEqual(consulta, depois)

    def test_ordem_decrescente_e_teto_de_dez(self) -> None:
        for i in range(12):
            Cliente.transacao(1, 1, "c", f"t{i}")
        corpo = self.client.get("/clientes/1/extrato").json()
        descricoes = [t["descricao"] for t in corpo["ultimas_transacoes"]]
        self.assertEqual(descricoes, [f"t{i}" for i in range(11, 1, -1)])

    def test_post_no_endpoint_de_extrato_nao_e_permitido(self) -> None:
        self.assertEqual(self.client.post("/clientes/1/extrato").status_code, 405)


class RoteamentoTest(TestCase):
    def test_id_nao_numerico_nao_casa_a_rota(self) -> None:
        self.assertEqual(self.client.get("/clientes/abc/extrato").status_code, 404)

    def test_id_negativo_nao_casa_a_rota(self) -> None:
        # `<int:...>` não aceita sinal — 404 antes de qualquer view rodar.
        self.assertEqual(self.client.get("/clientes/-1/extrato").status_code, 404)
