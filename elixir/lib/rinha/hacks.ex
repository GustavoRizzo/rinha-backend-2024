defmodule Rinha.Hacks do
  @moduledoc """
  Atalhos que só existem porque isto é uma competição.

  Cópia deliberada de `django/crebitos/hacks.py` e `fastapi/app/hacks.py`: o
  mesmo hack, no mesmo lugar, com o mesmo nome. Comparar projetos exige que os
  atalhos sejam os mesmos — se o Elixir ganhasse por ter um hack a mais, a
  diferença não seria da linguagem.

  Catálogo e justificativa: `.claude/docs/05-hacks-da-competicao.md`.
  """

  # O README fixa exatamente 5 clientes (IDs 1 a 5), criados na carga inicial, e
  # proíbe cadastrar o ID 6 — parte do teste é confirmar que ele devolve 404.
  # Não existe endpoint de cadastro, então o conjunto de IDs válidos é conhecido
  # em tempo de compilação.
  @ids_validos 1..5

  @doc """
  Responde se o cliente existe **sem consultar o banco**.

  Economiza um round-trip em todo request com ID inválido, e desambigua o
  `UPDATE ... RETURNING` que devolve zero linhas (cliente inexistente vs. limite
  estourado) antes de tocar no banco.

  Numa aplicação real isto é indefensável — o conjunto de clientes muda. Aqui
  ele é imutável por regra do desafio.
  """
  @spec cliente_existe?(integer()) :: boolean()
  def cliente_existe?(id) when is_integer(id), do: id in @ids_validos
end
