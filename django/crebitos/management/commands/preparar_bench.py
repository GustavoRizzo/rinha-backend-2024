"""Deixa o banco num estado conhecido e realista para o benchmark.

Sem isto, `GET /clientes/1/extrato` devolveria uma lista vazia e mediria a
serialização de quase nada. O contrato permite até 10 transações no extrato, e é
esse o payload que queremos exercitar.

Recria o estado do zero a cada chamada: comparar rodadas que partiram de bancos
diferentes não compara nada.
"""

from django.core.management.base import BaseCommand

from crebitos.models import Cliente, Transacao

# Mais que as 10 do extrato, para o ORDER BY + LIMIT ter o que descartar.
TRANSACOES_POR_CLIENTE = 50


class Command(BaseCommand):
    help = "Zera as transações e recria um histórico fixo para o benchmark."

    def handle(self, *args: object, **options: object) -> None:
        Transacao.objects.all().delete()
        Cliente.objects.update(saldo=0)

        for cliente in Cliente.objects.all():
            Transacao.objects.bulk_create(
                Transacao(
                    cliente=cliente,
                    valor=100,
                    tipo="c" if i % 2 == 0 else "d",
                    descricao=f"bench{i:04d}"[:10],
                )
                for i in range(TRANSACOES_POR_CLIENTE)
            )

        total = Transacao.objects.count()
        self.stdout.write(f"ok: {total} transações em {Cliente.objects.count()} clientes")
