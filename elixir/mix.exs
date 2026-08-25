defmodule Rinha.MixProject do
  # Projeto Mix da implementação em Elixir.
  #
  # O par estrutural aqui é o `fastapi/`, não o `django/`: uma casca fina sobre
  # um servidor HTTP, SQL cru, sem ORM e sem framework completo. A justificativa
  # está em `.claude/docs/performance/elixir/00-indice.md`, seção 1.
  use Mix.Project

  def project do
    [
      app: :rinha,
      version: "0.1.0",
      # 1.18 é o piso porque a variante `JSON_LIB=otp` usa o módulo `JSON`,
      # que só existe a partir dela (e exige OTP 27 por baixo).
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      # `:logger` só; nada de `:runtime_tools` ou `:observer` — cada aplicação
      # iniciada é memória, e o orçamento é de 100MB por instância.
      extra_applications: [:logger],
      mod: {Rinha.Application, []}
    ]
  end

  defp deps do
    [
      # Servidor HTTP. Papel do `uvicorn` no projeto FastAPI.
      {:bandit, "~> 1.6"},
      # A especificação servidor<->aplicação. Papel do ASGI/Starlette.
      {:plug, "~> 1.16"},
      # Driver do Postgres, com pool próprio (DBConnection). Papel do `asyncpg`.
      # NÃO usamos Ecto: o caminho quente dos outros dois projetos é SQL cru, e
      # trocar isso junto com a linguagem tornaria a diferença inatribuível.
      {:postgrex, "~> 0.20"},
      # Uma das duas variantes de JSON; a outra é o módulo `JSON` da OTP 27.
      {:jason, "~> 1.4"}
    ]
  end

  defp releases do
    [
      rinha: [
        # `:permanent` faz o VM inteiro morrer se a aplicação morrer, em vez de
        # ficar de pé servindo erro. É o comportamento que o `docker restart`
        # espera, e o mesmo que `exec uvicorn` dá ao FastAPI.
        applications: [rinha: :permanent],
        # Sem `:tar`: quem empacota é a imagem Docker.
        include_executables_for: [:unix]
      ]
    ]
  end
end
