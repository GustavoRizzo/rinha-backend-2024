"""Agrega as repetições de uma série num único JSON com mediana e dispersão.

Reportar uma execução única esconde o ruído; reportar a média esconde outliers.
Guardamos mediana, mínimo e máximo, mais a amplitude relativa — que é o número
que diz se uma diferença entre configurações é real ou não.
"""

import json
import statistics
import sys


def main() -> None:
    destino, *arquivos = sys.argv[1:]
    execucoes = [json.load(open(a)) for a in arquivos]
    rps = [e["resultado"]["summary"]["requestsPerSec"] for e in execucoes]
    p50 = [e["resultado"]["latencyPercentiles"]["p50"] * 1000 for e in execucoes]
    p99 = [e["resultado"]["latencyPercentiles"]["p99"] * 1000 for e in execucoes]

    def resumo(valores: list[float]) -> dict[str, float]:
        mediana = statistics.median(valores)
        return {
            "mediana": round(mediana, 2),
            "min": round(min(valores), 2),
            "max": round(max(valores), 2),
            # Amplitude relativa: acima disso, diferenças não são atribuíveis.
            "amplitude_pct": round((max(valores) - min(valores)) / mediana * 100, 2),
        }

    base = execucoes[0]
    json.dump(
        {
            k: base[k]
            for k in ("config", "endpoint", "duracao", "modelo_de_carga",
                      "concorrencia", "git_commit", "git_sujo", "ferramenta",
                      "host", "banco")
        }
        | {
            "repeticoes": len(execucoes),
            "aquecimento_descartado": True,
            "rps": resumo(rps),
            "p50_ms": resumo(p50),
            "p99_ms": resumo(p99),
            "codigos": base["resultado"]["statusCodeDistribution"],
            # Só existe sob cgroup: é o que distingue "lento" de "congelado".
            **({"cgroup": {chave: resumo([e["cgroup"][chave] for e in execucoes])
                           for chave in base["cgroup"]}} if "cgroup" in base else {}),
        },
        open(destino, "w"),
        indent=2,
    )
    print(f"-> {destino}")


if __name__ == "__main__":
    main()
