"""Monta os blocos `cgroup` do resultado a partir dos deltas do `cpu.stat`.

Os denominadores aqui são legitimamente zero em alguns cenários — sem cota
apertada não há throttling, e `nr_periods` pode não avançar. Divisão protegida
em vez de erro.

Uso: bench-cgroup.py <total_req> <uso_us> <thr> <thr_us> <periodos> [... idem nginx]
"""

import json
import sys


def divide(a: float, b: float) -> float:
    return 0.0 if b == 0 else a / b


def bloco(total: int, uso_us: int, throttled: int, throttled_us: int, periodos: int) -> dict:
    return {
        "cpu_usado_s": round(uso_us / 1_000_000, 3),
        # A métrica que a cota recompensa: quanto de CPU cada requisição custa,
        # independente de quanta CPU existe.
        "cpu_us_por_request": round(divide(uso_us, total), 1),
        "nr_throttled": throttled,
        "throttled_ms": round(throttled_us / 1000, 1),
        "nr_periods": periodos,
        "pct_periodos_throttlados": round(divide(throttled * 100, periodos), 1),
    }


def main() -> None:
    valores = [int(v) for v in sys.argv[1:]]
    total = valores[0]
    saida = {"cgroup": bloco(total, *valores[1:5])}
    # Argumentos extras descrevem um segundo cgroup (o do load balancer).
    if len(valores) >= 9:
        saida["cgroup_nginx"] = bloco(total, *valores[5:9])
    print(json.dumps(saida))


if __name__ == "__main__":
    main()
