// O contrato HTTP da Rinha, verificado endpoint a endpoint.
//
// Porte de `elixir/test/contrato_test.exs` e `fastapi/tests/test_contrato.py`.
// Cada asserção aqui corresponde a uma verificação da simulação oficial —
// `.claude/docs/02-regras.md`, seções 1 e 6.
package main

import (
	"net/http"
	"testing"
)

func TestExtratoDeClienteExistente(t *testing.T) {
	h := caso(t)

	resposta := extratoDe(h, 1)
	if resposta.Code != http.StatusOK {
		t.Fatalf("status %d, esperado 200", resposta.Code)
	}

	corpo := decodificar(t, resposta.Body.Bytes())
	saldo := corpo["saldo"].(map[string]any)
	if saldo["limite"].(float64) != 100_000 {
		t.Errorf("limite %v, esperado 100000", saldo["limite"])
	}
	if saldo["total"].(float64) != 0 {
		t.Errorf("total %v, esperado 0", saldo["total"])
	}
	if saldo["data_extrato"] == "" {
		t.Error("data_extrato vazia")
	}
	// Lista vazia, e não `null`: o contrato mostra um array, e um `null` faria o
	// Gatling falhar ao ler `ultimas_transacoes.size()`.
	if ultimas, ok := corpo["ultimas_transacoes"].([]any); !ok || len(ultimas) != 0 {
		t.Errorf("ultimas_transacoes %v, esperado lista vazia", corpo["ultimas_transacoes"])
	}
}

func TestClienteInexistenteDa404(t *testing.T) {
	h := caso(t)

	// O cliente 6 NÃO existe, e o teste oficial verifica exatamente isso.
	if resposta := extratoDe(h, 6); resposta.Code != http.StatusNotFound {
		t.Errorf("GET extrato do 6: status %d, esperado 404", resposta.Code)
	}
	resposta := transacionar(h, 6, `{"valor":1,"tipo":"c","descricao":"x"}`)
	if resposta.Code != http.StatusNotFound {
		t.Errorf("POST no 6: status %d, esperado 404", resposta.Code)
	}
	// Um ID que nem número é: tem de ser 404, não 500.
	if r := requisitar(h, http.MethodGet, "/clientes/abc/extrato", ""); r.Code != http.StatusNotFound {
		t.Errorf("GET /clientes/abc/extrato: status %d, esperado 404", r.Code)
	}
}

func TestTransacaoDeSucessoResponde200(t *testing.T) {
	h := caso(t)

	// 200, obrigatoriamente — nunca 201. É uma das regras explícitas do README.
	resposta := transacionar(h, 1, `{"valor":1000,"tipo":"c","descricao":"toma"}`)
	if resposta.Code != http.StatusOK {
		t.Fatalf("status %d, esperado 200", resposta.Code)
	}
	if tipo := resposta.Header().Get("Content-Type"); tipo != tipoJSON {
		t.Errorf("content-type %q, esperado %q", tipo, tipoJSON)
	}

	corpo := decodificar(t, resposta.Body.Bytes())
	if corpo["limite"].(float64) != 100_000 || corpo["saldo"].(float64) != 1000 {
		t.Errorf("corpo %v, esperado limite 100000 e saldo 1000", corpo)
	}
}

func TestDebitoDentroDoLimitePassa(t *testing.T) {
	h := caso(t)

	resposta := transacionar(h, 1, `{"valor":100000,"tipo":"d","descricao":"limite"}`)
	if resposta.Code != http.StatusOK {
		t.Fatalf("status %d, esperado 200", resposta.Code)
	}
	// Exatamente no limite: saldo -limite é válido, -limite-1 não.
	if saldo := saldoDe(t, 1); saldo != -100_000 {
		t.Errorf("saldo %d, esperado -100000", saldo)
	}
}

func TestDebitoQueEstouraOLimiteDa422ENaoAplica(t *testing.T) {
	h := caso(t)

	resposta := transacionar(h, 1, `{"valor":100001,"tipo":"d","descricao":"estoura"}`)
	if resposta.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status %d, esperado 422", resposta.Code)
	}
	// "sem aplicar a transação": nem o saldo muda, nem sobra transação no
	// extrato. É o que a transação de banco garante.
	if saldo := saldoDe(t, 1); saldo != 0 {
		t.Errorf("saldo %d, esperado 0", saldo)
	}
	corpo := decodificar(t, extratoDe(h, 1).Body.Bytes())
	if ultimas := corpo["ultimas_transacoes"].([]any); len(ultimas) != 0 {
		t.Errorf("%d transações no extrato, esperado nenhuma", len(ultimas))
	}
}

func TestPayloadsInvalidosDao422(t *testing.T) {
	h := caso(t)

	// Os cinco payloads que a simulação oficial manda de propósito, mais os que
	// as outras três stacks já cobriam.
	casos := map[string]string{
		"valor fracionário":  `{"valor":1.2,"tipo":"c","descricao":"x"}`,
		"valor booleano":     `{"valor":true,"tipo":"c","descricao":"x"}`,
		"valor negativo":     `{"valor":-1,"tipo":"c","descricao":"x"}`,
		"valor zero":         `{"valor":0,"tipo":"c","descricao":"x"}`,
		"valor como string":  `{"valor":"1","tipo":"c","descricao":"x"}`,
		"tipo inválido":      `{"valor":1,"tipo":"x","descricao":"x"}`,
		"descrição com 11":   `{"valor":1,"tipo":"c","descricao":"123456789 e mais um pouco"}`,
		"descrição vazia":    `{"valor":1,"tipo":"c","descricao":""}`,
		"descrição null":     `{"valor":1,"tipo":"c","descricao":null}`,
		"descrição ausente":  `{"valor":1,"tipo":"c"}`,
		"valor ausente":      `{"tipo":"c","descricao":"x"}`,
		"corpo vazio":        ``,
		"corpo não é objeto": `[]`,
		"JSON malformado":    `{"valor":`,
	}

	for nome, corpo := range casos {
		t.Run(nome, func(t *testing.T) {
			resposta := transacionar(h, 1, corpo)
			if resposta.Code != http.StatusUnprocessableEntity {
				t.Errorf("status %d, esperado 422", resposta.Code)
			}
		})
	}

	// Nenhum deles pode ter tocado no saldo.
	if saldo := saldoDe(t, 1); saldo != 0 {
		t.Errorf("saldo %d depois dos payloads inválidos, esperado 0", saldo)
	}
}

func TestDescricaoComExatamente10CaracteresPassa(t *testing.T) {
	h := caso(t)

	// A fronteira: 10 é válido, 11 não. Um `<` no lugar de `<=` passaria em
	// todos os outros testes.
	if r := transacionar(h, 1, `{"valor":1,"tipo":"c","descricao":"1234567890"}`); r.Code != http.StatusOK {
		t.Errorf("10 caracteres: status %d, esperado 200", r.Code)
	}
	if r := transacionar(h, 1, `{"valor":1,"tipo":"c","descricao":"12345678901"}`); r.Code != http.StatusUnprocessableEntity {
		t.Errorf("11 caracteres: status %d, esperado 422", r.Code)
	}
	// Acentos contam como UM caractere, e não como os dois bytes do UTF-8:
	// `len()` sobre bytes recusaria esta descrição de 10 letras.
	if r := transacionar(h, 1, `{"valor":1,"tipo":"c","descricao":"ãéíõúçãéí"}`); r.Code != http.StatusOK {
		t.Errorf("9 caracteres acentuados: status %d, esperado 200", r.Code)
	}
}

func TestExtratoEmOrdemDecrescente(t *testing.T) {
	h := caso(t)

	// A sequência exata da fase 2 do Gatling: crédito "toma", depois débito
	// "devolve" — e o extrato tem de mostrar "devolve" primeiro.
	transacionar(h, 1, `{"valor":1,"tipo":"c","descricao":"toma"}`)
	transacionar(h, 1, `{"valor":1,"tipo":"d","descricao":"devolve"}`)

	corpo := decodificar(t, extratoDe(h, 1).Body.Bytes())
	ultimas := corpo["ultimas_transacoes"].([]any)
	if len(ultimas) != 2 {
		t.Fatalf("%d transações, esperado 2", len(ultimas))
	}
	primeira := ultimas[0].(map[string]any)
	segunda := ultimas[1].(map[string]any)
	if primeira["descricao"] != "devolve" || primeira["tipo"] != "d" {
		t.Errorf("primeira %v, esperado devolve/d", primeira)
	}
	if segunda["descricao"] != "toma" || segunda["tipo"] != "c" {
		t.Errorf("segunda %v, esperado toma/c", segunda)
	}
}

func TestExtratoLimitaEm10Transacoes(t *testing.T) {
	h := caso(t)

	for range 15 {
		transacionar(h, 1, `{"valor":1,"tipo":"c","descricao":"x"}`)
	}

	corpo := decodificar(t, extratoDe(h, 1).Body.Bytes())
	if ultimas := corpo["ultimas_transacoes"].([]any); len(ultimas) != qtdTransacoesExtrato {
		t.Errorf("%d transações, esperado %d", len(ultimas), qtdTransacoesExtrato)
	}
	// `total` é o saldo TOTAL, não a soma das 10 listadas.
	saldo := corpo["saldo"].(map[string]any)
	if saldo["total"].(float64) != 15 {
		t.Errorf("total %v, esperado 15 (todas as transações, não só as 10 listadas)", saldo["total"])
	}
}

func TestReadYourWrites(t *testing.T) {
	h := caso(t)

	// Fase 2 do Gatling: um POST seguido de 5 GETs paralelos, todos exigindo ver
	// a transação e o saldo exato que o POST devolveu.
	resposta := transacionar(h, 1, `{"valor":777,"tipo":"c","descricao":"danada"}`)
	saldoDoPost := decodificar(t, resposta.Body.Bytes())["saldo"].(float64)

	for range 5 {
		corpo := decodificar(t, extratoDe(h, 1).Body.Bytes())
		if corpo["saldo"].(map[string]any)["total"].(float64) != saldoDoPost {
			t.Fatalf("extrato não vê o saldo que o POST devolveu (%v)", saldoDoPost)
		}
		ultimas := corpo["ultimas_transacoes"].([]any)
		if len(ultimas) == 0 || ultimas[0].(map[string]any)["descricao"] != "danada" {
			t.Fatal("extrato não vê a transação que o POST acabou de gravar")
		}
	}
}

func TestMetodoErradoNaRotaCerta(t *testing.T) {
	h := caso(t)

	// `GET` em /transacoes não casa com `POST /clientes/{id}/transacoes` e cai
	// no handler curinga. 404 é o que as outras stacks respondem.
	if r := requisitar(h, http.MethodGet, "/clientes/1/transacoes", ""); r.Code != http.StatusNotFound {
		t.Errorf("status %d, esperado 404", r.Code)
	}
	if r := requisitar(h, http.MethodGet, "/", ""); r.Code != http.StatusNotFound {
		t.Errorf("status %d, esperado 404", r.Code)
	}
}
