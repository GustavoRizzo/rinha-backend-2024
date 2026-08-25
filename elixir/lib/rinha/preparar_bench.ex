defmodule Rinha.PrepararBench do
  @moduledoc """
  Deixa o banco num estado conhecido e realista para o benchmark.

  Porte de `fastapi/app/preparar_bench.py`, e o estado final tem de ser
  **idêntico** ao que aquele produz: mesmas 50 transações por cliente, mesmos
  valores, mesma ordem de inserção. Se o Elixir medisse o extrato com uma lista
  de tamanho diferente, a comparação estaria medindo o payload, não a aplicação.

  Sem isto, `GET /clientes/1/extrato` devolveria lista vazia e mediria a
  serialização de quase nada. O contrato permite até 10 transações no extrato, e
  é esse o payload que queremos exercitar.

  Roda por `bin/rinha eval`, que carrega o código sem iniciar a aplicação — daí
  a conexão própria em vez do pool `Rinha.DB`.
  """

  # Mais que as 10 do extrato, para o ORDER BY + LIMIT ter o que descartar.
  @transacoes_por_cliente 50

  @spec run() :: :ok
  def run do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    opts =
      Rinha.Config.postgrex_opts()
      |> Keyword.put(:pool_size, 1)

    {:ok, conn} = Postgrex.start_link(opts)

    # RESTART IDENTITY para que os ids recomecem do 1 a cada rodada: o extrato
    # ordena por id, e ids crescentes entre repetições mudariam o custo do
    # índice ao longo da série.
    Postgrex.query!(conn, "TRUNCATE crebitos_transacao RESTART IDENTITY", [])
    Postgrex.query!(conn, "UPDATE crebitos_cliente SET saldo = 0", [])

    %Postgrex.Result{rows: linhas} =
      Postgrex.query!(conn, "SELECT id FROM crebitos_cliente ORDER BY id", [])

    ids = Enum.map(linhas, fn [id] -> id end)

    # A ordem de inserção importa: o extrato devolve as 10 de maior id, e é ela
    # que decide QUAIS transações entram na resposta medida.
    for id_cliente <- ids, i <- 0..(@transacoes_por_cliente - 1) do
      Postgrex.query!(
        conn,
        "INSERT INTO crebitos_transacao" <>
          " (cliente_id, valor, tipo, descricao, realizada_em)" <>
          " VALUES ($1, $2, $3, $4, now())",
        [id_cliente, 100, if(rem(i, 2) == 0, do: "c", else: "d"), descricao(i)]
      )
    end

    %Postgrex.Result{rows: [[total]]} =
      Postgrex.query!(conn, "SELECT count(*) FROM crebitos_transacao", [])

    IO.puts("ok: #{total} transações em #{length(ids)} clientes")
    :ok
  end

  # `bench0000`..`bench0049`, exatamente como o `f"bench{i:04d}"[:10]` do Python.
  defp descricao(i), do: "bench" <> String.pad_leading(Integer.to_string(i), 4, "0")
end
