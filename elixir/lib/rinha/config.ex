defmodule Rinha.Config do
  @moduledoc """
  Configuração por variável de ambiente, lida uma vez na subida.

  Convenção do projeto (`CLAUDE.md`): configurações alternativas são **variáveis
  de ambiente, não branches**. Elas convivem no mesmo commit, e é isso que torna
  a comparação A/B possível — `bench-stack.sh` liga uma de cada vez sem trocar
  de código.

  As variantes ficam em `:persistent_term`, e não em `Application.get_env`, pelo
  motivo explicado em `config/runtime.exs`: o caminho quente lê isto em toda
  requisição.
  """

  @chave :rinha_config

  @doc "Lê o ambiente, valida e publica. Chamado uma vez, por `Rinha.Application`."
  @spec carregar!() :: :ok
  def carregar! do
    cfg = %{
      # `unica` — uma query só, com o array de transações já serializado em JSON
      #           pelo Postgres. Padrão porque foi o padrão eleito no FastAPI
      #           (`performance/fastapi/01`: 1,25x, com teste provando bytes
      #           idênticos). Repetir a escolha é o que mantém a comparação.
      # `duas`   — um SELECT do cliente, outro das 10 transações. Espelha o que o
      #            Django faz, e é a linha de base daquela comparação.
      extrato_query: opcao!("EXTRATO_QUERY", "unica", ~w(unica duas)),
      # `jason` — a biblioteca de fato do ecossistema, em Elixir puro com
      #           otimizações de compilação.
      # `otp`   — o módulo `JSON` da OTP 27, escrito em C dentro do runtime.
      # Paralelo do `SERIALIZACAO=orjson|stdlib` do FastAPI.
      json_lib: opcao!("JSON_LIB", "jason", ~w(jason otp))
    }

    :persistent_term.put(@chave, cfg)
    :ok
  end

  @spec extrato_query() :: String.t()
  def extrato_query, do: :persistent_term.get(@chave).extrato_query

  @spec json_lib() :: String.t()
  def json_lib, do: :persistent_term.get(@chave).json_lib

  # --- banco ---------------------------------------------------------------

  @doc """
  Opções do `Postgrex.start_link/1`.

  `pool_size` é o teto por instância, e a conta é 2 APIs × `DB_POOL_MAX` + folga
  de manutenção ≤ `max_connections = 20` do `infra/postgres/postgresql.conf`.
  Cada conexão no Postgres é um **processo do sistema operacional**, com ~5-10MB
  de overhead — num orçamento de 550MB isso é decisão de arquitetura.
  """
  @spec postgrex_opts() :: keyword()
  def postgrex_opts do
    [
      hostname: env("DB_HOST", "localhost"),
      port: inteiro!("DB_PORT", "5432"),
      database: env("DB_NAME", "rinha"),
      username: env("DB_USER", "rinha"),
      password: env("DB_PASSWORD", "rinha"),
      pool_size: inteiro!("DB_POOL_MAX", "8"),
      # As conexões vivem pelo tempo de vida do processo. `django/04` mediu
      # 4,75x entre conexão persistente e conexão nova por requisição.
      #
      # `prepare: :named` (padrão do Postgrex) mantém os statements preparados
      # em cache por conexão: as 5 queries deste projeto são preparadas uma vez
      # e reexecutadas, sem pagar parse+plan por requisição.
      prepare: :named,
      # Sem log de query, pelo mesmo motivo do `access_log off`.
      show_sensitive_data_on_connection_error: false,
      # A carga da Rinha tem picos; a fila do DBConnection é preferível a
      # estourar erro. 5s é folgado contra um SLA de 250ms — se chegarmos perto
      # disso, o problema já apareceu no percentil muito antes.
      queue_target: 50,
      queue_interval: 1000,
      timeout: 5_000
    ]
  end

  @doc "Aborta a subida se a carga inicial divergir do README (ver `Rinha.DB`)."
  @spec verificar_clientes?() :: boolean()
  def verificar_clientes?, do: env("VERIFICAR_CLIENTES", "1") == "1"

  @doc """
  Caminho do socket Unix em que o Bandit escuta.

  Socket Unix e não TCP porque `performance/django/03` mediu 2,9x em vazão alta
  no salto nginx->API, e a amplitude entre repetições caiu de 246% para 3,9%.
  """
  @spec bind() :: String.t()
  def bind do
    env("BANDIT_BIND", "unix:/sockets/api01.sock")
    |> String.replace_prefix("unix:", "")
  end

  # --- primitivas ----------------------------------------------------------

  defp env(nome, padrao), do: System.get_env(nome, padrao)

  # Toda opção desconhecida aborta, com o nome da variável e o valor recebido.
  #
  # Regra do projeto, aprendida na marra: três bugs deste repositório produziram
  # números plausíveis em vez de erro. Um `JSON_LIB=jasson` com typo cairia
  # silenciosamente no padrão e viraria uma linha de tabela mentirosa.
  defp opcao!(nome, padrao, aceitos) do
    valor = env(nome, padrao)

    if valor in aceitos do
      valor
    else
      abortar("#{nome}=#{inspect(valor)} desconhecido; aceitos: #{inspect(aceitos)}")
    end
  end

  defp inteiro!(nome, padrao) do
    valor = env(nome, padrao)

    case Integer.parse(valor) do
      {n, ""} when n > 0 -> n
      _ -> abortar("#{nome}=#{inspect(valor)} não é um inteiro positivo")
    end
  end

  # Exceção, e não `System.stop/1`: levantada de dentro de `Application.start/2`
  # ela impede a subida com código de saída diferente de zero, que é o que o
  # `just up` e o Compose esperam — e, ao contrário do `stop`, é observável num
  # teste.
  defp abortar(mensagem) do
    raise Rinha.ConfiguracaoInvalida, mensagem
  end
end

defmodule Rinha.ConfiguracaoInvalida do
  @moduledoc "Variável de ambiente com valor que a aplicação não reconhece."
  defexception [:message]
end
