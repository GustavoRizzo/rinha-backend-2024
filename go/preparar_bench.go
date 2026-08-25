// Deixa o banco num estado conhecido e realista para o benchmark.
//
// Porte de `fastapi/app/preparar_bench.py` e `elixir/lib/rinha/preparar_bench.ex`,
// e o estado final tem de ser **idêntico** ao que aqueles produzem: mesmas 50
// transações por cliente, mesmos valores, mesma ordem de inserção. Se o Go
// medisse o extrato com uma lista de tamanho diferente, a comparação estaria
// medindo o payload, não a aplicação.
//
// Sem isto, `GET /clientes/1/extrato` devolveria lista vazia e mediria a
// serialização de quase nada. O contrato permite até 10 transações no extrato,
// e é esse o payload que queremos exercitar.
package main

import "fmt"

// Mais que as 10 do extrato, para o ORDER BY + LIMIT ter o que descartar.
const transacoesPorCliente = 50

func prepararBench() error {
	cfg, erro := carregarConfig()
	if erro != nil {
		return erro
	}
	// Uma conexão só: este comando roda antes da carga, não durante, e um pool
	// aqui só disputaria as 20 conexões do `postgresql.conf` com a API que já
	// pode estar de pé no mesmo container.
	cfg.DBPoolMax = 1
	cfg.DBPoolMin = 1

	ctx, cancelar := contextoCurto()
	defer cancelar()

	pool, erro := criarPool(ctx, cfg)
	if erro != nil {
		return erro
	}
	defer pool.Close()

	// RESTART IDENTITY para que os ids recomecem do 1 a cada rodada: o extrato
	// ordena por id, e ids crescentes entre repetições mudariam o custo do
	// índice ao longo da série.
	if _, erro := pool.Exec(ctx, "TRUNCATE crebitos_transacao RESTART IDENTITY"); erro != nil {
		return erro
	}
	if _, erro := pool.Exec(ctx, "UPDATE crebitos_cliente SET saldo = 0"); erro != nil {
		return erro
	}

	linhas, erro := pool.Query(ctx, "SELECT id FROM crebitos_cliente ORDER BY id")
	if erro != nil {
		return erro
	}
	var ids []int32
	for linhas.Next() {
		var id int32
		if erro := linhas.Scan(&id); erro != nil {
			linhas.Close()
			return erro
		}
		ids = append(ids, id)
	}
	linhas.Close()
	if erro := linhas.Err(); erro != nil {
		return erro
	}

	// A ordem de inserção importa: o extrato devolve as 10 de maior id, e é ela
	// que decide QUAIS transações entram na resposta medida. Um `INSERT` por
	// vez, em sequência, como nas outras duas stacks — `CopyFrom` seria mais
	// rápido e não garante a mesma atribuição de ids.
	const sql = `INSERT INTO crebitos_transacao` +
		` (cliente_id, valor, tipo, descricao, realizada_em)` +
		` VALUES ($1, $2, $3, $4, now())`

	for _, idCliente := range ids {
		for i := range transacoesPorCliente {
			tipo := "c"
			if i%2 != 0 {
				tipo = "d"
			}
			// `bench0000`..`bench0049`, exatamente como o `f"bench{i:04d}"[:10]`
			// do Python: 9 caracteres, dentro do limite de 10 do contrato.
			descricao := fmt.Sprintf("bench%04d", i)
			if _, erro := pool.Exec(ctx, sql, idCliente, 100, tipo, descricao); erro != nil {
				return erro
			}
		}
	}

	var total int64
	if erro := pool.QueryRow(ctx, "SELECT count(*) FROM crebitos_transacao").Scan(&total); erro != nil {
		return erro
	}
	fmt.Printf("ok: %d transações em %d clientes\n", total, len(ids))
	return nil
}
