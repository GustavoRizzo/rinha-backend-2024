// Os testes que justificam a estratégia de concorrência.
//
// Porte de `elixir/test/concorrencia_test.exs` e
// `fastapi/tests/test_concorrencia.py`. São a razão de o `saldo` ser
// desnormalizado e de o débito ser um `UPDATE ... WHERE ... RETURNING`: nenhuma
// dessas asserções passa com read-modify-write sob `READ COMMITTED`.
//
// Ver `.claude/docs/01-fundamentos.md`, seção 4.
package main

import (
	"context"
	"math/rand/v2"
	"net/http"
	"sync"
	"testing"
)

// dispararEmParalelo executa `n` requisições ao mesmo tempo e devolve os status
// na ordem de conclusão.
//
// Um teste de corrida que roda uma vez pode passar por sorte; estes rodam
// dezenas de operações simultâneas, que é o regime em que o lost update
// aparece. O `WaitGroup` de largada garante que as goroutines cheguem juntas em
// vez de escalonadas.
func dispararEmParalelo(n int, requisicao func(i int) int) []int {
	var largada sync.WaitGroup
	var fim sync.WaitGroup
	largada.Add(1)

	status := make([]int, n)
	for i := range n {
		fim.Add(1)
		go func() {
			defer fim.Done()
			largada.Wait()
			status[i] = requisicao(i)
		}()
	}
	largada.Done()
	fim.Wait()
	return status
}

// estrategias são as quatro do Bloco B. Os testes de concorrência rodam contra
// TODAS: é isso que autoriza compará-las depois. Uma estratégia que perde uma
// escrita é mais rápida por não fazer o trabalho, e o número dela seria
// mentira.
var estrategias = []string{"update-returning", "select-for-update", "advisory-lock", "otimista"}

// porEstrategia roda o mesmo corpo de teste contra cada estratégia, com o banco
// zerado antes de cada uma.
func porEstrategia(t *testing.T, corpo func(*testing.T, http.Handler)) {
	t.Helper()
	for _, estrategia := range estrategias {
		t.Run(estrategia, func(t *testing.T) {
			zerar(t)
			h := servidorDe(t, func(c *Config) { c.Estrategia = estrategia })
			corpo(t, h)
		})
	}
}

func TestVinteECincoDebitosSimultaneos(t *testing.T) {
	h := caso(t)

	// É a fase 1 da simulação oficial do Gatling, reproduzida em teste. Com
	// read-modify-write o resultado seria algum valor entre -1 e -25.
	status := dispararEmParalelo(25, func(int) int {
		return transacionar(h, 1, `{"valor":1,"tipo":"d","descricao":"d"}`).Code
	})
	for _, s := range status {
		if s != http.StatusOK {
			t.Fatalf("status %d, esperado 200 em todos", s)
		}
	}
	if saldo := saldoDe(t, 1); saldo != -25 {
		t.Errorf("saldo %d, esperado exatamente -25", saldo)
	}

	// E a volta: 25 créditos simultâneos devolvem o saldo a zero.
	dispararEmParalelo(25, func(int) int {
		return transacionar(h, 1, `{"valor":1,"tipo":"c","descricao":"c"}`).Code
	})
	if saldo := saldoDe(t, 1); saldo != 0 {
		t.Errorf("saldo %d depois dos créditos, esperado 0", saldo)
	}
}

func TestCasoAdversarial100DebitosParaUmLimiteDe80(t *testing.T) {
	h := caso(t)

	// Cliente 2 tem limite 80.000. Cem débitos de 1.000 pedem 100.000: 80 têm de
	// passar e 20 têm de ser recusados — e o saldo tem de parar exatamente no
	// limite, nunca abaixo.
	//
	// Este é o teste que separa "atômico" de "quase atômico": uma janela entre
	// ler e gravar deixa passar a 81ª.
	status := dispararEmParalelo(100, func(int) int {
		return transacionar(h, 2, `{"valor":1000,"tipo":"d","descricao":"d"}`).Code
	})

	var aceitos, recusados int
	for _, s := range status {
		switch s {
		case http.StatusOK:
			aceitos++
		case http.StatusUnprocessableEntity:
			recusados++
		default:
			t.Fatalf("status inesperado: %d", s)
		}
	}
	if aceitos != 80 || recusados != 20 {
		t.Errorf("%d aceitos e %d recusados, esperado 80 e 20", aceitos, recusados)
	}
	if saldo := saldoDe(t, 2); saldo != -80_000 {
		t.Errorf("saldo %d, esperado exatamente -80000", saldo)
	}
}

func TestCreditosEDebitosSimultaneosSomamCerto(t *testing.T) {
	h := caso(t)

	// 50 créditos de 100 e 50 débitos de 100 sobre o cliente 3, embaralhados: o
	// saldo final tem de ser zero. Verifica que a soma não perde escritas quando
	// as duas direções disputam a mesma linha.
	operacoes := make([]string, 0, 100)
	for range 50 {
		operacoes = append(operacoes, "c", "d")
	}
	rand.Shuffle(len(operacoes), func(i, j int) {
		operacoes[i], operacoes[j] = operacoes[j], operacoes[i]
	})

	status := dispararEmParalelo(len(operacoes), func(i int) int {
		return transacionar(h, 3, `{"valor":100,"tipo":"`+operacoes[i]+`","descricao":"mix"}`).Code
	})
	for _, s := range status {
		if s != http.StatusOK {
			t.Fatalf("status %d, esperado 200 em todos (limite do cliente 3 é 1.000.000)", s)
		}
	}
	if saldo := saldoDe(t, 3); saldo != 0 {
		t.Errorf("saldo %d, esperado 0", saldo)
	}
}

func TestTodaTransacaoConfirmadaTemLastroNoExtrato(t *testing.T) {
	h := caso(t)

	// O Gatling compara saldo e extrato. Um `UPDATE` confirmado sem o `INSERT`
	// correspondente seria saldo sem lastro — a razão de as duas operações
	// estarem na mesma transação de banco.
	dispararEmParalelo(40, func(int) int {
		return transacionar(h, 4, `{"valor":10,"tipo":"c","descricao":"l"}`).Code
	})

	var quantidade, soma int64
	erro := poolTeste.QueryRow(context.Background(),
		"SELECT count(*), COALESCE(sum(valor), 0) FROM crebitos_transacao WHERE cliente_id = 4").
		Scan(&quantidade, &soma)
	if erro != nil {
		t.Fatal(erro)
	}
	if quantidade != 40 {
		t.Errorf("%d transações gravadas, esperado 40", quantidade)
	}
	if soma != int64(saldoDe(t, 4)) {
		t.Errorf("soma das transações %d != saldo %d", soma, saldoDe(t, 4))
	}
}

// --------------------------------------------------------------------------
// As mesmas garantias, contra as QUATRO estratégias do Bloco B
// --------------------------------------------------------------------------

func TestTodasAsEstrategiasNaoPerdemEscrita(t *testing.T) {
	// 25 débitos simultâneos -> saldo exatamente -25. É a fase 1 do Gatling, e
	// o teste que separa atômico de "quase atômico".
	porEstrategia(t, func(t *testing.T, h http.Handler) {
		status := dispararEmParalelo(25, func(int) int {
			return transacionar(h, 1, `{"valor":1,"tipo":"d","descricao":"d"}`).Code
		})
		for _, s := range status {
			if s != http.StatusOK {
				t.Fatalf("status %d, esperado 200 em todos", s)
			}
		}
		if saldo := saldoDe(t, 1); saldo != -25 {
			t.Errorf("saldo %d, esperado exatamente -25", saldo)
		}
	})
}

func TestTodasAsEstrategiasRespeitamOLimite(t *testing.T) {
	// O caso adversarial: 100 débitos de 1.000 contra um limite de 80.000.
	// Exatamente 80 passam, 20 são recusados, e o saldo para no limite.
	porEstrategia(t, func(t *testing.T, h http.Handler) {
		status := dispararEmParalelo(100, func(int) int {
			return transacionar(h, 2, `{"valor":1000,"tipo":"d","descricao":"d"}`).Code
		})
		var aceitos, recusados int
		for _, s := range status {
			switch s {
			case http.StatusOK:
				aceitos++
			case http.StatusUnprocessableEntity:
				recusados++
			default:
				t.Fatalf("status inesperado: %d", s)
			}
		}
		if aceitos != 80 || recusados != 20 {
			t.Errorf("%d aceitos e %d recusados, esperado 80 e 20", aceitos, recusados)
		}
		if saldo := saldoDe(t, 2); saldo != -80_000 {
			t.Errorf("saldo %d, esperado exatamente -80000", saldo)
		}
	})
}

func TestTodasAsEstrategiasDaoLastroNoExtrato(t *testing.T) {
	// Toda transação confirmada tem de ter INSERT correspondente: o Gatling
	// compara saldo e extrato.
	porEstrategia(t, func(t *testing.T, h http.Handler) {
		dispararEmParalelo(40, func(int) int {
			return transacionar(h, 4, `{"valor":10,"tipo":"c","descricao":"l"}`).Code
		})
		var quantidade, soma int64
		erro := poolTeste.QueryRow(context.Background(),
			"SELECT count(*), COALESCE(sum(valor), 0) FROM crebitos_transacao WHERE cliente_id = 4").
			Scan(&quantidade, &soma)
		if erro != nil {
			t.Fatal(erro)
		}
		if quantidade != 40 {
			t.Errorf("%d transações gravadas, esperado 40", quantidade)
		}
		if soma != int64(saldoDe(t, 4)) {
			t.Errorf("soma das transações %d != saldo %d", soma, saldoDe(t, 4))
		}
	})
}
