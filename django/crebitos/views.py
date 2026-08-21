"""Os dois endpoints do contrato da Rinha.

Views de função e `HttpResponse` cru — sem DRF, sem serializers. São dois
endpoints sem autenticação, sem negociação de conteúdo e sem paginação; o custo
por request de um framework de API não compraria nada aqui. Ver
`.claude/docs/05-hacks-da-competicao.md`, seção Infraestrutura.
"""

import json
from datetime import datetime

from django.http import HttpRequest, HttpResponse
from django.utils import timezone
from django.views.decorators.http import require_GET, require_POST

from crebitos.hacks import cliente_existe
from crebitos.models import (
    Cliente,
    ClienteNaoEncontrado,
    Transacao,
    TransacaoInvalida,
)

# O corpo de 404 e 422 não é testado pela Rinha ("você pode escolher como o
# representar"), então não gastamos CPU nem bytes serializando mensagem alguma.
#
# Instância nova a cada chamada, de propósito: o handler chama `.close()` na
# resposta e middlewares mutam headers, então um objeto compartilhado entre
# requests vira estado sujo. O construtor é barato o bastante.
def _vazio(status: int) -> HttpResponse:
    return HttpResponse(status=status)


def _json(payload: dict[str, object], status: int = 200) -> HttpResponse:
    """Serializa sem passar por `JsonResponse`.

    `JsonResponse` faz o mesmo, mas carrega o `DjangoJSONEncoder` — que não
    usamos, porque formatamos as datas à mão para casar com o contrato.
    """
    return HttpResponse(
        json.dumps(payload, separators=(",", ":")),
        content_type="application/json",
    )


def _iso(momento: datetime) -> str:
    """Formata como o README: `2024-01-17T02:34:41.217753Z`.

    `isoformat()` sozinho produz `+00:00`; o contrato mostra `Z`. O Gatling não
    verifica o formato, mas seguir o exemplo é de graça.
    """
    return momento.isoformat().replace("+00:00", "Z")


@require_POST
def transacoes(request: HttpRequest, id_cliente: int) -> HttpResponse:
    """`POST /clientes/{id}/transacoes` -> 200 `{limite, saldo}` | 422 | 404."""
    # HACK DA RINHA: resolve o 404 sem tocar no banco. Para medir o custo real
    # da verificação, comente a linha abaixo — `Cliente.transacao` já levanta
    # `ClienteNaoEncontrado` sozinho, via query, no caminho de erro.
    if not cliente_existe(id_cliente):
        return _vazio(404)

    try:
        corpo = json.loads(request.body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return _vazio(422)
    if not isinstance(corpo, dict):
        return _vazio(422)

    try:
        limite, saldo = Cliente.transacao(
            id_cliente,
            corpo.get("valor"),
            corpo.get("tipo"),
            corpo.get("descricao"),
        )
    except TransacaoInvalida:
        return _vazio(422)
    except ClienteNaoEncontrado:
        return _vazio(404)

    return _json({"limite": limite, "saldo": saldo})


@require_GET
def extrato(request: HttpRequest, id_cliente: int) -> HttpResponse:
    """`GET /clientes/{id}/extrato` -> 200 | 404."""
    # HACK DA RINHA: mesmo atalho do endpoint acima.
    if not cliente_existe(id_cliente):
        return _vazio(404)

    try:
        cliente, ultimas = Cliente.extrato(id_cliente)
    except ClienteNaoEncontrado:
        return _vazio(404)

    return _json(
        {
            "saldo": {
                "total": cliente.saldo,
                # Instante da consulta, não uma coluna do banco.
                "data_extrato": _iso(timezone.now()),
                "limite": cliente.limite,
            },
            "ultimas_transacoes": [_transacao_json(t) for t in ultimas],
        }
    )


def _transacao_json(transacao: Transacao) -> dict[str, object]:
    return {
        "valor": transacao.valor,
        "tipo": transacao.tipo,
        "descricao": transacao.descricao,
        "realizada_em": _iso(transacao.realizada_em),
    }
