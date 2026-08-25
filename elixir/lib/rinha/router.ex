defmodule Rinha.Router do
  @moduledoc """
  Os dois endpoints do contrato da Rinha, em `Plug.Router`.

  `Plug.Router` e não Phoenix, de propósito: o par estrutural do FastAPI (casca
  fina sobre Starlette) é Plug sobre Bandit; Phoenix é o par do Django, e a
  stack Django já existe. A justificativa completa está em
  `.claude/docs/performance/elixir/00-indice.md`, seção 1.

  Não há `Plug.Parsers` no pipeline: ele decodificaria o corpo antes de sabermos
  se o ID sequer existe, e traria multipart e urlencoded para um serviço que só
  fala JSON. O corpo é lido cru dentro do handler, como no FastAPI.
  """

  use Plug.Router

  alias Rinha.{Dominio, Hacks, Json}

  plug(:match)
  plug(:dispatch)

  # O corpo de 404 e 422 não é testado pela Rinha ("você pode escolher como o
  # representar"), então não gastamos CPU nem bytes serializando mensagem
  # alguma. Módulo de atributo: a string é montada em tempo de compilação.
  @tipo_json "application/json"

  post "/clientes/:id/transacoes" do
    # HACK DA RINHA: resolve o 404 sem tocar no banco. Ver `Rinha.Hacks`.
    with {:ok, id_cliente} <- id_valido(id),
         {:ok, corpo, conn} <- Plug.Conn.read_body(conn),
         {:ok, payload} <- Json.decode(corpo),
         {:ok, valor, tipo, descricao} <- Dominio.validar(payload) do
      case Dominio.transacao(Rinha.DB, id_cliente, valor, tipo, descricao) do
        {:ok, limite, saldo} ->
          responder(conn, 200, Json.encode(%{"limite" => limite, "saldo" => saldo}))

        :sem_limite ->
          vazio(conn, 422)
      end
    else
      :nao_encontrado -> vazio(conn, 404)
      _ -> vazio(conn, 422)
    end
  end

  get "/clientes/:id/extrato" do
    case id_valido(id) do
      :nao_encontrado ->
        vazio(conn, 404)

      {:ok, id_cliente} ->
        case Dominio.extrato(Rinha.DB, id_cliente) do
          {:ok, corpo} -> responder(conn, 200, corpo)
          :nao_encontrado -> vazio(conn, 404)
        end
    end
  end

  match _ do
    vazio(conn, 404)
  end

  # `Integer.parse` e não `String.to_integer`: um ID não numérico levantaria
  # exceção, e uma exceção por requisição inválida é 500 no Bandit, não 404.
  defp id_valido(id) do
    case Integer.parse(id) do
      {n, ""} -> if Hacks.cliente_existe?(n), do: {:ok, n}, else: :nao_encontrado
      _ -> :nao_encontrado
    end
  end

  # `put_resp_header` cru em vez de `put_resp_content_type`: este último anexa
  # `; charset=utf-8`, e as outras duas implementações mandam `application/json`
  # puro. Corpo de resposta diferente entre projetos mediria o cabeçalho.
  defp responder(conn, status, corpo) do
    conn
    |> put_resp_header("content-type", @tipo_json)
    |> send_resp(status, corpo)
  end

  defp vazio(conn, status), do: send_resp(conn, status, "")
end
