"""Confere se a carga inicial bate com a tabela do README.

Existe como comando (e não como script solto no justfile) para poder ser
chamado também do entrypoint do container: se a carga inicial divergir, é melhor
falhar na subida do que descobrir no relatório do Gatling.
"""

from django.core.management.base import BaseCommand, CommandError

from crebitos.models import Cliente

# Seção "Cadastro Inicial de Clientes" do README: id -> limite.
LIMITES_ESPERADOS = {1: 100000, 2: 80000, 3: 1000000, 4: 10000000, 5: 500000}


class Command(BaseCommand):
    help = "Verifica se os 5 clientes da Rinha estão cadastrados corretamente."

    def handle(self, *args: object, **options: object) -> None:
        limites = dict(Cliente.objects.values_list("pk", "limite"))
        if limites != LIMITES_ESPERADOS:
            raise CommandError(f"carga inicial divergiu do README: {limites}")

        saldos = set(Cliente.objects.values_list("saldo", flat=True))
        if saldos != {0}:
            raise CommandError(f"todos os saldos deveriam ser 0, mas há {saldos}")

        # O README proíbe o ID 6: parte do teste é confirmar que ele dá 404.
        if Cliente.objects.filter(pk=6).exists():
            raise CommandError("cliente 6 existe e o README proíbe cadastrá-lo")

        self.stdout.write("ok: 5 clientes conferem com o README; id 6 ausente")
