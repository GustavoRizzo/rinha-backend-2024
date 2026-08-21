"""Roteamento da API.

Duas rotas, e nada mais. O conversor `<int:...>` já devolve 404 para IDs não
numéricos ou negativos antes de qualquer view ser chamada — de graça.
"""

from django.urls import path

from crebitos import views

urlpatterns = [
    path("clientes/<int:id_cliente>/transacoes", views.transacoes),
    path("clientes/<int:id_cliente>/extrato", views.extrato),
]
