defmodule Rinha.DB do
  @moduledoc """
  Nome do pool do Postgrex e a verificação da carga inicial.

  Não há migrações aqui, de propósito. O schema e os 5 clientes vêm de
  `infra/sql/` — os MESMOS arquivos que as stacks Django e FastAPI usam —
  executados uma única vez pela imagem do Postgres na criação do volume. Duas
  razões:

  1. Com duas APIs, deixá-las aplicar o schema é uma corrida.
  2. Reusar `infra/sql/ddl.sql` é o que mantém *uma variável por vez*: mesmas
     tabelas, mesmo índice, mesmos dados.

  O módulo existe também como **nome registrado** do pool: `Rinha.DB` é passado
  a `Postgrex.query!/3` no caminho quente, e resolver um átomo registrado é mais
  barato que carregar um PID de algum lugar.
  """

  require Logger

  # Os 5 clientes do README. Ver `.claude/docs/02-regras.md`, seção 2 — e a
  # advertência de NÃO cadastrar o cliente 6, cujo 404 é parte do teste.
  @clientes_esperados %{
    1 => 100_000,
    2 => 80_000,
    3 => 1_000_000,
    4 => 10_000_000,
    5 => 500_000
  }

  def clientes_esperados, do: @clientes_esperados

  @doc """
  Aborta a subida se a carga inicial não bater com o README.

  Equivalente ao `manage.py verificar_clientes` do Django e ao
  `db.verificar_clientes` do FastAPI. Falhar aqui é muito melhor que descobrir a
  divergência no relatório da carga — um banco com saldo residual produz
  "inconsistências" que não são da aplicação.
  """
  @spec verificar!(term()) :: :ok
  def verificar!(conn) do
    %Postgrex.Result{rows: linhas} =
      Postgrex.query!(conn, "SELECT id, limite, saldo FROM crebitos_cliente ORDER BY id", [])

    encontrados = Map.new(linhas, fn [id, limite, saldo] -> {id, {limite, saldo}} end)

    problemas =
      Enum.flat_map(@clientes_esperados, fn {id, limite} ->
        case encontrados do
          %{^id => {^limite, 0}} -> []
          %{^id => {limite_real, 0}} -> ["cliente #{id}: limite #{limite_real}, esperado #{limite}"]
          %{^id => {_, saldo_real}} -> ["cliente #{id}: saldo #{saldo_real}, esperado 0"]
          _ -> ["cliente #{id} ausente"]
        end
      end) ++
        # O cliente 6 não pode existir: o Gatling verifica que ele devolve 404.
        Enum.map(Map.keys(encontrados) -- Map.keys(@clientes_esperados), fn id ->
          "cliente #{id} não deveria existir"
        end)

    if problemas == [] do
      :ok
    else
      raise "carga inicial divergente do README:\n  " <> Enum.join(problemas, "\n  ")
    end
  end
end
