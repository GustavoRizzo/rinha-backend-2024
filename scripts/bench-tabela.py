"""Imprime a tabela comparativa das séries de benchmark já executadas.

Ordena por vazão e mostra a amplitude relativa ao lado — sem ela não dá para
saber se a diferença entre duas linhas é real ou ruído.

A coluna que importa sob cgroup é **µs de CPU por requisição**, não rps: com
cota fixa, vazão é consequência (cota ÷ custo). O rps só é comparável entre
linhas que rodaram sob a MESMA cota, e é por isso que a cota está no nome da
configuração.

As colunas de throttling respondem "quem é o gargalo": o serviço que congela em
quase todos os períodos é quem está segurando o sistema.

Uso: bench-tabela.py [diretório] [filtro ...]
     Os filtros são substrings; uma série entra se casar com qualquer uma.
"""

import json
import pathlib
import sys


def celula(serie: dict, bloco: str, chave: str) -> str:
    """Blocos ausentes viram travessão em vez de zero.

    Séries antigas não têm o cgroup do banco, e imprimir 0,0 ali seria afirmar
    que o banco não gastou CPU — que é uma medição, não uma ausência.
    """
    if bloco not in serie:
        return "—"
    return f"{serie[bloco][chave]['mediana']:.1f}"


def main() -> None:
    argumentos = sys.argv[1:]
    if argumentos and not argumentos[0].startswith("-") and pathlib.Path(argumentos[0]).is_dir():
        diretorio = pathlib.Path(argumentos[0])
        filtros = argumentos[1:]
    else:
        diretorio = pathlib.Path("resultados/bench")
        filtros = argumentos

    series = sorted(diretorio.glob("*.serie.json"))
    if filtros:
        series = [s for s in series if any(f in s.name for f in filtros)]
    if not series:
        alvo = f"{diretorio}" + (f" com filtro {filtros}" if filtros else "")
        print(f"nenhuma série em {alvo}")
        return

    dados = [json.load(open(a)) for a in series]
    dados.sort(key=lambda d: d["rps"]["mediana"])

    largura = max(len(d["config"]) for d in dados)
    cab = (
        f"{'config':{largura}}{'endpoint':11}{'rps':>9}{'ampl%':>7}"
        f"{'µs/req':>9}{'thr%':>6}{'µs/req db':>11}{'thr% db':>9}{'p99ms':>8}"
        # O commit vai em CADA LINHA, e não só no rodapé: a ação decorrente de
        # `performance/elixir/04` pedia que a mistura de commits ficasse
        # "mais visível que hoje", e um aviso no fim da tabela é justamente o
        # que se lê por último — ou não se lê.
        f"{'commit':>9}"
    )
    print(cab)
    print("-" * len(cab))
    for d in dados:
        print(
            f"{d['config']:{largura}}{d['endpoint']:11}"
            f"{d['rps']['mediana']:9.1f}{d['rps']['amplitude_pct']:7.1f}"
            f"{celula(d, 'cgroup', 'cpu_us_por_request'):>9}"
            f"{celula(d, 'cgroup', 'pct_periodos_throttlados'):>6}"
            f"{celula(d, 'cgroup_db', 'cpu_us_por_request'):>11}"
            f"{celula(d, 'cgroup_db', 'pct_periodos_throttlados'):>9}"
            f"{d['p99_ms']['mediana']:8.1f}"
            f"{d['git_commit'][:7]:>9}"
        )

    commits = {d["git_commit"] for d in dados}
    sujas = [d["config"] for d in dados if d["git_sujo"]]
    ref = dados[0]
    print(
        f"\n{ref['ferramenta']} | {ref['repeticoes']} reps + aquecimento descartado"
        f" | commits: {', '.join(sorted(commits))}"
    )
    if len(commits) > 1:
        print(
            f"AVISO: {len(commits)} commits diferentes nesta tabela (coluna à"
            " direita). Comparável só se nada entre eles tocou o caminho medido."
        )
    if sujas:
        print(f"AVISO: séries medidas com ÁRVORE SUJA: {', '.join(sujas)}")


if __name__ == "__main__":
    main()
