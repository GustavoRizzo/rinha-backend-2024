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
        # A mediana pode ser legitimamente 0 (ex.: nr_throttled sem cota
        # apertada). Amplitude relativa não existe nesse caso.
        amplitude = 0.0 if mediana == 0 else (max(valores) - min(valores)) / mediana * 100
        return {
            "mediana": round(mediana, 2),
            "min": round(min(valores), 2),
            "max": round(max(valores), 2),
            # Amplitude relativa: acima disso, diferenças não são atribuíveis.
            "amplitude_pct": round(amplitude, 2),
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
            # Valores crus de cada repetição: a amplitude resume, mas quando
            # ela sai alta é preciso ver se foi um outlier ou dispersão real.
            "rps_por_repeticao": [round(v, 1) for v in rps],
            # Só existe sob cgroup: é o que distingue "lento" de "congelado".
            **{bloco: {chave: resumo([e[bloco][chave] for e in execucoes])
                       for chave in base[bloco]}
               for bloco in ("cgroup", "cgroup_nginx", "cgroup_db") if bloco in base},
        },
        open(destino, "w"),
        indent=2,
    )
    print(f"-> {destino}")


if __name__ == "__main__":
    main()
