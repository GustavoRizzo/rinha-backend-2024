"""Imprime a tabela comparativa das séries de benchmark já executadas.

Ordena por vazão e mostra a amplitude relativa ao lado — sem ela não dá para
saber se a diferença entre duas linhas é real ou ruído.
"""

import json
import pathlib
import sys


def main() -> None:
    diretorio = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "resultados/bench")
    series = sorted(diretorio.glob("*.serie.json"))
    if not series:
        print(f"nenhuma série em {diretorio} (rode `just bench-01`)")
        return

    dados = [json.load(open(a)) for a in series]
    dados.sort(key=lambda d: d["rps"]["mediana"])
    base = dados[0]["rps"]["mediana"]

    cab = f"{'config':20}{'endpoint':11}{'rps':>10}{'ampl%':>7}{'p50ms':>8}{'p99ms':>9}{'vs base':>9}"
    print(cab)
    print("-" * len(cab))
    for d in dados:
        print(
            f"{d['config']:20}{d['endpoint']:11}"
            f"{d['rps']['mediana']:10.1f}{d['rps']['amplitude_pct']:7.1f}"
            f"{d['p50_ms']['mediana']:8.1f}{d['p99_ms']['mediana']:9.1f}"
            f"{d['rps']['mediana'] / base:8.1f}x"
        )
    ref = dados[0]
    print(
        f"\ncommit {ref['git_commit']}"
        f"{' (ÁRVORE SUJA)' if ref['git_sujo'] else ''}"
        f" | {ref['ferramenta']} | {ref['repeticoes']} reps + aquecimento descartado"
    )


if __name__ == "__main__":
    main()
