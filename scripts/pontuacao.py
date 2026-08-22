"""Calcula a pontuação da Rinha a partir do relatório do Gatling.

Regras (RESULTADOS-HEADER.md do repositório oficial):

  - prêmio base: USD 100.000,00
  - multa de SLA: (98 - % de requisições abaixo de 250ms) * USD 1.000,00,
    cobrada apenas quando a porcentagem fica abaixo de 98
  - multa de consistência: nº de inconsistências * USD 803,01

Os dados são extraídos do `index.html` porque, a partir da 3.13, o Gatling não
gera mais `js/global_stats.json` e o `simulation.log` passou a ser binário.
"""

import json
import pathlib
import re
import sys

PREMIO = 100_000.00
MULTA_SLA_POR_PONTO = 1_000.00
MULTA_INCONSISTENCIA = 803.01
LIMIAR_MS = 250
SLA_ALVO_PCT = 98.0


def numeros_da_linha_global(html: str) -> dict[str, int]:
    """Extrai a linha 'All Requests' da tabela de estatísticas."""
    linha = re.search(r'<tr id="ROOT".*?</tr>', html, re.S)
    if not linha:
        sys.exit("não encontrei a linha global no relatório")
    valores = re.findall(r'<td class="value [^"]*col-(\d+)">([\d.]+)</td>', linha.group(0))
    por_coluna = {int(col): valor for col, valor in valores}
    cabecalhos = re.findall(r'<th id="col-(\d+)"[^>]*>.*?<span>(?:<abbr[^>]*>)?([^<]+)',
                            html, re.S)
    rotulos = {int(col): rotulo.strip() for col, rotulo in cabecalhos}
    return {rotulos.get(col, f"col{col}"): valor for col, valor in por_coluna.items()}


def faixas_de_resposta(html: str) -> dict[str, int]:
    """Extrai o gráfico 'Response Time Ranges': rótulo -> nº de requisições."""
    categorias = re.search(r"renderTo: 'RangesContainerId'.*?categories: \[(.*?)\]", html, re.S)
    serie = re.search(r"renderTo: 'RangesContainerId'.*?series: \[(.*?)\n    \}\n", html, re.S)
    if not categorias or not serie:
        sys.exit("não encontrei o gráfico de faixas de resposta")
    rotulos = [r.replace("<br>", " ").strip() for r in re.findall(r'"([^"]+)"', categorias.group(1))]
    contagens = [int(v) for v in re.findall(r"y:\s*(\d+)", serie.group(1))]
    return dict(zip(rotulos, contagens))


def main() -> None:
    diretorio = pathlib.Path(sys.argv[1])
    html = (diretorio / "index.html").read_text()

    globais = numeros_da_linha_global(html)
    faixas = faixas_de_resposta(html)

    total = int(float(globais.get("Total Count", globais.get("col2", 0))))
    ko = int(float(globais.get("Failed Count", globais.get("col4", 0))))

    # A primeira faixa é sempre "t < <lowerBound> ms". Conferimos que o
    # lowerBound configurado é mesmo 250 — senão o número não responde à regra.
    primeira = next(iter(faixas))
    if f"< {LIMIAR_MS}" not in primeira:
        sys.exit(
            f"o relatório foi gerado com limiar diferente de {LIMIAR_MS}ms ({primeira!r}).\n"
            f"Ajuste `lowerBound = {LIMIAR_MS}` em gatling/src/test/resources/gatling.conf."
        )
    dentro_do_sla = faixas[primeira]
    pct_sucesso = dentro_do_sla / total * 100 if total else 0.0

    # Cada resposta que acusa inconsistência de saldo vira uma falha de check no
    # Gatling, ou seja, uma requisição KO.
    inconsistencias = ko

    multa_sla = max(0.0, SLA_ALVO_PCT - pct_sucesso) * MULTA_SLA_POR_PONTO
    multa_consistencia = inconsistencias * MULTA_INCONSISTENCIA
    pontuacao = PREMIO - multa_sla - multa_consistencia

    print(f"requisições totais           {total:>12,}")
    print(f"abaixo de {LIMIAR_MS}ms             {dentro_do_sla:>12,}  ({pct_sucesso:.3f}%)")
    print(f"inconsistências (KO)         {inconsistencias:>12,}")
    print()
    for rotulo, contagem in faixas.items():
        print(f"  {rotulo:34}{contagem:>10,}")
    print()
    print(f"prêmio base                  {PREMIO:>15,.2f} USD")
    print(f"multa de SLA                 {-multa_sla:>15,.2f} USD")
    print(f"multa de consistência        {-multa_consistencia:>15,.2f} USD")
    print(f"{'PONTUAÇÃO':<28} {pontuacao:>15,.2f} USD")

    resumo = {
        "requisicoes_total": total,
        "abaixo_de_250ms": dentro_do_sla,
        "pct_abaixo_de_250ms": round(pct_sucesso, 4),
        "inconsistencias": inconsistencias,
        "multa_sla_usd": round(multa_sla, 2),
        "multa_consistencia_usd": round(multa_consistencia, 2),
        "pontuacao_usd": round(pontuacao, 2),
        "percentis_ms": {k: v for k, v in globais.items() if "pct" in k.lower() or k == "Max"},
    }
    (diretorio / "pontuacao.json").write_text(json.dumps(resumo, indent=2, ensure_ascii=False))
    print(f"\nresumo em {diretorio / 'pontuacao.json'}")


if __name__ == "__main__":
    main()
