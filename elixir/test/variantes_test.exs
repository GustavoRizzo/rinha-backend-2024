defmodule Rinha.VariantesTest do
  @moduledoc """
  As variantes medidas produzem o MESMO resultado.

  É o que autoriza compará-las depois: se `EXTRATO_QUERY=unica` e `duas`
  respondessem coisas diferentes, a diferença de CPU mediria a resposta, não a
  query. Espelha `fastapi/tests/test_variantes.py`.
  """

  use Rinha.Caso, async: false

  defp corpo_extrato(variantes) do
    com_variante(variantes, fn ->
      requisitar(:get, "/clientes/1/extrato").resp_body |> IO.iodata_to_binary()
    end)
  end

  test "as duas formas do extrato produzem os MESMOS BYTES" do
    for i <- 1..12, do: transacionar(1, %{valor: i, tipo: "c", descricao: "v#{i}"})

    unica = corpo_extrato(%{"EXTRATO_QUERY" => "unica"})
    duas = corpo_extrato(%{"EXTRATO_QUERY" => "duas"})

    # `data_extrato` é o instante da consulta e muda entre as duas chamadas: é o
    # único campo legitimamente diferente, e é removido antes da comparação.
    assert sem_data(unica) == sem_data(duas)
  end

  test "descrição com aspas e barra invertida é escapada igual nas duas formas" do
    # O `to_json()` do Postgres é quem escapa na variante `unica`; a biblioteca
    # de JSON é quem escapa na `duas`. É o caso em que elas poderiam divergir.
    assert transacionar(1, %{valor: 1, tipo: "c", descricao: ~S("a\b)}).status == 200

    assert sem_data(corpo_extrato(%{"EXTRATO_QUERY" => "unica"})) ==
             sem_data(corpo_extrato(%{"EXTRATO_QUERY" => "duas"}))
  end

  test "as duas bibliotecas de JSON produzem os mesmos bytes" do
    for i <- 1..3, do: transacionar(1, %{valor: i, tipo: "c", descricao: "j#{i}"})

    jason = corpo_extrato(%{"EXTRATO_QUERY" => "duas", "JSON_LIB" => "jason"})
    otp = corpo_extrato(%{"EXTRATO_QUERY" => "duas", "JSON_LIB" => "otp"})

    assert sem_data(jason) == sem_data(otp)
  end

  test "as duas bibliotecas de JSON aceitam e recusam os mesmos payloads" do
    for lib <- ~w(jason otp) do
      com_variante(%{"JSON_LIB" => lib}, fn ->
        assert transacionar(5, %{valor: 1, tipo: "c", descricao: "ok"}).status == 200
        assert requisitar(:post, "/clientes/5/transacoes", "{").status == 422
        assert transacionar(5, %{valor: 1.5, tipo: "c", descricao: "float"}).status == 422
      end)
    end
  end

  test "configuração desconhecida aborta em vez de cair no padrão" do
    # A regra do projeto: todo componente de medição deve abortar quando não
    # reconhecer o que está lendo. Três bugs deste repositório produziram
    # números plausíveis em vez de erro.
    System.put_env("EXTRATO_QUERY", "unicaa")

    try do
      assert_raise Rinha.ConfiguracaoInvalida, ~r/EXTRATO_QUERY/, &Rinha.Config.carregar!/0
    after
      System.delete_env("EXTRATO_QUERY")
      Rinha.Config.carregar!()
    end
  end

  defp sem_data(corpo), do: String.replace(corpo, ~r/"data_extrato":"[^"]+"/, "")
end
