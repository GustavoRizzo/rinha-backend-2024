#!/usr/bin/env python3
"""Conta linhas de CÓDIGO por stack, separando documentação de implementação.

Motivação: a pergunta é *"se a linguagem ajuda demais o programador, ela tende a
ser pior em desempenho?"*. Para ela fazer sentido, o número precisa medir o que
o programador escreveu para resolver o problema — e não o quanto ele comentou.
Este repositório comenta muito e de propósito (`CLAUDE.md`: "comentários
explicam o porquê, com o número que sustenta a decisão"), então contar comentário
mediria o estilo do autor, não a linguagem.

Por que não `tokei`/`cloc`: as duas contam **docstring como código**. Em Python e
em Elixir a documentação de módulo é uma string, não um comentário — e este
projeto escreve `@moduledoc` e docstrings longos. Medir com elas puniria
exatamente as duas linguagens que documentam com strings. Verificado:
`tokei elixir/lib` diz 574 de código e 149 de comentário, com os `@moduledoc`
inteiros dentro do "código".

Regras, por linguagem:

- **Python**: `ast` acha os docstrings (módulo, classe, função); `tokenize` acha
  os comentários. Uma linha é comentário quando o `#` é a primeira coisa nela —
  comentário no fim de uma linha de código não descaracteriza a linha.
- **Elixir**: heredoc de `@moduledoc`/`@doc`/`@typedoc` é documentação. Todo
  outro heredoc é código — as constantes de SQL do projeto são heredocs, e SQL é
  código nas quatro stacks. `#` na primeira posição é comentário.
- **Go**: `//` na primeira posição é comentário; blocos `/* */` também. Não há
  docstring: a documentação do Go É comentário, o que a coloca no lado certo da
  conta sem trabalho nenhum.
- **Outros** (YAML, Dockerfile, shell): `#` na primeira posição.

O script **aborta** quando encontra um arquivo cuja extensão não sabe tratar, em
vez de ignorá-lo em silêncio. Regra do projeto: três bugs deste repositório
produziram números plausíveis em vez de erro.

Uso:
    python3 scripts/contar-codigo.py            # tabela das quatro stacks
    python3 scripts/contar-codigo.py --detalhe  # por arquivo
"""

from __future__ import annotations

import ast
import io
import sys
import tokenize
from dataclasses import dataclass
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent


@dataclass
class Contagem:
    codigo: int = 0
    doc: int = 0
    branco: int = 0

    @property
    def total(self) -> int:
        return self.codigo + self.doc + self.branco

    def __add__(self, outra: "Contagem") -> "Contagem":
        return Contagem(
            self.codigo + outra.codigo,
            self.doc + outra.doc,
            self.branco + outra.branco,
        )


# --------------------------------------------------------------------------
# Contadores por linguagem
# --------------------------------------------------------------------------

def contar_python(texto: str) -> Contagem:
    linhas = texto.splitlines()
    doc = set()

    # Docstrings: o `ast` diz exatamente quais são, sem heurística de aspas.
    arvore = ast.parse(texto)
    for no in ast.walk(arvore):
        if not isinstance(
            no, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)
        ):
            continue
        corpo = getattr(no, "body", [])
        if (
            corpo
            and isinstance(corpo[0], ast.Expr)
            and isinstance(corpo[0].value, ast.Constant)
            and isinstance(corpo[0].value.value, str)
        ):
            primeiro = corpo[0]
            doc.update(range(primeiro.lineno, (primeiro.end_lineno or primeiro.lineno) + 1))

    # Comentários: só contam como "linha de comentário" quando o `#` abre a
    # linha. `x = 1  # porquê` continua sendo uma linha de código.
    for tok in tokenize.generate_tokens(io.StringIO(texto).readline):
        if tok.type == tokenize.COMMENT and not linhas[tok.start[0] - 1][: tok.start[1]].strip():
            doc.add(tok.start[0])

    return _somar(linhas, doc)


def contar_elixir(texto: str) -> Contagem:
    linhas = texto.splitlines()
    doc: set[int] = set()
    em_doc = False

    for numero, linha in enumerate(linhas, start=1):
        despido = linha.strip()

        if em_doc:
            doc.add(numero)
            if despido.endswith('"""') or despido == '"""':
                em_doc = False
            continue

        # Heredoc de documentação. Um heredoc de SQL (`@sql_debito """`) NÃO
        # entra aqui de propósito: SQL é código nas quatro implementações, e
        # descontá-lo só do Elixir inventaria uma vantagem.
        if despido.startswith(("@moduledoc", "@doc", "@typedoc")):
            if '"""' in despido:
                doc.add(numero)
                # `@moduledoc """` abre; `@doc "uma linha"` já fecha.
                if despido.count('"""') == 1:
                    em_doc = True
            elif despido.startswith("@moduledoc false"):
                pass  # diretiva, é código
            else:
                doc.add(numero)
            continue

        if despido.startswith("#"):
            doc.add(numero)

    if em_doc:
        raise ValueError("heredoc de documentação não fechado")
    return _somar(linhas, doc)


def contar_go(texto: str) -> Contagem:
    linhas = texto.splitlines()
    doc: set[int] = set()
    em_bloco = False

    for numero, linha in enumerate(linhas, start=1):
        despido = linha.strip()
        if em_bloco:
            doc.add(numero)
            if "*/" in despido:
                em_bloco = False
            continue
        if despido.startswith("//"):
            doc.add(numero)
        elif despido.startswith("/*"):
            doc.add(numero)
            if "*/" not in despido[2:]:
                em_bloco = True

    if em_bloco:
        raise ValueError("bloco de comentário não fechado")
    return _somar(linhas, doc)


def contar_cerquilha(texto: str) -> Contagem:
    """YAML, Dockerfile, shell, `.exs` de configuração: `#` abre comentário."""
    linhas = texto.splitlines()
    doc = {n for n, linha in enumerate(linhas, start=1) if linha.strip().startswith("#")}
    return _somar(linhas, doc)


def _somar(linhas: list[str], doc: set[int]) -> Contagem:
    contagem = Contagem()
    for numero, linha in enumerate(linhas, start=1):
        if not linha.strip():
            contagem.branco += 1
        elif numero in doc:
            contagem.doc += 1
        else:
            contagem.codigo += 1
    return contagem


CONTADORES = {
    ".py": contar_python,
    ".ex": contar_elixir,
    ".exs": contar_elixir,
    ".go": contar_go,
    ".yml": contar_cerquilha,
    ".yaml": contar_cerquilha,
    ".sh": contar_cerquilha,
    "Dockerfile": contar_cerquilha,
}


def contar_arquivo(caminho: Path) -> Contagem:
    chave = caminho.name if caminho.name == "Dockerfile" else caminho.suffix
    contador = CONTADORES.get(chave)
    if contador is None:
        raise SystemExit(f"ABORTADO: não sei contar '{caminho}' (extensão {chave!r})")
    try:
        return contador(caminho.read_text(encoding="utf-8"))
    except Exception as erro:  # noqa: BLE001 - o objetivo é abortar com contexto
        raise SystemExit(f"ABORTADO: erro ao contar '{caminho}': {erro}") from erro


# --------------------------------------------------------------------------
# O que cada stack tem
# --------------------------------------------------------------------------

# Grupos deliberados, e a razão de cada corte:
#
# `aplicacao` — o que resolve os dois endpoints: domínio, rotas, validação,
#     acesso a banco, configuração da aplicação e os hacks. É o número que
#     responde à pergunta.
# `framework` — o que existe só porque o framework exige (settings do Django,
#     config.exs do Elixir, `apps.py`, `wsgi.py`). Separado porque é custo de
#     escolha de framework, não de linguagem.
# `gerado` — migrations. Código que ninguém escreveu à mão.
# `testes` — a suíte própria de cada stack.
# `infra` — Dockerfile, entrypoint e compose da stack. Igual em espírito nas
#     quatro, e serve de controle: se um número aqui destoar, é sinal de que a
#     comparação das outras linhas tem uma variável escondida.
STACKS: dict[str, dict[str, list[str]]] = {
    "django": {
        "aplicacao": [
            "django/crebitos/models.py",
            "django/crebitos/views.py",
            "django/crebitos/hacks.py",
            "django/kernel/urls.py",
            "django/crebitos/management/commands/preparar_bench.py",
            "django/crebitos/management/commands/verificar_clientes.py",
        ],
        "framework": [
            "django/kernel/settings.py",
            "django/kernel/wsgi.py",
            "django/kernel/asgi.py",
            "django/crebitos/apps.py",
            "django/crebitos/admin.py",
            "django/manage.py",
        ],
        "gerado": ["django/crebitos/migrations/0001_initial.py"],
        "testes": ["django/crebitos/tests.py", "django/crebitos/tests_hacks.py"],
        "infra": [
            "django/Dockerfile",
            "django/docker-entrypoint.sh",
            "django/docker-compose.yml",
        ],
    },
    "fastapi": {
        "aplicacao": [
            "fastapi/app/main.py",
            "fastapi/app/dominio.py",
            "fastapi/app/db.py",
            "fastapi/app/config.py",
            "fastapi/app/hacks.py",
            "fastapi/app/preparar_bench.py",
        ],
        "framework": [],
        "gerado": [],
        "testes": [
            "fastapi/tests/conftest.py",
            "fastapi/tests/test_contrato.py",
            "fastapi/tests/test_concorrencia.py",
            "fastapi/tests/test_variantes.py",
        ],
        "infra": [
            "fastapi/Dockerfile",
            "fastapi/docker-entrypoint.sh",
            "fastapi/docker-compose.yml",
        ],
    },
    "elixir": {
        "aplicacao": [
            "elixir/lib/rinha/router.ex",
            "elixir/lib/rinha/dominio.ex",
            "elixir/lib/rinha/db.ex",
            "elixir/lib/rinha/config.ex",
            "elixir/lib/rinha/hacks.ex",
            "elixir/lib/rinha/json.ex",
            "elixir/lib/rinha/preparar_bench.ex",
            "elixir/lib/rinha/application.ex",
        ],
        "framework": [
            "elixir/mix.exs",
            "elixir/config/config.exs",
            "elixir/config/runtime.exs",
        ],
        "gerado": [],
        "testes": [
            "elixir/test/test_helper.exs",
            "elixir/test/contrato_test.exs",
            "elixir/test/concorrencia_test.exs",
            "elixir/test/variantes_test.exs",
        ],
        "infra": [
            "elixir/Dockerfile",
            "elixir/docker-entrypoint.sh",
            "elixir/docker-compose.yml",
        ],
    },
    "go": {
        "aplicacao": [
            "go/main.go",
            "go/router.go",
            "go/dominio.go",
            "go/db.go",
            "go/config.go",
            "go/hacks.go",
            "go/preparar_bench.go",
        ],
        "framework": [],
        "gerado": [],
        "testes": [
            "go/caso_test.go",
            "go/contrato_test.go",
            "go/concorrencia_test.go",
            "go/variantes_test.go",
        ],
        "infra": ["go/Dockerfile", "go/docker-entrypoint.sh", "go/docker-compose.yml"],
    },
}


def main() -> None:
    detalhe = "--detalhe" in sys.argv
    grupos = ["aplicacao", "framework", "gerado", "testes", "infra"]
    resultado: dict[str, dict[str, Contagem]] = {}

    for stack, mapa in STACKS.items():
        resultado[stack] = {}
        for grupo in grupos:
            total = Contagem()
            for relativo in mapa[grupo]:
                caminho = RAIZ / relativo
                if not caminho.exists():
                    raise SystemExit(f"ABORTADO: '{relativo}' não existe (stack {stack})")
                contagem = contar_arquivo(caminho)
                if detalhe:
                    print(
                        f"  {stack:8} {grupo:10} {relativo:55} "
                        f"código {contagem.codigo:4}  doc {contagem.doc:4}"
                    )
                total = total + contagem
            resultado[stack][grupo] = total

    largura = 10
    print()
    print("LINHAS DE CÓDIGO (sem comentários, sem docstrings, sem linhas em branco)")
    print()
    cabecalho = "grupo".ljust(12) + "".join(s.rjust(largura) for s in STACKS)
    print(cabecalho)
    print("-" * len(cabecalho))
    for grupo in grupos:
        linha = grupo.ljust(12)
        for stack in STACKS:
            linha += str(resultado[stack][grupo].codigo).rjust(largura)
        print(linha)
    print("-" * len(cabecalho))

    linha = "app+framework".ljust(12)
    for stack in STACKS:
        soma = resultado[stack]["aplicacao"].codigo + resultado[stack]["framework"].codigo
        linha += str(soma).rjust(largura)
    print(linha)

    print()
    print("RAZÃO documentação/código na aplicação (estilo do autor, não da linguagem)")
    linha = "doc/código".ljust(12)
    for stack in STACKS:
        app = resultado[stack]["aplicacao"]
        linha += f"{app.doc / app.codigo:.2f}x".rjust(largura)
    print(linha)


if __name__ == "__main__":
    main()
