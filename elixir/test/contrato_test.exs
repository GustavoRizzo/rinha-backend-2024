defmodule Rinha.ContratoTest do
  @moduledoc """
  O contrato HTTP do doc `02-regras.md`, endpoint a endpoint.

  Espelha `fastapi/tests/test_contrato.py`. Um caso que existe lá e não existe
  aqui seria uma diferença de cobertura entre projetos, e cobertura diferente
  invalida a comparação tanto quanto código diferente.
  """

  use Rinha.Caso, async: false

  describe "POST /clientes/:id/transacoes" do
    test "crédito devolve 200 com limite e saldo atualizados" do
      conn = transacionar(1, %{valor: 1000, tipo: "c", descricao: "salario"})

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"limite" => 100_000, "saldo" => 1000}
    end

    test "débito dentro do limite devolve 200 com saldo negativo" do
      conn = transacionar(1, %{valor: 1000, tipo: "d", descricao: "aluguel"})

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"limite" => 100_000, "saldo" => -1000}
    end

    test "débito que estoura o limite devolve 422 e NÃO altera o saldo" do
      conn = transacionar(1, %{valor: 100_001, tipo: "d", descricao: "caro"})

      assert conn.status == 422
      # A parte que importa: a recusa é atômica. Um 422 que tivesse debitado
      # metade seria pior que um 500.
      assert saldo_de(1) == 0
    end

    test "débito exatamente no limite é aceito" do
      conn = transacionar(1, %{valor: 100_000, tipo: "d", descricao: "limite"})

      assert conn.status == 200
      assert saldo_de(1) == -100_000
    end

    test "cliente inexistente devolve 404" do
      assert transacionar(6, %{valor: 1, tipo: "c", descricao: "x"}).status == 404
    end

    test "id não numérico devolve 404" do
      assert requisitar(:post, "/clientes/abc/transacoes", "{}").status == 404
    end

    test "payloads inválidos devolvem 422" do
      invalidos = [
        %{valor: 1.2, tipo: "c", descricao: "float"},
        %{valor: 0, tipo: "c", descricao: "zero"},
        %{valor: -5, tipo: "c", descricao: "negativo"},
        %{valor: true, tipo: "c", descricao: "booleano"},
        %{valor: "100", tipo: "c", descricao: "string"},
        %{valor: 100, tipo: "x", descricao: "tipo"},
        %{valor: 100, tipo: "c", descricao: "onze caracteres"},
        %{valor: 100, tipo: "c", descricao: ""},
        %{valor: 100, tipo: "c"},
        %{valor: 100, tipo: "c", descricao: nil}
      ]

      for payload <- invalidos do
        conn = transacionar(1, payload)
        assert conn.status == 422, "esperava 422 para #{inspect(payload)}"
      end
    end

    test "corpo que não é JSON devolve 422" do
      assert requisitar(:post, "/clientes/1/transacoes", "não é json").status == 422
    end

    test "descrição de 10 caracteres é aceita e a de 11 não" do
      assert transacionar(1, %{valor: 1, tipo: "c", descricao: "1234567890"}).status == 200
      assert transacionar(1, %{valor: 1, tipo: "c", descricao: "12345678901"}).status == 422
    end
  end

  describe "GET /clientes/:id/extrato" do
    test "cliente sem transações devolve saldo zero e lista vazia" do
      conn = requisitar(:get, "/clientes/1/extrato")
      corpo = Jason.decode!(conn.resp_body)

      assert conn.status == 200
      assert corpo["saldo"]["total"] == 0
      assert corpo["saldo"]["limite"] == 100_000
      assert corpo["ultimas_transacoes"] == []
      assert String.ends_with?(corpo["saldo"]["data_extrato"], "Z")
    end

    test "devolve no máximo 10 transações, da mais recente para a mais antiga" do
      for i <- 1..15 do
        transacionar(1, %{valor: i, tipo: "c", descricao: "t#{i}"})
      end

      corpo = Jason.decode!(requisitar(:get, "/clientes/1/extrato").resp_body)

      assert length(corpo["ultimas_transacoes"]) == 10
      # A 15ª é a primeira da lista; a 6ª é a última. As cinco primeiras ficaram
      # de fora.
      assert Enum.map(corpo["ultimas_transacoes"], & &1["valor"]) == Enum.to_list(15..6//-1)
    end

    test "read-your-writes: o extrato logo após o POST já enxerga a transação" do
      transacionar(1, %{valor: 777, tipo: "c", descricao: "agora"})
      corpo = Jason.decode!(requisitar(:get, "/clientes/1/extrato").resp_body)

      assert corpo["saldo"]["total"] == 777
      assert hd(corpo["ultimas_transacoes"])["valor"] == 777
    end

    test "cliente inexistente devolve 404" do
      assert requisitar(:get, "/clientes/6/extrato").status == 404
    end

    test "o campo realizada_em sai no formato do README" do
      transacionar(1, %{valor: 1, tipo: "c", descricao: "fmt"})
      corpo = Jason.decode!(requisitar(:get, "/clientes/1/extrato").resp_body)

      assert hd(corpo["ultimas_transacoes"])["realizada_em"] =~
               ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/
    end
  end

  describe "content-type" do
    test "é application/json puro, sem charset" do
      conn = requisitar(:get, "/clientes/1/extrato")
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json"]
    end
  end
end
