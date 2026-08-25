// Configuração por variável de ambiente, lida uma vez na subida.
//
// Convenção do projeto (`CLAUDE.md`): configurações alternativas são
// **variáveis de ambiente, não branches**. Elas convivem no mesmo commit, e é
// isso que torna a comparação A/B possível — `bench-stack.sh` liga uma de cada
// vez sem trocar de código.
package main

import (
	"fmt"
	"os"
	"slices"
	"strconv"
)

// Config é lida uma vez, na subida, e depois só lida. Um struct global e não
// `os.Getenv` no caminho quente: `Getenv` faz busca linear no ambiente a cada
// chamada, e o extrato consultaria a variante em toda requisição.
type Config struct {
	DBHost     string
	DBPort     int
	DBName     string
	DBUser     string
	DBPassword string
	DBPoolMax  int
	DBPoolMin  int

	// `unica` — uma query só, com o array de transações já serializado em JSON
	//           pelo Postgres. Padrão porque foi o padrão eleito no FastAPI
	//           (`performance/fastapi/01`: 1,25x, com teste provando bytes
	//           idênticos). Repetir a escolha é o que mantém a comparação.
	// `duas`  — um SELECT do cliente, outro das 10 transações. Espelha o que o
	//           Django faz, e é a linha de base daquela comparação.
	ExtratoQuery string

	// `manual` — a resposta é montada byte a byte, sem reflexão.
	// `stdlib` — `encoding/json`, que serializa por reflexão sobre o struct.
	// Paralelo do `SERIALIZACAO=orjson|stdlib` do FastAPI e do
	// `JSON_LIB=jason|otp` do Elixir. A hipótese é a mesma: num payload de dois
	// campos (a resposta do POST) a escolha não deve aparecer; no extrato,
	// talvez apareça.
	Serializacao string

	// Aborta a subida se a carga inicial divergir do README.
	VerificarClientes bool

	// Caminho do socket Unix. Socket e não TCP porque `performance/django/03`
	// mediu 2,9x em vazão alta no salto nginx->API, e a amplitude entre
	// repetições caiu de 246% para 3,9%.
	Bind string
}

// carregarConfig lê o ambiente, valida e devolve. Todo valor desconhecido
// **aborta**, com o nome da variável e o valor recebido.
//
// Regra do projeto, aprendida na marra: três bugs deste repositório produziram
// números plausíveis em vez de erro. Um `SERIALIZACAO=stdilb` com typo cairia
// silenciosamente no padrão e viraria uma linha de tabela mentirosa.
func carregarConfig() (Config, error) {
	cfg := Config{
		DBHost:            env("DB_HOST", "localhost"),
		DBName:            env("DB_NAME", "rinha"),
		DBUser:            env("DB_USER", "rinha"),
		DBPassword:        env("DB_PASSWORD", "rinha"),
		VerificarClientes: env("VERIFICAR_CLIENTES", "1") == "1",
		// O prefixo `unix:` existe para o valor ser idêntico ao que o FastAPI e
		// o Elixir recebem na mesma posição do compose.
		Bind: trimPrefixo(env("BIND", "unix:/sockets/api01.sock"), "unix:"),
	}

	var erro error
	cfg.DBPort, erro = inteiroPositivo("DB_PORT", "5432")
	if erro != nil {
		return cfg, erro
	}
	// Cada conexão no Postgres é um PROCESSO do sistema operacional, com ~5-10MB
	// de overhead, e `infra/postgres/postgresql.conf` fixa `max_connections =
	// 20` para as duas APIs. A conta é 2 APIs × DB_POOL_MAX + folga de
	// manutenção. Num orçamento de 550MB isso é decisão de arquitetura, não
	// afinação.
	cfg.DBPoolMax, erro = inteiroPositivo("DB_POOL_MAX", "8")
	if erro != nil {
		return cfg, erro
	}
	cfg.DBPoolMin, erro = inteiroPositivo("DB_POOL_MIN", "2")
	if erro != nil {
		return cfg, erro
	}
	cfg.ExtratoQuery, erro = opcao("EXTRATO_QUERY", "unica", []string{"unica", "duas"})
	if erro != nil {
		return cfg, erro
	}
	cfg.Serializacao, erro = opcao("SERIALIZACAO", "manual", []string{"manual", "stdlib"})
	if erro != nil {
		return cfg, erro
	}
	return cfg, nil
}

func env(nome, padrao string) string {
	if valor, ok := os.LookupEnv(nome); ok && valor != "" {
		return valor
	}
	return padrao
}

func opcao(nome, padrao string, aceitos []string) (string, error) {
	valor := env(nome, padrao)
	if slices.Contains(aceitos, valor) {
		return valor, nil
	}
	return "", fmt.Errorf("%s=%q desconhecido; aceitos: %v", nome, valor, aceitos)
}

func inteiroPositivo(nome, padrao string) (int, error) {
	valor := env(nome, padrao)
	n, erro := strconv.Atoi(valor)
	if erro != nil || n <= 0 {
		return 0, fmt.Errorf("%s=%q não é um inteiro positivo", nome, valor)
	}
	return n, nil
}

func trimPrefixo(s, prefixo string) string {
	if len(s) >= len(prefixo) && s[:len(prefixo)] == prefixo {
		return s[len(prefixo):]
	}
	return s
}
