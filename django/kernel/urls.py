"""Roteamento da API.

Duas rotas, e nada mais. O conversor `<int:...>` já devolve 404 para IDs não
numéricos ou negativos antes de qualquer view ser chamada — de graça.

`VIEWS_ASYNC=1` troca o módulo de views pelo par `async def` do experimento 08.
A escolha é no import, não dentro da view: um `if` por requisição seria custo
pago no caminho quente para responder uma pergunta que já está decidida na
subida do processo.
"""

import os

from django.urls import path

if os.environ.get("VIEWS_ASYNC", "0") == "1":
    from crebitos import views_async as views
else:
    from crebitos import views  # type: ignore[no-redef]

urlpatterns = [
    path("clientes/<int:id_cliente>/transacoes", views.transacoes),
    path("clientes/<int:id_cliente>/extrato", views.extrato),
]
