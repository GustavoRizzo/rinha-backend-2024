// As quatro estratégias de concorrência do Bloco B do plano.
//
// Motivo de existirem: `.claude/docs/03-plano-implementacao.md` registra que a
// **maior lacuna do projeto** é o `UPDATE ... RETURNING` nunca ter sido
// comparado com as alternativas. A hipótese escrita lá — *"espero que B2 vença
// por larga margem"* — é hipótese desde o primeiro dia, sustentada apenas por
// zero inconsistências em 553.527 requisições, o que prova que ele é CORRETO e
// não que ele seja BARATO.
//
// Por que a comparação mora no projeto Go: é a stack com a aplicação mais
// barata (302,9 µs por escrita contra 862,4 do Django), então o custo da
// estratégia aparece limpo em vez de enterrado sob o custo do framework. Ver
// `performance/go/03`, seção 4.
//
// As quatro produzem o MESMO resultado observável — `concorrencia_test.go` roda
// a suíte inteira contra cada uma. O que muda é como o banco serializa os
// acessos concorrentes à mesma linha.
package main

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// --------------------------------------------------------------------------
// B1 — lock pessimista: SELECT ... FOR UPDATE
// --------------------------------------------------------------------------

// Lê a linha travando-a, decide na aplicação, grava. É o jeito "de manual", e o
// que a maioria escreve antes de pensar em concorrência.
//
// A janela entre ler e gravar existe, mas o lock a fecha: qualquer outra
// transação que peça a mesma linha espera no `FOR UPDATE`. Custa um round-trip
// a mais e mantém o lock aberto por todo o tempo de ida e volta até a
// aplicação — que é exatamente o que o `UPDATE ... RETURNING` evita.
const sqlSelectForUpdate = `
    SELECT saldo, limite FROM crebitos_cliente WHERE id = $1 FOR UPDATE
`

const sqlAtualizarSaldo = `
    UPDATE crebitos_cliente SET saldo = $1 WHERE id = $2
`

func transacaoSelectForUpdate(
	ctx context.Context, tx pgx.Tx, idCliente int32, t transacaoValidada, delta int32,
) (limite int32, saldo int32, erro error) {
	erro = tx.QueryRow(ctx, sqlSelectForUpdate, idCliente).Scan(&saldo, &limite)
	if errors.Is(erro, pgx.ErrNoRows) {
		return 0, 0, erroTransacaoInvalida
	}
	if erro != nil {
		return 0, 0, erro
	}

	novo := saldo + delta
	// A validação de limite acontece AQUI, na aplicação — e é correta só porque
	// a linha está travada. Sem o `FOR UPDATE` este seria o lost update clássico.
	if novo < -limite {
		return 0, 0, erroTransacaoInvalida
	}
	if _, erro := tx.Exec(ctx, sqlAtualizarSaldo, novo, idCliente); erro != nil {
		return 0, 0, erro
	}
	return limite, novo, nil
}

// --------------------------------------------------------------------------
// B2 — update atômico condicional (a estratégia das quatro stacks)
// --------------------------------------------------------------------------

func transacaoUpdateRetornando(
	ctx context.Context, tx pgx.Tx, idCliente int32, t transacaoValidada, delta int32,
) (limite int32, saldo int32, erro error) {
	sql := sqlCredito
	if t.Tipo == "d" {
		sql = sqlDebito
	}
	erro = tx.QueryRow(ctx, sql, delta, idCliente).Scan(&saldo, &limite)
	if errors.Is(erro, pgx.ErrNoRows) {
		return 0, 0, erroTransacaoInvalida
	}
	return limite, saldo, erro
}

// --------------------------------------------------------------------------
// B3 — advisory lock por cliente
// --------------------------------------------------------------------------

// `pg_advisory_xact_lock` trava um NÚMERO, não uma linha, e o solta no fim da
// transação. A diferença para o `FOR UPDATE` é conceitual: o lock não depende
// de a linha existir nem de qual tabela ela é, o que o torna útil quando a
// seção crítica cobre várias tabelas.
//
// Aqui ele custa um round-trip a mais que o `FOR UPDATE` — trava, lê, grava —
// e serializa exatamente a mesma coisa. A pergunta que ele responde é se o
// mecanismo de lock leve do Postgres é mais barato que o lock de linha.
const sqlAdvisoryLock = `SELECT pg_advisory_xact_lock($1)`

const sqlLerSaldo = `SELECT saldo, limite FROM crebitos_cliente WHERE id = $1`

func transacaoAdvisoryLock(
	ctx context.Context, tx pgx.Tx, idCliente int32, t transacaoValidada, delta int32,
) (limite int32, saldo int32, erro error) {
	if _, erro := tx.Exec(ctx, sqlAdvisoryLock, int64(idCliente)); erro != nil {
		return 0, 0, erro
	}
	erro = tx.QueryRow(ctx, sqlLerSaldo, idCliente).Scan(&saldo, &limite)
	if errors.Is(erro, pgx.ErrNoRows) {
		return 0, 0, erroTransacaoInvalida
	}
	if erro != nil {
		return 0, 0, erro
	}

	novo := saldo + delta
	if novo < -limite {
		return 0, 0, erroTransacaoInvalida
	}
	if _, erro := tx.Exec(ctx, sqlAtualizarSaldo, novo, idCliente); erro != nil {
		return 0, 0, erro
	}
	return limite, novo, nil
}

// --------------------------------------------------------------------------
// B4 — otimista: compare-and-swap sobre o próprio saldo
// --------------------------------------------------------------------------

// O plano previa "coluna de versão + retry". Aqui o CAS é sobre o **próprio
// saldo**, e não sobre uma coluna nova, por uma razão de método: acrescentar
// uma coluna mudaria `infra/sql/ddl.sql`, que é compartilhado pelas quatro
// stacks — a comparação entre linguagens passaria a ter schemas diferentes.
//
// O efeito é o mesmo: se alguém alterou o saldo entre a leitura e a escrita, o
// `WHERE saldo = $2` não casa, zero linhas voltam, e a operação é refeita. A
// diferença para uma coluna de versão é o problema ABA — dois créditos e um
// débito que devolvem o saldo ao valor original passariam despercebidos. Aqui
// isso é inofensivo: o resultado final é o mesmo número, que é tudo o que o
// saldo significa.
const sqlCASSaldo = `
    UPDATE crebitos_cliente SET saldo = $1 WHERE id = $2 AND saldo = $3
`

// Sem teto de tentativas não há garantia de término; com teto baixo demais, uma
// rajada legítima vira 500. 50 é folgado para 5 clientes: mesmo com 50
// requisições concorrentes na MESMA linha, cada retry só perde para quem
// commitou antes.
const maxTentativasOtimista = 50

func transacaoOtimista(
	ctx context.Context, conexao *pgxpool.Conn, idCliente int32, t transacaoValidada, delta int32,
	agora time.Time,
) (limite int32, saldo int32, erro error) {
	for tentativa := 0; tentativa < maxTentativasOtimista; tentativa++ {
		// A leitura fica FORA da transação de escrita de propósito: é isso que
		// caracteriza a estratégia otimista — não segurar nada enquanto pensa.
		var atual int32
		erro = conexao.QueryRow(ctx, sqlLerSaldo, idCliente).Scan(&atual, &limite)
		if errors.Is(erro, pgx.ErrNoRows) {
			return 0, 0, erroTransacaoInvalida
		}
		if erro != nil {
			return 0, 0, erro
		}

		novo := atual + delta
		if novo < -limite {
			return 0, 0, erroTransacaoInvalida
		}

		tx, erro := conexao.Begin(ctx)
		if erro != nil {
			return 0, 0, erro
		}
		etiqueta, erro := tx.Exec(ctx, sqlCASSaldo, novo, idCliente, atual)
		if erro != nil {
			tx.Rollback(ctx) //nolint:errcheck
			return 0, 0, erro
		}
		if etiqueta.RowsAffected() == 0 {
			// Alguém escreveu no meio. Desfaz e tenta de novo com o saldo novo.
			tx.Rollback(ctx) //nolint:errcheck
			continue
		}
		if _, erro := tx.Exec(ctx, sqlInserirTransacao,
			idCliente, t.Valor, t.Tipo, t.Descricao, agora); erro != nil {
			tx.Rollback(ctx) //nolint:errcheck
			return 0, 0, erro
		}
		if erro := tx.Commit(ctx); erro != nil {
			return 0, 0, erro
		}
		return limite, novo, nil
	}
	// Estourar o teto é falha de verdade, e vira 500 — não 422. Um 422 aqui
	// mentiria: a transação não foi recusada por limite, o servidor desistiu.
	return 0, 0, errors.New("concorrência otimista excedeu as tentativas")
}
