defmodule Rinha.Application do
  @moduledoc """
  A árvore de supervisão: o pool do Postgres e o servidor HTTP, nesta ordem.

  A ordem importa. O Bandit só passa a aceitar conexões depois que o Postgrex
  subiu, então o `curl` de prontidão do `just up` não pega uma janela em que a
  API responde 500 por não ter banco. É o equivalente do `lifespan` do FastAPI,
  que abre o pool antes de o uvicorn anunciar prontidão.
  """

  use Application

  require Logger

  alias Rinha.Config

  @impl true
  def start(_type, _args) do
    # Antes de qualquer processo: valida as variantes e aborta se não reconhecer
    # o que leu. Um valor com typo cairia no padrão e viraria número mentiroso.
    Config.carregar!()

    filhos = [
      {Postgrex, Keyword.put(Config.postgrex_opts(), :name, Rinha.DB)},
      servidor()
    ]

    with {:ok, pid} <- Supervisor.start_link(filhos, strategy: :one_for_one, name: Rinha.Supervisor) do
      if Config.verificar_clientes?(), do: Rinha.DB.verificar!(Rinha.DB)
      {:ok, pid}
    end
  end

  defp servidor do
    caminho = Config.bind()

    # Um socket Unix é um ARQUIVO. Se o container reiniciar sem que o volume
    # seja recriado, o arquivo antigo continua lá e o `bind` falha com
    # `:eaddrinuse` — falha que não tem nada a ver com porta ocupada e leva
    # meia hora para ser diagnosticada. Remover antes é o que o nginx e o
    # gunicorn também fazem.
    File.rm(caminho)
    File.mkdir_p!(Path.dirname(caminho))

    {Bandit,
     plug: Rinha.Router,
     scheme: :http,
     thousand_island_options: [
       # `port: 0` é obrigatório junto com `ip: {:local, _}`: o ThousandIsland
       # ainda passa uma porta para o `:gen_tcp`, e para uma família `:local`
       # ela precisa ser zero.
       port: 0,
       transport_options: [ip: {:local, caminho}],
       # Sob 0.40 CPU não há o que ganhar com muitos acceptors; o custo deles é
       # o mesmo dos 4 workers de Gunicorn que perderam para 1 em `django/04`.
       num_acceptors: 4
     ],
     http_options: [log_protocol_errors: false]}
  end
end
