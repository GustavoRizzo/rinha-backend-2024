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
from html import unescape

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


def erros_por_tipo(html: str) -> list[tuple[str, int]]:
    """Extrai a tabela de erros: (mensagem, contagem)."""
    bloco = re.search(r'<table id="container_errors".*?</table>', html, re.S)
    if not bloco:
        return []
    celulas = re.findall(r"<td[^>]*>(.*?)</td>", bloco.group(0), re.S)
    erros = []
    for i in range(0, len(celulas) - 2, 3):
        mensagem = unescape(re.sub(r"<span.*?</span>|<[^>]+>", "", celulas[i], flags=re.S)).strip()
        try:
            erros.append((mensagem, int(celulas[i + 1])))
        except ValueError:
            continue
    return erros


def classifica_erros(erros: list[tuple[str, int]]) -> tuple[int, int]:
    """Separa inconsistências de saldo das demais falhas.

    A multa de consistência da Rinha vale para "cada resposta do teste que
    detectar inconsistência no saldo do cliente". Na simulação, essas
    verificações são asserções `jmesPath` sobre saldo, limite e
    ultimas_transacoes. Um timeout ou um HTTP 502 é falha de requisição: pesa no
    SLA (a requisição não respondeu abaixo de 250ms), mas NÃO é inconsistência.

    Contar as duas coisas juntas produz números absurdos — a primeira versão
    deste script cobrou USD 26,7 milhões de multa por 33.305 timeouts.
    """
    inconsistencias = falhas = 0
    for mensagem, quantidade in erros:
        if "jmespath" in mensagem.lower():
            inconsistencias += quantidade
        else:
            falhas += quantidade
    return inconsistencias, falhas


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

    def coluna(*rotulos_aceitos: str) -> int:
        """Os rótulos das colunas mudam entre versões do Gatling; falhar alto é
        melhor que assumir zero — um total zerado vira multa máxima em silêncio."""
        for rotulo in rotulos_aceitos:
            for chave, valor in globais.items():
                if chave.strip().lower() == rotulo.lower():
                    return int(float(valor))
        sys.exit(f"não achei a coluna {rotulos_aceitos} em {sorted(globais)}")

    total = coluna("Total", "Total Count")
    ko = coluna("KO", "Failed Count")

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

    erros = erros_por_tipo(html)
    inconsistencias, falhas = classifica_erros(erros)
    if ko and not erros:
        # Silêncio aqui vira multa zero numa execução cheia de falhas.
        sys.exit(f"há {ko} KO mas não consegui ler a tabela de erros do relatório")
    if erros and inconsistencias + falhas != ko:
        print(
            f"aviso: a soma dos erros ({inconsistencias + falhas}) não bate com "
            f"o total de KO ({ko}); a tabela de erros pode estar truncada."
        )

    multa_sla = max(0.0, SLA_ALVO_PCT - pct_sucesso) * MULTA_SLA_POR_PONTO
    multa_consistencia = inconsistencias * MULTA_INCONSISTENCIA
    pontuacao = PREMIO - multa_sla - multa_consistencia

    print(f"requisições totais           {total:>12,}")
    print(f"abaixo de {LIMIAR_MS}ms             {dentro_do_sla:>12,}  ({pct_sucesso:.3f}%)")
    print(f"requisições que falharam     {falhas:>12,}  (timeout, 5xx, conexão)")
    print(f"inconsistências de saldo     {inconsistencias:>12,}  (asserções jmesPath)")
    print()
    if erros:
        print("  erros por tipo:")
        for mensagem, quantidade in erros[:6]:
            marca = "INCONSISTÊNCIA" if "jmespath" in mensagem.lower() else "falha"
            print(f"    {quantidade:>7,}  [{marca}] {mensagem[:64]}")
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
        "requisicoes_falhas": falhas,
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
