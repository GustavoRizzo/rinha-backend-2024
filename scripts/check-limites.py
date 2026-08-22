"""Valida as restrições da Rinha: soma <= 1.5 CPU e <= 550MB entre TODOS os
serviços. Lê o compose resolvido (`docker compose config`) do stdin.

ARMADILHA DE UNIDADE: o Docker interpreta o sufixo `MB` como **MiB**
(1.048.576 bytes), não como 10^6. Uma stack declarando 550MB recebe de fato
577 MB decimais de RAM. O README da Rinha pede que os limites sejam escritos
em `MB` "para facilitar as verificações", ou seja, a conferência é feita
sobre os NÚMEROS DECLARADOS. Este script converte de volta para MiB para
comparar exatamente o que foi declarado — que é o critério da competição.
"""

import json
import sys

CPU_MAX = 1.5
MEM_MAX_MB = 550  # em MiB, como o Docker e a competição contam


def para_mb(valor: object) -> float:
    # O `docker compose config` resolve memória para bytes; o YAML cru usa
    # sufixos. Aceitamos os dois para o script servir nos dois casos.
    if isinstance(valor, (int, float)):
        # O Compose resolve para bytes usando múltiplos binários; voltamos
        # para MiB, que é o número que foi escrito no YAML.
        return valor / 1_048_576
    texto = str(valor).strip().upper().removesuffix("B")
    for sufixo, fator in (("G", 1024.0), ("M", 1.0), ("K", 1 / 1024)):
        if texto.endswith(sufixo):
            return float(texto[:-1]) * fator
    return float(texto) / 1_048_576


def main() -> None:
    compose = json.load(sys.stdin)
    cpus = mem = 0.0
    faltando = []

    print(f"{'serviço':16}{'cpus':>8}{'memória':>12}")
    for nome, servico in sorted(compose["services"].items()):
        limites = servico.get("deploy", {}).get("resources", {}).get("limits", {})
        if not limites:
            print(f"{nome:16}{'SEM LIMITE':>20}")
            faltando.append(nome)
            continue
        c = float(limites.get("cpus", 0))
        m = para_mb(limites.get("memory", 0))
        cpus += c
        mem += m
        print(f"{nome:16}{c:8.2f}{m:10.0f}MB")

    print(f"{'TOTAL':16}{cpus:8.2f}{mem:10.0f}MB")
    print(f"{'LIMITE':16}{CPU_MAX:8.2f}{MEM_MAX_MB:10.0f}MB")

    erros = []
    if faltando:
        # A Rinha exige limites declarados em todos os serviços.
        erros.append(f"sem limites declarados: {', '.join(faltando)}")
    if cpus > CPU_MAX + 1e-9:
        erros.append(f"CPU {cpus:.2f} > {CPU_MAX}")
    if mem > MEM_MAX_MB + 1e-9:
        erros.append(f"memória {mem:.0f}MB > {MEM_MAX_MB}MB")
    if erros:
        sys.exit("ESTOUROU: " + "; ".join(erros))

    print(f"\nok: sobra {CPU_MAX - cpus:.2f} CPU e {MEM_MAX_MB - mem:.0f}MB")


if __name__ == "__main__":
    main()
