defmodule Rinha.Json do
  @moduledoc """
  As duas variantes de JSON, atrás de uma interface só.

  Paralelo do `SERIALIZACAO=orjson|stdlib` do FastAPI, e a hipótese é a mesma:
  num payload de 2 campos (a resposta do POST) a escolha não deve aparecer, e no
  extrato talvez apareça. Medição, não fé.

  - `jason` — a biblioteca de fato do ecossistema, em Elixir puro.
  - `otp`   — o módulo `JSON` da OTP 27, implementado dentro do runtime.

  Sempre `_to_iodata`: `Plug.Conn.send_resp/3` aceita iodata, então a lista de
  fragmentos vai direto para o socket sem uma cópia final para binário.
  """

  alias Rinha.Config

  @spec encode(term()) :: iodata()
  def encode(termo) do
    case Config.json_lib() do
      "jason" -> Jason.encode_to_iodata!(termo)
      "otp" -> JSON.encode_to_iodata!(termo)
    end
  end

  @doc """
  Devolve `:erro` em vez de exceção: corpo malformado é 422, e é um caminho
  esperado do contrato (o Gatling manda payloads inválidos de propósito), não
  uma condição excepcional.
  """
  @spec decode(binary()) :: {:ok, term()} | :erro
  def decode(bin) do
    resultado =
      case Config.json_lib() do
        "jason" -> Jason.decode(bin)
        "otp" -> JSON.decode(bin)
      end

    case resultado do
      {:ok, termo} -> {:ok, termo}
      {:error, _} -> :erro
    end
  end
end
