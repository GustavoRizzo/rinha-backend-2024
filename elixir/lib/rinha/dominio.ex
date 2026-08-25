defmodule Rinha.Dominio do
  @moduledoc """
  Regras de negócio dos crébitos, portadas de `fastapi/app/dominio.py`.

  A decisão central é a mesma nos três projetos, e é o que faz o teste de
  concorrência passar: o `saldo` é **desnormalizado** em `crebitos_cliente` e é
  a fonte da verdade, não um `SUM(transacoes.valor)`. Isso permite resolver
  débito + validação de limite num único `UPDATE ... WHERE ... RETURNING`, sem
  janela entre ler e gravar.

  O que muda em relação ao FastAPI: nada de semântica. O SQL é caractere por
  caractere o mesmo. O que muda é quem o executa — Postgrex sobre a BEAM em vez
  de asyncpg sobre o loop do uvloop.
  """

  alias Rinha.Config

  # Limites do contrato (README da Rinha, seção "Transações").
  @tipos_validos ~w(c d)
  @descricao_tamanho_max 10
  @qtd_transacoes_extrato 10

  def qtd_transacoes_extrato, do: @qtd_transacoes_extrato

  # --------------------------------------------------------------------------
  # Validação
  # --------------------------------------------------------------------------

  @doc """
  As mesmas 6 verificações do Django e do FastAPI, sobre um corpo já
  desserializado.

  Não existe variante "com biblioteca de validação" aqui, ao contrário do
  `VALIDACAO=pydantic` do FastAPI: o equivalente no ecossistema Elixir seria um
  changeset do Ecto, e este projeto não usa Ecto (ver
  `.claude/docs/performance/elixir/00-indice.md`, seção 1).
  """
  @spec validar(term()) :: {:ok, pos_integer(), String.t(), String.t()} | :erro
  def validar(%{"valor" => valor, "tipo" => tipo, "descricao" => descricao})
      when is_integer(valor) and valor > 0 and
             is_binary(tipo) and is_binary(descricao) do
    # `is_integer` já barra float e booleano de graça: ao contrário do Python,
    # em Elixir `true` não é um inteiro e `1.0` não é `1`. As duas verificações
    # extras que o `validar_manual` do FastAPI precisa fazer não existem aqui.
    cond do
      tipo not in @tipos_validos -> :erro
      # "string de 1 a 10 caracteres": `""` é tão inválido quanto o >10.
      # `String.length/1` conta grafemas, não bytes — é o que "caracteres"
      # significa, e o que o Python faz com `len()` sobre `str`.
      String.length(descricao) not in 1..@descricao_tamanho_max -> :erro
      true -> {:ok, valor, tipo, descricao}
    end
  end

  def validar(_), do: :erro

  # --------------------------------------------------------------------------
  # SQL — idêntico ao de `fastapi/app/dominio.py`
  # --------------------------------------------------------------------------

  # `RETURNING` no próprio `UPDATE`, e a condição do limite DENTRO da cláusula
  # `WHERE`: não existe janela entre ler o saldo e gravá-lo, então não existe
  # lost update. É o que a fase 1 do Gatling verifica (25 débitos simultâneos ->
  # saldo exatamente -25). Ver `.claude/docs/01-fundamentos.md`, seção 4.
  @sql_debito """
      UPDATE crebitos_cliente SET saldo = saldo + $1
       WHERE id = $2 AND saldo + $1 >= -limite
   RETURNING saldo, limite
  """

  # Crédito não tem teto: o limite só restringe o saldo por baixo.
  @sql_credito """
      UPDATE crebitos_cliente SET saldo = saldo + $1
       WHERE id = $2
   RETURNING saldo, limite
  """

  @sql_inserir_transacao """
      INSERT INTO crebitos_transacao (cliente_id, valor, tipo, descricao, realizada_em)
           VALUES ($1, $2, $3, $4, $5)
  """

  @sql_cliente "SELECT saldo, limite FROM crebitos_cliente WHERE id = $1"

  # `ORDER BY id DESC` e não `realizada_em DESC`: sob 340 req/s os timestamps
  # empatam, e o Gatling verifica `ultimas_transacoes[0]` e `[1]` de duas
  # transações feitas em sequência imediata. O `id` é monotônico e consistente
  # com a ordem cronológica, e é exatamente o índice que existe
  # (`idx_transacao_extrato`, em `cliente_id, id DESC`).
  @sql_ultimas_transacoes """
      SELECT valor, tipo, descricao, realizada_em
        FROM crebitos_transacao
       WHERE cliente_id = $1
    ORDER BY id DESC
       LIMIT #{@qtd_transacoes_extrato}
  """

  # Variante `EXTRATO_QUERY=unica`: um round-trip só, e o array de transações já
  # volta como texto JSON pronto — a aplicação o embute na resposta sem
  # desserializar e re-serializar 10 estruturas.
  #
  # O JSON é montado por concatenação, e não com `json_agg`, porque `json_agg`
  # insere espaços entre os elementos e `json_build_object` separa chave e valor
  # com `" : "`. Nenhum dos dois é errado — o Gatling faz parsing e não liga para
  # espaço em branco — mas nós ligamos: as duas variantes precisam produzir **os
  # mesmos bytes** para que a diferença medida seja o custo da query, e não o
  # tamanho do corpo trafegado. `test/extrato_test.exs` prova isso.
  #
  # A ORDEM DAS CHAVES aqui é alfabética, e difere da do FastAPI. Motivo: na
  # variante `duas` quem serializa é a biblioteca de JSON, iterando um mapa — e
  # mapas pequenos da BEAM guardam as chaves ordenadas por termo. Para as duas
  # variantes darem os mesmos bytes, esta precisa seguir a mesma ordem. A ordem
  # de chaves de um objeto JSON não faz parte do contrato.
  #
  # `to_json(t.descricao)` em vez de aspas na mão: é ele que escapa aspas e
  # barras invertidas dentro da descrição. Os outros campos não precisam.
  # `to_char` existe porque um timestamptz em JSON sai com `+00:00`, e o
  # contrato do README mostra `Z`.
  @sql_extrato_unico """
      SELECT c.saldo,
             c.limite,
             COALESCE((
                 SELECT '[' || string_agg(
                            '{"descricao":' || to_json(t.descricao)::text
                         || ',"realizada_em":"' || to_char(
                                t.realizada_em AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
                         || '","tipo":"' || t.tipo
                         || '","valor":' || t.valor
                         || '}', ',' ORDER BY t.id DESC) || ']'
                   FROM (SELECT id, valor, tipo, descricao, realizada_em
                           FROM crebitos_transacao
                          WHERE cliente_id = c.id
                       ORDER BY id DESC
                          LIMIT #{@qtd_transacoes_extrato}) t
             ), '[]') AS ultimas
        FROM crebitos_cliente c
       WHERE c.id = $1
  """

  # --------------------------------------------------------------------------
  # Operações
  # --------------------------------------------------------------------------

  @doc """
  Aplica uma transação e devolve `{:ok, limite, saldo}` já atualizados.

  A validação do payload acontece antes, no roteador: payload inválido não
  merece nem um check-out do pool, quanto mais um round-trip.
  """
  @spec transacao(term(), integer(), pos_integer(), String.t(), String.t()) ::
          {:ok, integer(), integer()} | :sem_limite
  def transacao(conn, id_cliente, valor, tipo, descricao) do
    delta = if tipo == "c", do: valor, else: -valor
    sql = if tipo == "c", do: @sql_credito, else: @sql_debito
    agora = DateTime.utc_now()

    # A transação garante que não exista `UPDATE` confirmado sem o `INSERT`
    # correspondente — seria um saldo sem lastro no extrato, e o Gatling compara
    # os dois.
    resultado =
      Postgrex.transaction(conn, fn tx ->
        case Postgrex.query!(tx, sql, [delta, id_cliente]) do
          # Zero linhas afetadas é ambíguo: cliente inexistente ou limite
          # estourado. Aqui, como no FastAPI, não gastamos uma segunda query
          # para desambiguar — o roteador já barrou os IDs inválidos com
          # `Rinha.Hacks.cliente_existe?/1` antes de tocar no banco.
          %Postgrex.Result{rows: []} ->
            # `rollback` desfaz a transação vazia e sai por `{:error, :sem_limite}`.
            Postgrex.rollback(tx, :sem_limite)

          %Postgrex.Result{rows: [[saldo, limite]]} ->
            Postgrex.query!(tx, @sql_inserir_transacao, [
              id_cliente,
              valor,
              tipo,
              descricao,
              agora
            ])

            {limite, saldo}
        end
      end)

    case resultado do
      {:ok, {limite, saldo}} -> {:ok, limite, saldo}
      {:error, :sem_limite} -> :sem_limite
    end
  end

  @doc """
  `EXTRATO_QUERY=duas` — espelha o Django: um SELECT do cliente, outro das
  transações.

  As duas na MESMA conexão. Não é por consistência — em `read committed` cada
  statement já enxerga o último commit, que é o que o teste de read-your-writes
  exige — e sim para não pagar dois check-outs do pool.
  """
  @spec extrato_duas_queries(term(), integer()) ::
          {:ok, integer(), integer(), [list()]} | :nao_encontrado
  def extrato_duas_queries(pool, id_cliente) do
    Postgrex.transaction(pool, fn conn ->
      case Postgrex.query!(conn, @sql_cliente, [id_cliente]) do
        %Postgrex.Result{rows: []} ->
          Postgrex.rollback(conn, :nao_encontrado)

        %Postgrex.Result{rows: [[saldo, limite]]} ->
          %Postgrex.Result{rows: ultimas} =
            Postgrex.query!(conn, @sql_ultimas_transacoes, [id_cliente])

          {saldo, limite, ultimas}
      end
    end)
    |> case do
      {:ok, {saldo, limite, ultimas}} -> {:ok, saldo, limite, ultimas}
      {:error, :nao_encontrado} -> :nao_encontrado
    end
  end

  @doc "`EXTRATO_QUERY=unica` — um round-trip, transações já em JSON pronto."
  @spec extrato_query_unica(term(), integer()) ::
          {:ok, integer(), integer(), String.t()} | :nao_encontrado
  def extrato_query_unica(pool, id_cliente) do
    case Postgrex.query!(pool, @sql_extrato_unico, [id_cliente]) do
      %Postgrex.Result{rows: []} -> :nao_encontrado
      %Postgrex.Result{rows: [[saldo, limite, ultimas]]} -> {:ok, saldo, limite, ultimas}
    end
  end

  @doc "Despacha para a variante escolhida por `EXTRATO_QUERY`."
  @spec extrato(term(), integer()) :: {:ok, iodata()} | :nao_encontrado
  def extrato(pool, id_cliente) do
    case Config.extrato_query() do
      "unica" -> extrato_unico(pool, id_cliente)
      "duas" -> extrato_duplo(pool, id_cliente)
    end
  end

  # Concatena a string JSON que o Postgres já montou.
  #
  # Interpolação de iodata em vez de `Jason.encode!`: as transações já são JSON
  # válido vindo do banco, e desserializá-las só para re-serializar seria pagar
  # o trabalho duas vezes. `send_resp/3` aceita iodata, então nem a concatenação
  # acontece — a lista vai direto para o socket.
  defp extrato_unico(pool, id_cliente) do
    case extrato_query_unica(pool, id_cliente) do
      :nao_encontrado ->
        :nao_encontrado

      {:ok, saldo, limite, ultimas} ->
        {:ok,
         [
           ~s({"saldo":{"data_extrato":"),
           agora_iso(),
           ~s(","limite":),
           Integer.to_string(limite),
           ~s(,"total":),
           Integer.to_string(saldo),
           ~s(},"ultimas_transacoes":),
           ultimas,
           ?}
         ]}
    end
  end

  defp extrato_duplo(pool, id_cliente) do
    case extrato_duas_queries(pool, id_cliente) do
      :nao_encontrado ->
        :nao_encontrado

      {:ok, saldo, limite, ultimas} ->
        {:ok,
         Rinha.Json.encode(%{
           "saldo" => %{
             # Instante da consulta, não uma coluna do banco.
             "total" => saldo,
             "data_extrato" => agora_iso(),
             "limite" => limite
           },
           "ultimas_transacoes" =>
             Enum.map(ultimas, fn [valor, tipo, descricao, realizada_em] ->
               %{
                 "valor" => valor,
                 "tipo" => tipo,
                 "descricao" => descricao,
                 "realizada_em" => DateTime.to_iso8601(realizada_em)
               }
             end)
         })}
    end
  end

  @doc """
  Formata como o README: `2024-01-17T02:34:41.217753Z`.

  `DateTime.utc_now/0` já vem com precisão de microssegundo e deslocamento zero,
  então `to_iso8601/1` produz o sufixo `Z` do exemplo. O Gatling não verifica o
  formato, mas seguir o contrato é de graça.
  """
  @spec agora_iso() :: String.t()
  def agora_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
