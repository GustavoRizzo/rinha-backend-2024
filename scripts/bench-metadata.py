"""Anexa metadados ao JSON cru do oha (lido do stdin) e grava o arquivo.

Sem commit e versões junto do número, o resultado não é replicável — em alguns
meses ninguém sabe contra qual código ele foi medido.
"""

import datetime
import json
import os
import platform
import subprocess
import sys


def cmd(*args: str) -> str:
    try:
        return subprocess.run(args, capture_output=True, text=True).stdout.strip()
    except Exception:
        return "?"


def main() -> None:
    destino, config, endpoint, duracao, modelo, concorrencia = sys.argv[1:7]
    # 7º argumento opcional: JSON com campos extras a mesclar (ex.: cgroup).
    extras = json.loads(sys.argv[7]) if len(sys.argv) > 7 else {}
    bruto = json.load(sys.stdin)
    metadados = {
        "config": config,
        "endpoint": endpoint,
        "duracao": duracao,
        "modelo_de_carga": modelo,
        "concorrencia": int(concorrencia),
        "timestamp": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "git_commit": cmd("git", "rev-parse", "--short", "HEAD") or "(sem commit)",
        # MESMO critério do aborto em bench-stack.sh: `resultados/` de fora,
        # porque são saídas versionadas. Sem a exclusão, a primeira série de uma
        # varredura sujava a árvore para as seguintes, e todas saíam marcadas
        # como suspeitas sem nada ter mudado no código medido.
        "git_sujo": bool(
            cmd("git", "status", "--porcelain", "--", ".", ":(exclude)resultados")
        ),
        "ferramenta": cmd("oha", "--version"),
        "host": {
            "cpus": os.cpu_count(),
            "kernel": platform.release(),
            "python": platform.python_version(),
        },
        "banco": os.environ.get("BENCH_BANCO", "sqlite"),
        "resultado": bruto,
    } | extras
    with open(destino, "w") as saida:
        json.dump(metadados, saida, indent=2)
    print(f"-> {destino}")


if __name__ == "__main__":
    main()
