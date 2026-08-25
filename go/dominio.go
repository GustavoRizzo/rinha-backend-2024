// Regras de negócio dos crébitos, portadas de `fastapi/app/dominio.py`.
//
// A decisão central é a mesma nos quatro projetos, e é o que faz o teste de
// concorrência passar: o `saldo` é **desnormalizado** em `crebitos_cliente` e é
// a fonte da verdade, não um `SUM(transacoes.valor)`. Isso permite resolver
// débito + validação de limite num único `UPDATE ... WHERE ... RETURNING`, sem
// janela entre ler e gravar.
//
// O que muda em relação ao FastAPI e ao Elixir: nada de semântica. O SQL é
// caractere por caractere o mesmo. O que muda é quem o executa — pgx sobre o
// scheduler do Go, em vez de asyncpg sobre o uvloop ou Postgrex sobre a BEAM.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Limites do contrato (README da Rinha, seção "Transações").
const (
	descricaoTamanhoMax  = 10
	qtdTransacoesExtrato = 10
	formatoInstante      = "2006-01-02T15:04:05.000000Z"
)

var (
	// Payload fora da especificação, ou débito que estouraria o limite. A Rinha
	// usa o mesmo status (422) para os dois casos e não testa o corpo da
	// resposta, então não vale a pena separar em duas.
	erroTransacaoInvalida = errors.New("transação inválida")
	erroClienteAusente    = errors.New("cliente não encontrado")
)

// --------------------------------------------------------------------------
// Validação
// --------------------------------------------------------------------------

// payloadTransacao existe para separar "campo ausente" de "campo com valor
// zero": sem os ponteiros, `{"valor": 0}` e `{}` chegariam idênticos aqui.
//
// `json.RawMessage` no lugar de `int` guarda os BYTES do campo `valor` e
// adia a decisão para `validarValor`. Um `int` recusaria `true` mas também o
// `1.2`; um `float64` aceitaria os dois.
//
// E `json.Number` — que foi a primeira tentativa — aceita `{"valor": "1"}`,
// porque o decodificador do Go trata uma string numérica como número válido
// para aquele tipo. As outras três stacks recusam (`is_integer` em Elixir,
// `isinstance(valor, int)` em Python), e o teste `valor como string` pegou a
// divergência. Com os bytes crus a regra fica explícita: aspas não são número.
type payloadTransacao struct {
	Valor     *json.RawMessage `json:"valor"`
	Tipo      *string          `json:"tipo"`
	Descricao *string          `json:"descricao"`
}

type transacaoValidada struct {
	Valor     int32
	Tipo      string
	Descricao string
}

// validar faz as mesmas 6 verificações do Django, do FastAPI e do Elixir, sobre
// os bytes crus do corpo.
//
// Recebe bytes e não um mapa desserializado, ao contrário do Elixir: em Go o
// caminho natural é `Unmarshal` direto num struct, e passar por
// `map[string]any` alocaria uma interface por campo sem ganhar nada.
func validar(corpo []byte) (transacaoValidada, error) {
	var payload payloadTransacao
	if erro := json.Unmarshal(corpo, &payload); erro != nil {
		return transacaoValidada{}, erroTransacaoInvalida
	}
	if payload.Valor == nil || payload.Tipo == nil || payload.Descricao == nil {
		// Cobre também `"descricao": null`, um dos payloads inválidos do teste.
		return transacaoValidada{}, erroTransacaoInvalida
	}

	valor, ok := validarValor(*payload.Valor)
	if !ok {
		return transacaoValidada{}, erroTransacaoInvalida
	}
	if *payload.Tipo != "c" && *payload.Tipo != "d" {
		return transacaoValidada{}, erroTransacaoInvalida
	}
	// "string de 1 a 10 caracteres": `""` é tão inválido quanto o >10.
	// `RuneCountInString` conta pontos de código, que é o que o `len()` do
	// Python conta sobre `str` — `len(bytes)` daria outro número para acentos.
	tamanho := utf8.RuneCountInString(*payload.Descricao)
	if tamanho < 1 || tamanho > descricaoTamanhoMax {
		return transacaoValidada{}, erroTransacaoInvalida
	}

	return transacaoValidada{Valor: valor, Tipo: *payload.Tipo, Descricao: *payload.Descricao}, nil
}

// validarValor aceita apenas um literal JSON de número inteiro positivo.
//
// `ParseInt` com base 10 já recusa `1.2`, `1e3`, `true` e `null` — todos falham
// no parsing. A verificação de aspas vem antes porque `"1"` seria um inteiro
// válido DEPOIS de tirar as aspas, e o contrato pede um número, não uma string
// que se pareça com um.
func validarValor(bruto json.RawMessage) (int32, bool) {
	texto := string(bytes.TrimSpace(bruto))
	if texto == "" || texto[0] == '"' {
		return 0, false
	}
	// 32 bits porque a coluna `valor` é `integer` no schema
	// (`infra/sql/ddl.sql`): um valor maior seria recusado pelo banco, e o
	// contrato manda responder 422, não 500.
	valor, erro := strconv.ParseInt(texto, 10, 32)
	if erro != nil || valor <= 0 {
		return 0, false
	}
	return int32(valor), true
}

// --------------------------------------------------------------------------
// SQL — idêntico ao de `fastapi/app/dominio.py` e `elixir/lib/rinha/dominio.ex`
// --------------------------------------------------------------------------

// `RETURNING` no próprio `UPDATE`, e a condição do limite DENTRO da cláusula
// `WHERE`: não existe janela entre ler o saldo e gravá-lo, então não existe
// lost update. É o que a fase 1 do Gatling verifica (25 débitos simultâneos ->
// saldo exatamente -25). Ver `.claude/docs/01-fundamentos.md`, seção 4.
const sqlDebito = `
    UPDATE crebitos_cliente SET saldo = saldo + $1
     WHERE id = $2 AND saldo + $1 >= -limite
 RETURNING saldo, limite
`

// Crédito não tem teto: o limite só restringe o saldo por baixo.
const sqlCredito = `
    UPDATE crebitos_cliente SET saldo = saldo + $1
     WHERE id = $2
 RETURNING saldo, limite
`

const sqlInserirTransacao = `
    INSERT INTO crebitos_transacao (cliente_id, valor, tipo, descricao, realizada_em)
         VALUES ($1, $2, $3, $4, $5)
`

const sqlCliente = `SELECT saldo, limite FROM crebitos_cliente WHERE id = $1`

// `ORDER BY id DESC` e não `realizada_em DESC`: sob 340 req/s os timestamps
// empatam, e o Gatling verifica `ultimas_transacoes[0]` e `[1]` de duas
// transações feitas em sequência imediata. O `id` é monotônico e consistente
// com a ordem cronológica, e é exatamente o índice que existe
// (`idx_transacao_extrato`, em `cliente_id, id DESC`).
const sqlUltimasTransacoes = `
    SELECT valor, tipo, descricao, realizada_em
      FROM crebitos_transacao
     WHERE cliente_id = $1
  ORDER BY id DESC
     LIMIT 10
`

// Variante `EXTRATO_QUERY=unica`: um round-trip só, e o array de transações já
// volta como texto JSON pronto — a aplicação o embute na resposta sem
// desserializar e re-serializar 10 estruturas.
//
// O JSON é montado por concatenação, e não com `json_agg`, porque `json_agg`
// insere espaços entre os elementos e `json_build_object` separa chave e valor
// com `" : "`. Nenhum dos dois é errado — o Gatling faz parsing e não liga para
// espaço em branco — mas nós ligamos: as duas variantes precisam produzir **os
// mesmos bytes** para que a diferença medida seja o custo da query, e não o
// tamanho do corpo trafegado. `extrato_test.go` prova isso.
//
// A ordem das chaves é a do FastAPI (valor, tipo, descricao, realizada_em), e
// não a alfabética do Elixir: lá quem serializava na variante `duas` era uma
// biblioteca iterando um mapa da BEAM, que ordena por termo. Aqui a ordem é a
// dos campos do struct, então dá para seguir a do FastAPI — e assim as duas
// stacks trafegam exatamente os mesmos bytes.
const sqlExtratoUnico = `
    SELECT c.saldo,
           c.limite,
           COALESCE((
               SELECT '[' || string_agg(
                          '{"valor":' || t.valor
                       || ',"tipo":"' || t.tipo
                       || '","descricao":' || to_json(t.descricao)::text
                       || ',"realizada_em":"' || to_char(
                              t.realizada_em AT TIME ZONE 'UTC',
                              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
                       || '"}', ',' ORDER BY t.id DESC) || ']'
                 FROM (SELECT id, valor, tipo, descricao, realizada_em
                         FROM crebitos_transacao
                        WHERE cliente_id = c.id
                     ORDER BY id DESC
                        LIMIT 10) t
           ), '[]') AS ultimas
      FROM crebitos_cliente c
     WHERE c.id = $1
`

// --------------------------------------------------------------------------
// Operações
// --------------------------------------------------------------------------

type linhaTransacao struct {
	Valor       int32  `json:"valor"`
	Tipo        string `json:"tipo"`
	Descricao   string `json:"descricao"`
	RealizadaEm string `json:"realizada_em"`
}

// aplicarTransacao devolve `(limite, saldo)` já atualizados.
//
// A validação do payload acontece antes, no roteador: payload inválido não
// merece nem uma conexão do pool, quanto mais um round-trip.
func aplicarTransacao(
	ctx context.Context, pool *pgxpool.Pool, idCliente int32, t transacaoValidada,
) (limite int32, saldo int32, erro error) {
	delta := t.Valor
	sql := sqlCredito
	if t.Tipo == "d" {
		delta = -t.Valor
		sql = sqlDebito
	}
	agora := time.Now().UTC()

	conexao, erro := pool.Acquire(ctx)
	if erro != nil {
		return 0, 0, erro
	}
	defer conexao.Release()

	// A transação garante que não exista `UPDATE` confirmado sem o `INSERT`
	// correspondente — seria um saldo sem lastro no extrato, e o Gatling compara
	// os dois.
	tx, erro := conexao.Begin(ctx)
	if erro != nil {
		return 0, 0, erro
	}
	// Rollback depois de um Commit bem-sucedido é no-op no pgx; o defer existe
	// para os caminhos de erro, inclusive o `return` de limite estourado.
	defer tx.Rollback(ctx) //nolint:errcheck

	erro = tx.QueryRow(ctx, sql, delta, idCliente).Scan(&saldo, &limite)
	if errors.Is(erro, pgx.ErrNoRows) {
		// Zero linhas afetadas é ambíguo: cliente inexistente ou limite
		// estourado. Aqui, como nas outras stacks, não gastamos uma segunda
		// query para desambiguar — o roteador já barrou os IDs inválidos com
		// `clienteExiste` antes de tocar no banco.
		return 0, 0, erroTransacaoInvalida
	}
	if erro != nil {
		return 0, 0, erro
	}

	if _, erro := tx.Exec(ctx, sqlInserirTransacao, idCliente, t.Valor, t.Tipo, t.Descricao, agora); erro != nil {
		return 0, 0, erro
	}
	if erro := tx.Commit(ctx); erro != nil {
		return 0, 0, erro
	}
	return limite, saldo, nil
}

// extratoDuasQueries espelha o Django: um SELECT do cliente, outro das
// transações.
//
// As duas na MESMA conexão. Não é por consistência — em `read committed` cada
// statement já enxerga o último commit, que é o que o teste de read-your-writes
// exige — e sim para não pagar dois check-outs do pool.
func extratoDuasQueries(
	ctx context.Context, pool *pgxpool.Pool, idCliente int32,
) (saldo int32, limite int32, ultimas []linhaTransacao, erro error) {
	conexao, erro := pool.Acquire(ctx)
	if erro != nil {
		return 0, 0, nil, erro
	}
	defer conexao.Release()

	erro = conexao.QueryRow(ctx, sqlCliente, idCliente).Scan(&saldo, &limite)
	if errors.Is(erro, pgx.ErrNoRows) {
		return 0, 0, nil, erroClienteAusente
	}
	if erro != nil {
		return 0, 0, nil, erro
	}

	linhas, erro := conexao.Query(ctx, sqlUltimasTransacoes, idCliente)
	if erro != nil {
		return 0, 0, nil, erro
	}
	defer linhas.Close()

	// Capacidade exata: o `LIMIT` do SQL é o mesmo 10, então a fatia nunca
	// precisa crescer.
	ultimas = make([]linhaTransacao, 0, qtdTransacoesExtrato)
	for linhas.Next() {
		var t linhaTransacao
		var realizadaEm time.Time
		if erro := linhas.Scan(&t.Valor, &t.Tipo, &t.Descricao, &realizadaEm); erro != nil {
			return 0, 0, nil, erro
		}
		t.RealizadaEm = realizadaEm.UTC().Format(formatoInstante)
		ultimas = append(ultimas, t)
	}
	if erro := linhas.Err(); erro != nil {
		return 0, 0, nil, erro
	}
	return saldo, limite, ultimas, nil
}

// extratoQueryUnica devolve as transações como o texto JSON que o Postgres já
// montou, pronto para ser concatenado na resposta.
func extratoQueryUnica(
	ctx context.Context, pool *pgxpool.Pool, idCliente int32,
) (saldo int32, limite int32, ultimas string, erro error) {
	erro = pool.QueryRow(ctx, sqlExtratoUnico, idCliente).Scan(&saldo, &limite, &ultimas)
	if errors.Is(erro, pgx.ErrNoRows) {
		return 0, 0, "", erroClienteAusente
	}
	return saldo, limite, ultimas, erro
}

// agoraISO formata como o README: `2024-01-17T02:34:41.217753Z`.
//
// Seis casas de microssegundo SEMPRE, e não `time.RFC3339Nano`, que suprime
// zeros à direita: as duas variantes do extrato precisam produzir os mesmos
// bytes, e a `unica` recebe do `to_char` do Postgres um campo de largura fixa.
func agoraISO() string {
	return time.Now().UTC().Format(formatoInstante)
}
