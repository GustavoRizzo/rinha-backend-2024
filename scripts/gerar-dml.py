"""Gera infra/sql/dml.sql a partir da fixture do Django.

Gerado da FIXTURE e não de um `pg_dump`: a fixture é a fonte da verdade e é
imutável, enquanto um dump reflete o estado em que o banco estava no momento —
inclusive saldos alterados por um smoke test. Foi exatamente esse erro que o
`verificar_clientes` pegou na subida da stack.
"""

import json
import pathlib
import sys

RAIZ = pathlib.Path(__file__).resolve().parent.parent
FIXTURE = RAIZ / "django" / "crebitos" / "fixtures" / "clientes.json"


def main() -> None:
    clientes = json.loads(FIXTURE.read_text())
    linhas = [
        "-- GERADO por scripts/gerar-dml.py — não edite à mão.",
        f"-- Fonte da verdade: {FIXTURE.relative_to(RAIZ)}",
        "-- Regenere com: just gen-sql",
        "",
        "INSERT INTO public.crebitos_cliente (id, limite, saldo) VALUES",
    ]
    valores = [
        f"    ({c['pk']}, {c['fields']['limite']}, {c['fields']['saldo']})"
        for c in sorted(clientes, key=lambda c: c["pk"])
    ]
    linhas.append(",\n".join(valores) + ";")
    linhas += [
        "",
        "-- A sequence precisa continuar de onde os IDs explícitos pararam.",
        "SELECT setval('public.crebitos_cliente_id_seq',"
        f" (SELECT MAX(id) FROM public.crebitos_cliente));",
        "",
    ]
    saida = RAIZ / "infra" / "sql" / "dml.sql"
    saida.write_text("\n".join(linhas))
    print(f"gerado: {saida} ({len(clientes)} clientes)")

    if any(c["fields"]["saldo"] != 0 for c in clientes):
        sys.exit("ERRO: a fixture tem cliente com saldo != 0")


if __name__ == "__main__":
    main()
