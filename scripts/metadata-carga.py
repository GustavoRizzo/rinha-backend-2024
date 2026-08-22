"""Grava resultados/<slug>/<timestamp>/metadata.json ao lado do relatório.

O formato segue o previsto em `.claude/docs/03-plano-implementacao.md`, seção 6:
sem commit, recursos declarados e ambiente, em duas semanas ninguém sabe o que
diferenciava uma execução da outra.
"""

import datetime
import json
import pathlib
import platform
import subprocess
import sys


def cmd(*args: str) -> str:
    try:
        return subprocess.run(args, capture_output=True, text=True).stdout.strip()
    except Exception:
        return "?"


def main() -> None:
    destino, slug, compose, segundos_ate_pronta = sys.argv[1:5]
    destino_dir = pathlib.Path(destino)

    recursos = {}
    bruto = cmd("docker", "compose", "-f", compose, "config", "--format", "json")
    if bruto:
        for nome, servico in json.loads(bruto)["services"].items():
            limites = servico.get("deploy", {}).get("resources", {}).get("limits", {})
            recursos[nome] = {
                "cpus": limites.get("cpus"),
                "memory_mib": round(int(limites.get("memory", 0)) / 1_048_576),
            }

    metadados = {
        "variante": slug,
        "timestamp": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "git_commit": cmd("git", "rev-parse", "--short", "HEAD"),
        "git_sujo": bool(cmd("git", "status", "--porcelain")),
        "segundos_ate_pronta": int(segundos_ate_pronta),
        "recursos": recursos,
        "gatling": "3.15.1",
        "host": {
            "cpus": __import__("os").cpu_count(),
            "kernel": platform.release(),
            "docker": cmd("docker", "version", "--format", "{{.Server.Version}}"),
        },
    }
    (destino_dir / "metadata.json").write_text(json.dumps(metadados, indent=2))
    print(f"metadata: {destino_dir / 'metadata.json'}")


if __name__ == "__main__":
    main()
