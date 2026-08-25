# Sobe o pool com o MESMO nome que a aplicação usa (`Rinha.DB`), para que os
# testes exercitem o caminho de produção e não uma conexão paralela.
#
# `Rinha.Config.carregar!/0` roda aqui pelo mesmo motivo: as variantes vivem em
# `:persistent_term`, e um teste que não as carregasse cairia num
# `:badarg` em vez de num erro legível.
# A suíte roda com `--no-start` (ver `scripts/elixir-teste.sh`), então as
# aplicações das dependências também não subiram. Estas duas são as que os
# testes usam de verdade.
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:plug)

Rinha.Config.carregar!()

{:ok, _} =
  Postgrex.start_link(Keyword.put(Rinha.Config.postgrex_opts(), :name, Rinha.DB))

ExUnit.start()

defmodule Rinha.Caso do
  @moduledoc """
  Base dos testes: zera o banco antes de cada um.

  Estado residual entre testes é a mesma armadilha que o `down -v` do justfile
  evita entre execuções da carga — um saldo herdado transforma um teste de
  concorrência numa afirmação sobre outra coisa.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Rinha.Caso
      alias Rinha.{Config, Dominio, Router}
    end
  end

  setup do
    zerar()
    :ok
  end

  @doc "Volta ao estado da carga inicial: 5 clientes, saldo 0, sem transações."
  def zerar do
    Postgrex.query!(Rinha.DB, "TRUNCATE crebitos_transacao RESTART IDENTITY", [])
    Postgrex.query!(Rinha.DB, "UPDATE crebitos_cliente SET saldo = 0", [])
    :ok
  end

  @doc "Troca uma variante e recarrega a configuração pelo caminho de produção."
  def com_variante(variaveis, fun) do
    anteriores = Map.new(variaveis, fn {k, _} -> {k, System.get_env(k)} end)

    try do
      Enum.each(variaveis, fn {k, v} -> System.put_env(k, v) end)
      Rinha.Config.carregar!()
      fun.()
    after
      Enum.each(anteriores, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      Rinha.Config.carregar!()
    end
  end

  @doc "Executa uma requisição pelo roteador, como o Bandit faria."
  def requisitar(metodo, caminho, corpo \\ nil) do
    Plug.Test.conn(metodo, caminho, corpo)
    |> Rinha.Router.call(Rinha.Router.init([]))
  end

  @doc "POST de transação com corpo JSON."
  def transacionar(id, payload) do
    requisitar(:post, "/clientes/#{id}/transacoes", Jason.encode!(payload))
  end

  def saldo_de(id) do
    %Postgrex.Result{rows: [[saldo]]} =
      Postgrex.query!(Rinha.DB, "SELECT saldo FROM crebitos_cliente WHERE id = $1", [id])

    saldo
  end
end
