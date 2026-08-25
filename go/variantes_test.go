// As variantes medidas produzem o MESMO resultado.
//
// É o que autoriza compará-las depois: se `EXTRATO_QUERY=unica` e `duas`
// respondessem coisas diferentes, a diferença de CPU mediria a resposta, não a
// query. Espelha `elixir/test/variantes_test.exs` e
// `fastapi/tests/test_variantes.py`.
package main

import (
	"net/http"
	"regexp"
	"testing"
)

// `data_extrato` é o instante da consulta e muda entre duas chamadas: é o único
// campo legitimamente diferente, e é removido antes da comparação.
var padraoDataExtrato = regexp.MustCompile(`"data_extrato":"[^"]*"`)

func semData(corpo []byte) string {
	return padraoDataExtrato.ReplaceAllString(string(corpo), `"data_extrato":"?"`)
}

func corpoExtrato(t *testing.T, extratoQuery, serializacao string, idCliente int) string {
	t.Helper()
	h := servidorDe(t, func(c *Config) {
		c.ExtratoQuery = extratoQuery
		c.Serializacao = serializacao
	})
	resposta := extratoDe(h, idCliente)
	if resposta.Code != http.StatusOK {
		t.Fatalf("extrato devolveu %d", resposta.Code)
	}
	return semData(resposta.Body.Bytes())
}

func TestAsDuasFormasDoExtratoProduzemOsMesmosBytes(t *testing.T) {
	h := caso(t)
	for range 12 {
		transacionar(h, 1, `{"valor":7,"tipo":"c","descricao":"v"}`)
	}

	unica := corpoExtrato(t, "unica", "manual", 1)
	duas := corpoExtrato(t, "duas", "manual", 1)

	if unica != duas {
		t.Errorf("as duas variantes divergem:\n unica: %s\n  duas: %s", unica, duas)
	}
}

func TestDescricaoComAspasEBarraEEscapadaIgualNasDuasFormas(t *testing.T) {
	h := caso(t)

	// O `to_json()` do Postgres é quem escapa na variante `unica`; o
	// `encoding/json` é quem escapa na `duas`. É o caso em que elas poderiam
	// divergir — e o motivo de `appendJSONString` não escapar à mão.
	resposta := transacionar(h, 1, `{"valor":1,"tipo":"c","descricao":"\"a\\b\""}`)
	if resposta.Code != http.StatusOK {
		t.Fatalf("status %d, esperado 200", resposta.Code)
	}

	if unica, duas := corpoExtrato(t, "unica", "manual", 1), corpoExtrato(t, "duas", "manual", 1); unica != duas {
		t.Errorf("escape divergente:\n unica: %s\n  duas: %s", unica, duas)
	}
}

func TestAsDuasSerializacoesProduzemOsMesmosBytes(t *testing.T) {
	h := caso(t)
	for range 3 {
		transacionar(h, 1, `{"valor":3,"tipo":"c","descricao":"j"}`)
	}

	// Só a variante `duas` serializa a lista na aplicação: na `unica` o array
	// vem pronto do Postgres e não há o que comparar.
	manual := corpoExtrato(t, "duas", "manual", 1)
	stdlib := corpoExtrato(t, "duas", "stdlib", 1)
	if manual != stdlib {
		t.Errorf("serializações divergem:\n manual: %s\n stdlib: %s", manual, stdlib)
	}

	// E a resposta do POST, que tem serialização própria nas duas variantes.
	hManual := servidorDe(t, func(c *Config) { c.Serializacao = "manual" })
	hStdlib := servidorDe(t, func(c *Config) { c.Serializacao = "stdlib" })
	corpoManual := transacionar(hManual, 5, `{"valor":10,"tipo":"c","descricao":"p"}`).Body.String()
	corpoStdlib := transacionar(hStdlib, 5, `{"valor":10,"tipo":"c","descricao":"p"}`).Body.String()
	// Os saldos diferem (são dois POSTs), então comparamos a FORMA: mesma ordem
	// de chaves, mesma ausência de espaços.
	if padraoSaldo(corpoManual) != padraoSaldo(corpoStdlib) {
		t.Errorf("resposta do POST diverge:\n manual: %s\n stdlib: %s", corpoManual, corpoStdlib)
	}
}

var padraoNumero = regexp.MustCompile(`-?\d+`)

func padraoSaldo(corpo string) string {
	return padraoNumero.ReplaceAllString(corpo, "N")
}

func TestAsDuasVariantesDeExtratoConcordamNoCasoVazio(t *testing.T) {
	// Lista vazia é o caso em que a `unica` depende do `COALESCE` e a `duas`, de
	// uma fatia com capacidade mas sem elementos — um `nil` viraria `null` no
	// `encoding/json` e quebraria a igualdade.
	_ = caso(t)

	if unica, duas := corpoExtrato(t, "unica", "manual", 1), corpoExtrato(t, "duas", "manual", 1); unica != duas {
		t.Errorf("caso vazio diverge:\n unica: %s\n  duas: %s", unica, duas)
	}
	if unica, stdlib := corpoExtrato(t, "unica", "manual", 1), corpoExtrato(t, "duas", "stdlib", 1); unica != stdlib {
		t.Errorf("caso vazio diverge no stdlib:\n unica: %s\n stdlib: %s", unica, stdlib)
	}
}

func TestAsVariantesAceitamERecusamOsMesmosPayloads(t *testing.T) {
	zerar(t)

	for _, serializacao := range []string{"manual", "stdlib"} {
		h := servidorDe(t, func(c *Config) { c.Serializacao = serializacao })
		if r := transacionar(h, 5, `{"valor":1,"tipo":"c","descricao":"ok"}`); r.Code != http.StatusOK {
			t.Errorf("%s: válido devolveu %d", serializacao, r.Code)
		}
		if r := transacionar(h, 5, `{"valor":1.5,"tipo":"c","descricao":"ok"}`); r.Code != http.StatusUnprocessableEntity {
			t.Errorf("%s: inválido devolveu %d", serializacao, r.Code)
		}
	}
}

// --------------------------------------------------------------------------
// A configuração ABORTA em valor desconhecido
// --------------------------------------------------------------------------

// Regra do projeto, aprendida na marra: três bugs deste repositório produziram
// números plausíveis em vez de erro. Um `SERIALIZACAO=stdilb` com typo cairia
// silenciosamente no padrão e viraria uma linha de tabela mentirosa.
func TestConfiguracaoDesconhecidaAborta(t *testing.T) {
	casos := map[string]string{
		"EXTRATO_QUERY": "tres",
		"SERIALIZACAO":  "stdilb",
		"DB_POOL_MAX":   "zero",
	}

	for nome, valor := range casos {
		t.Run(nome, func(t *testing.T) {
			t.Setenv(nome, valor)
			if _, erro := carregarConfig(); erro == nil {
				t.Errorf("%s=%q foi aceito; deveria abortar", nome, valor)
			}
		})
	}
}

func TestConfiguracaoPadraoEAEscolhaHerdada(t *testing.T) {
	// Os padrões não são arbitrários: `unica` foi eleito em `fastapi/01` (1,25x)
	// e repetido no Elixir. Um padrão que mudasse sem ninguém notar tornaria
	// séries antigas incomparáveis com as novas.
	cfg, erro := carregarConfig()
	if erro != nil {
		t.Fatal(erro)
	}
	if cfg.ExtratoQuery != "unica" {
		t.Errorf("EXTRATO_QUERY padrão %q, esperado unica", cfg.ExtratoQuery)
	}
	if cfg.Serializacao != "manual" {
		t.Errorf("SERIALIZACAO padrão %q, esperado manual", cfg.Serializacao)
	}
	if cfg.DBPoolMax != 8 {
		t.Errorf("DB_POOL_MAX padrão %d, esperado 8", cfg.DBPoolMax)
	}
}
