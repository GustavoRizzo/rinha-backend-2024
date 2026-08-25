// Base dos testes: um pool de verdade, um handler de verdade, e o banco zerado
// antes de cada teste.
//
// Estado residual entre testes é a mesma armadilha que o `down -v` do justfile
// evita entre execuções da carga — um saldo herdado transforma um teste de
// concorrência numa afirmação sobre outra coisa.
//
// Os testes batem no `http.Handler` com `httptest`, e não num socket Unix: o
// que se exercita aqui é o roteador e o domínio. O socket é infraestrutura, e
// quem o prova é o `smoke` contra a stack de pé.
package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
)

var poolTeste *pgxpool.Pool

func TestMain(m *testing.M) {
	// `scripts/go-teste.sh` sobe um Postgres descartável e aponta DB_HOST para
	// ele. Rodar `go test` sem o script falha aqui, e falhar é o certo: um teste
	// que "passa" sem banco não testou nada.
	cfg, erro := carregarConfig()
	if erro != nil {
		panic(erro)
	}
	cfg.VerificarClientes = false

	ctx := context.Background()
	poolTeste, erro = criarPool(ctx, cfg)
	if erro != nil {
		panic("sem banco de teste (rode `just go-test`): " + erro.Error())
	}
	codigo := m.Run()
	poolTeste.Close()
	os.Exit(codigo)
}

// servidorDe monta o handler com a configuração pedida, para os testes de
// variante poderem trocar `EXTRATO_QUERY` e `SERIALIZACAO` sem variável de
// ambiente global.
func servidorDe(t *testing.T, ajustes ...func(*Config)) http.Handler {
	t.Helper()
	cfg, erro := carregarConfig()
	if erro != nil {
		t.Fatal(erro)
	}
	for _, ajustar := range ajustes {
		ajustar(&cfg)
	}
	return novoServidor(poolTeste, cfg)
}

// zerar devolve o banco ao estado da carga inicial: 5 clientes com saldo 0 e
// nenhuma transação.
func zerar(t *testing.T) {
	t.Helper()
	ctx := context.Background()
	if _, erro := poolTeste.Exec(ctx, "TRUNCATE crebitos_transacao RESTART IDENTITY"); erro != nil {
		t.Fatal(erro)
	}
	if _, erro := poolTeste.Exec(ctx, "UPDATE crebitos_cliente SET saldo = 0"); erro != nil {
		t.Fatal(erro)
	}
}

// caso é o preâmbulo de todo teste: banco limpo e um handler com os padrões.
func caso(t *testing.T) http.Handler {
	t.Helper()
	zerar(t)
	return servidorDe(t)
}

func requisitar(h http.Handler, metodo, caminho, corpo string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(metodo, caminho, strings.NewReader(corpo))
	resposta := httptest.NewRecorder()
	h.ServeHTTP(resposta, req)
	return resposta
}

func transacionar(h http.Handler, idCliente int, corpo string) *httptest.ResponseRecorder {
	return requisitar(h, http.MethodPost, "/clientes/"+strconv.Itoa(idCliente)+"/transacoes", corpo)
}

func extratoDe(h http.Handler, idCliente int) *httptest.ResponseRecorder {
	return requisitar(h, http.MethodGet, "/clientes/"+strconv.Itoa(idCliente)+"/extrato", "")
}

func saldoDe(t *testing.T, idCliente int32) int32 {
	t.Helper()
	var saldo int32
	erro := poolTeste.QueryRow(context.Background(),
		"SELECT saldo FROM crebitos_cliente WHERE id = $1", idCliente).Scan(&saldo)
	if erro != nil {
		t.Fatal(erro)
	}
	return saldo
}

// decodificar falha o teste se a resposta não for JSON válido — o corpo é parte
// do contrato, e um 200 com corpo quebrado passaria despercebido numa asserção
// que só olhasse o status.
func decodificar(t *testing.T, corpo []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if erro := json.Unmarshal(corpo, &m); erro != nil {
		t.Fatalf("resposta não é JSON válido: %v — %s", erro, corpo)
	}
	return m
}
