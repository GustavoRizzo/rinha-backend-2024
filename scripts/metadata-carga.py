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

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from pontuacao import numeros_da_linha_global  # noqa: E402


def cmd(*args: str) -> str:
    try:
        return subprocess.run(args, capture_output=True, text=True).stdout.strip()
    except Exception:
        return "?"


def total_de_requisicoes(destino_dir: pathlib.Path) -> int:
    """Lê o total do relatório do Gatling, reusando o parser da pontuação.

    Reuso e não uma segunda regex: se o rótulo da coluna mudar numa versão nova
    do Gatling, os dois números têm de quebrar juntos. Duas leituras
    independentes do mesmo relatório é como se descobre, meses depois, que uma
    delas estava lendo a coluna errada.
    """
    globais = numeros_da_linha_global((destino_dir / "index.html").read_text())
    for rotulo in ("Total", "Total Count"):
        for chave, valor in globais.items():
            if chave.strip().lower() == rotulo.lower():
                return int(float(valor))
    sys.exit(f"não achei a coluna de total em {sorted(globais)}")


def consumo_por_servico(
    antes: pathlib.Path, depois: pathlib.Path, destino_dir: pathlib.Path
) -> dict:
    """Delta do `cpu.stat` de cada serviço entre as duas fotos.

    `pct_periodos_throttlados` é a métrica que `04-aprendizados.md` manda olhar
    ANTES de culpar a aplicação — e `cpu_us_por_request` é a que a cota
    recompensa. As duas juntas dizem se um serviço é gargalo ou só está
    saturando a própria cota.
    """
    a, d = json.loads(antes.read_text()), json.loads(depois.read_text())
    if a.keys() != d.keys():
        sys.exit(f"serviços diferentes entre as duas fotos: {sorted(a)} vs {sorted(d)}")

    total = total_de_requisicoes(destino_dir)
    if total <= 0:
        sys.exit(f"total de requisições inválido no relatório: {total}")

    saida = {}
    for servico in sorted(a):
        usado = d[servico]["usage_usec"] - a[servico]["usage_usec"]
        periodos = d[servico]["nr_periods"] - a[servico]["nr_periods"]
        congelados = d[servico]["nr_throttled"] - a[servico]["nr_throttled"]
        congelado_us = d[servico]["throttled_usec"] - a[servico]["throttled_usec"]
        if usado < 0:
            sys.exit(f"{servico}: cpu.stat andou para trás; o container reiniciou?")
        saida[servico] = {
            "cpu_usado_s": round(usado / 1_000_000, 2),
            "cpu_us_por_request": round(usado / total, 1),
            "nr_periods": periodos,
            "nr_throttled": congelados,
            "throttled_ms": round(congelado_us / 1000, 1),
            "pct_periodos_throttlados": (
                round(congelados * 100 / periodos, 1) if periodos else 0.0
            ),
        }
    saida["_total_requisicoes"] = total
    return saida


def main() -> None:
    # Os arquivos de compose vêm depois dos três primeiros argumentos, já como
    # a lista `-f a.yml -f b.yml` que o docker compose espera: a variante pode
    # ser composta por mais de um arquivo, e ler os recursos de apenas o
    # primeiro daria uma tabela de limites que não descreve o que subiu.
    destino, slug, segundos_ate_pronta, cgroup_antes, cgroup_depois = sys.argv[1:6]
    compose_args = sys.argv[6:]
    destino_dir = pathlib.Path(destino)

    recursos = {}
    bruto = cmd("docker", "compose", *compose_args, "config", "--format", "json")
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
        # MESMO critério do aborto em rodar-carga.sh: `resultados/` de fora,
        # porque são saídas versionadas — a execução anterior não suja a árvore
        # para a seguinte.
        "git_sujo": bool(
            cmd("git", "status", "--porcelain", "--", ".", ":(exclude)resultados")
        ),
        "segundos_ate_pronta": int(segundos_ate_pronta),
        "recursos": recursos,
        "gatling": "3.15.1",
        # O consumo REAL de cada serviço durante os 4 minutos, e não o limite
        # declarado. É a diferença entre "quanto essa stack podia usar" e
        # "quanto ela usou", que é o que decide redistribuição de cota.
        "cgroup": consumo_por_servico(
            pathlib.Path(cgroup_antes), pathlib.Path(cgroup_depois), destino_dir
        ),
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
