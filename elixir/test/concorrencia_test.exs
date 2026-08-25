defmodule Rinha.ConcorrenciaTest do
  @moduledoc """
  Os testes que justificam a estratégia de concorrência.

  Porte de `fastapi/tests/test_concorrencia.py`, que por sua vez porta os do
  Django. São a razão de o `saldo` ser desnormalizado e de o débito ser um
  `UPDATE ... WHERE ... RETURNING`: nenhuma dessas asserções passa com
  read-modify-write sob `READ COMMITTED`.

  Ver `.claude/docs/01-fundamentos.md`, seção 4.
  """

  use Rinha.Caso, async: false

  # Um teste de corrida que roda uma vez pode passar por sorte. Estes rodam
  # dezenas de operações simultâneas, que é o regime em que o lost update
  # aparece.
  @timeout 30_000

  test "25 débitos simultâneos deixam o saldo em exatamente -25" do
    # É a fase 1 da simulação oficial do Gatling, reproduzida em teste. Com
    # read-modify-write o resultado seria algum valor entre -1 e -25.
    1..25
    |> Task.async_stream(fn _ -> transacionar(1, %{valor: 1, tipo: "d", descricao: "d"}) end,
      max_concurrency: 25,
      timeout: @timeout
    )
    |> Enum.each(fn {:ok, conn} -> assert conn.status == 200 end)

    assert saldo_de(1) == -25
  end

  test "caso adversarial: 100 débitos disputando um limite que só cabe 80" do
    # Cliente 2 tem limite 80.000. Cem débitos de 1.000 pedem 100.000: 80 têm de
    # passar e 20 têm de ser recusadas — e o saldo tem de parar exatamente no
    # limite, nunca abaixo.
    #
    # Este é o teste que separa "atômico" de "quase atômico": uma janela entre
    # ler e gravar deixa passar a 81ª.
    resultados =
      1..100
      |> Task.async_stream(
        fn _ -> transacionar(2, %{valor: 1000, tipo: "d", descricao: "d"}).status end,
        max_concurrency: 50,
        timeout: @timeout
      )
      |> Enum.map(fn {:ok, status} -> status end)

    assert Enum.count(resultados, &(&1 == 200)) == 80
    assert Enum.count(resultados, &(&1 == 422)) == 20
    assert saldo_de(2) == -80_000
  end

  test "créditos e débitos simultâneos somam certo" do
    # 50 créditos de 100 e 50 débitos de 100 sobre o cliente 3, embaralhados: o
    # saldo final tem de ser zero. Verifica que a soma não perde escritas quando
    # as duas direções disputam a mesma linha.
    operacoes = Enum.shuffle(List.duplicate("c", 50) ++ List.duplicate("d", 50))

    operacoes
    |> Task.async_stream(
      fn tipo -> transacionar(3, %{valor: 100, tipo: tipo, descricao: "mix"}) end,
      max_concurrency: 50,
      timeout: @timeout
    )
    |> Enum.each(fn {:ok, conn} -> assert conn.status == 200 end)

    assert saldo_de(3) == 0
  end

  test "toda transação confirmada tem lastro no extrato" do
    # O Gatling compara saldo e extrato. Um `UPDATE` confirmado sem o `INSERT`
    # correspondente seria saldo sem lastro — a razão de as duas operações
    # estarem na mesma transação de banco.
    1..40
    |> Task.async_stream(fn _ -> transacionar(4, %{valor: 10, tipo: "c", descricao: "l"}) end,
      max_concurrency: 20,
      timeout: @timeout
    )
    |> Stream.run()

    %Postgrex.Result{rows: [[qtd, soma]]} =
      Postgrex.query!(
        Rinha.DB,
        "SELECT count(*), COALESCE(sum(valor), 0) FROM crebitos_transacao WHERE cliente_id = 4",
        []
      )

    assert qtd == 40
    assert soma == saldo_de(4)
  end
end
