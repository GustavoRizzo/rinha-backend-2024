// Os dois endpoints do contrato da Rinha, em `net/http` da biblioteca padrão.
//
// Sem framework, de propósito: o par estrutural do FastAPI (casca fina sobre
// Starlette) e do `Plug.Router` sobre Bandit é a stdlib. Desde o Go 1.22 o
// `http.ServeMux` entende método e variável de caminho, que é tudo o que dois
// endpoints precisam. A justificativa completa está em
// `.claude/docs/performance/go/00-indice.md`, seção 2.
package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/jackc/pgx/v5/pgxpool"
)

// O corpo de 404 e 422 não é testado pela Rinha ("você pode escolher como o
// representar"), então não gastamos CPU nem bytes serializando mensagem alguma.
const tipoJSON = "application/json"

// O corpo do POST tem 3 campos e o contrato limita a descrição a 10
// caracteres: qualquer coisa acima disto é payload que não vai ser aceito de
// qualquer forma, e ler o resto seria trabalho jogado fora. `MaxBytesReader`
// também é o que impede um corpo infinito de virar alocação infinita.
const maxCorpo = 1024

type servidor struct {
	pool *pgxpool.Pool
	cfg  Config
}

func novoServidor(pool *pgxpool.Pool, cfg Config) http.Handler {
	s := &servidor{pool: pool, cfg: cfg}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /clientes/{id}/transacoes", s.transacoes)
	mux.HandleFunc("GET /clientes/{id}/extrato", s.extrato)
	// Qualquer outra rota é 404, e não o 404 com corpo HTML que o `ServeMux`
	// gera por padrão.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	return mux
}

func (s *servidor) transacoes(w http.ResponseWriter, r *http.Request) {
	// HACK DA RINHA: resolve o 404 sem tocar no banco. Ver `hacks.go`.
	idCliente, ok := idValido(r.PathValue("id"))
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	corpo, erro := io.ReadAll(http.MaxBytesReader(w, r.Body, maxCorpo))
	if erro != nil {
		w.WriteHeader(http.StatusUnprocessableEntity)
		return
	}

	t, erro := validar(corpo)
	if erro != nil {
		w.WriteHeader(http.StatusUnprocessableEntity)
		return
	}

	limite, saldo, erro := aplicarTransacao(r.Context(), s.pool, s.cfg, idCliente, t)
	if erro != nil {
		if errors.Is(erro, erroTransacaoInvalida) {
			w.WriteHeader(http.StatusUnprocessableEntity)
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", tipoJSON)
	w.Write(s.respostaTransacao(limite, saldo)) //nolint:errcheck
}

func (s *servidor) extrato(w http.ResponseWriter, r *http.Request) {
	// HACK DA RINHA: mesmo atalho do endpoint acima.
	idCliente, ok := idValido(r.PathValue("id"))
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	var corpo []byte
	var erro error
	if s.cfg.ExtratoQuery == "unica" {
		corpo, erro = s.extratoUnico(r, idCliente)
	} else {
		corpo, erro = s.extratoDuplo(r, idCliente)
	}
	if erro != nil {
		if errors.Is(erro, erroClienteAusente) {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", tipoJSON)
	w.Write(corpo) //nolint:errcheck
}

// --------------------------------------------------------------------------
// Serialização — as duas variantes de `SERIALIZACAO`
// --------------------------------------------------------------------------

type respostaSaldo struct {
	Total       int32  `json:"total"`
	DataExtrato string `json:"data_extrato"`
	Limite      int32  `json:"limite"`
}

type respostaExtrato struct {
	Saldo             respostaSaldo    `json:"saldo"`
	UltimasTransacoes []linhaTransacao `json:"ultimas_transacoes"`
}

type respostaTransacao struct {
	Limite int32 `json:"limite"`
	Saldo  int32 `json:"saldo"`
}

// A ordem das chaves segue a do FastAPI e a do Elixir: `limite` antes de
// `saldo`. O Gatling faz parsing e não liga, mas corpos diferentes entre
// projetos mediriam o tamanho do payload em vez da aplicação.
func (s *servidor) respostaTransacao(limite, saldo int32) []byte {
	if s.cfg.Serializacao == "stdlib" {
		corpo, _ := json.Marshal(respostaTransacao{Limite: limite, Saldo: saldo})
		return corpo
	}
	// Montagem à mão: dois inteiros e 20 bytes de estrutura fixa não justificam
	// a reflexão do `encoding/json`. `AppendInt` escreve direto no buffer, sem
	// alocar a string intermediária que `strconv.Itoa` alocaria.
	corpo := make([]byte, 0, 40)
	corpo = append(corpo, `{"limite":`...)
	corpo = strconv.AppendInt(corpo, int64(limite), 10)
	corpo = append(corpo, `,"saldo":`...)
	corpo = strconv.AppendInt(corpo, int64(saldo), 10)
	return append(corpo, '}')
}

// extratoUnico concatena a string JSON que o Postgres já montou.
//
// As transações já são JSON válido vindo do banco: desserializá-las só para
// re-serializar seria pagar o trabalho duas vezes. Por isso esta variante
// ignora `SERIALIZACAO` no array — não há o que serializar.
func (s *servidor) extratoUnico(r *http.Request, idCliente int32) ([]byte, error) {
	saldo, limite, ultimas, erro := extratoQueryUnica(r.Context(), s.pool, idCliente)
	if erro != nil {
		return nil, erro
	}

	corpo := make([]byte, 0, len(ultimas)+96)
	corpo = append(corpo, `{"saldo":{"total":`...)
	corpo = strconv.AppendInt(corpo, int64(saldo), 10)
	corpo = append(corpo, `,"data_extrato":"`...)
	corpo = append(corpo, agoraISO()...)
	corpo = append(corpo, `","limite":`...)
	corpo = strconv.AppendInt(corpo, int64(limite), 10)
	corpo = append(corpo, `},"ultimas_transacoes":`...)
	corpo = append(corpo, ultimas...)
	return append(corpo, '}'), nil
}

func (s *servidor) extratoDuplo(r *http.Request, idCliente int32) ([]byte, error) {
	saldo, limite, ultimas, erro := extratoDuasQueries(r.Context(), s.pool, idCliente)
	if erro != nil {
		return nil, erro
	}

	resposta := respostaExtrato{
		Saldo: respostaSaldo{
			// Instante da consulta, não uma coluna do banco.
			Total:       saldo,
			DataExtrato: agoraISO(),
			Limite:      limite,
		},
		UltimasTransacoes: ultimas,
	}

	if s.cfg.Serializacao == "stdlib" {
		return json.Marshal(resposta)
	}
	return marshalExtratoManual(resposta), nil
}

// marshalExtratoManual produz exatamente os mesmos bytes que `json.Marshal`
// sobre `respostaExtrato` — e os mesmos que a variante `unica`. `extrato_test.go`
// prova as duas igualdades.
//
// A descrição é o único campo que precisa de escape: `valor` é inteiro, `tipo`
// é um caractere de um conjunto de dois, e `realizada_em` sai de um `Format`
// com layout fixo.
func marshalExtratoManual(r respostaExtrato) []byte {
	corpo := make([]byte, 0, 128+len(r.UltimasTransacoes)*96)
	corpo = append(corpo, `{"saldo":{"total":`...)
	corpo = strconv.AppendInt(corpo, int64(r.Saldo.Total), 10)
	corpo = append(corpo, `,"data_extrato":"`...)
	corpo = append(corpo, r.Saldo.DataExtrato...)
	corpo = append(corpo, `","limite":`...)
	corpo = strconv.AppendInt(corpo, int64(r.Saldo.Limite), 10)
	corpo = append(corpo, `},"ultimas_transacoes":[`...)
	for i, t := range r.UltimasTransacoes {
		if i > 0 {
			corpo = append(corpo, ',')
		}
		corpo = append(corpo, `{"valor":`...)
		corpo = strconv.AppendInt(corpo, int64(t.Valor), 10)
		corpo = append(corpo, `,"tipo":"`...)
		corpo = append(corpo, t.Tipo...)
		corpo = append(corpo, `","descricao":`...)
		corpo = appendJSONString(corpo, t.Descricao)
		corpo = append(corpo, `,"realizada_em":"`...)
		corpo = append(corpo, t.RealizadaEm...)
		corpo = append(corpo, `"}`...)
	}
	return append(corpo, ']', '}')
}

// appendJSONString delega ao `encoding/json` o escape de uma string.
//
// Fazer o escape à mão seria assumir que a descrição não tem aspas, barra
// invertida nem caractere de controle — e o `to_json()` do Postgres, do outro
// lado da comparação, não assume nada disso. Duas variantes com regras de
// escape diferentes produziriam bytes diferentes no primeiro payload esquisito,
// e o teste de igualdade só pegaria isso por sorte.
func appendJSONString(destino []byte, s string) []byte {
	codificada, _ := json.Marshal(s)
	return append(destino, codificada...)
}

// idValido devolve o ID só se ele for um inteiro E um dos 5 clientes.
//
// `ParseInt` e não `Atoi` por causa da largura: as colunas são `bigint` no
// schema, mas os IDs válidos cabem em `int32`, que é o tipo que o pgx manda no
// protocolo binário sem conversão.
func idValido(bruto string) (int32, bool) {
	n, erro := strconv.ParseInt(bruto, 10, 32)
	if erro != nil {
		return 0, false
	}
	id := int32(n)
	return id, clienteExiste(id)
}
