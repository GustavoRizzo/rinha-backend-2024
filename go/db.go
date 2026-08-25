// Pool de conexões do pgx e a verificação da carga inicial.
//
// Não há migrações aqui, de propósito. O schema e os 5 clientes vêm de
// `infra/sql/` — os MESMOS arquivos que as stacks Django, FastAPI e Elixir
// usam — executados uma única vez pela imagem do Postgres na criação do volume.
// Duas razões:
//
//  1. Com duas APIs, deixá-las aplicar o schema é uma corrida.
//  2. Reusar `infra/sql/ddl.sql` é o que mantém *uma variável por vez*: mesmas
//     tabelas, mesmo índice, mesmos dados.
package main

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Cem anos: o processo não vive tanto, então na prática é "nunca recicle". Ver
// o comentário em `criarPool` para o motivo de não ser zero.
const vidaEterna = 100 * 365 * 24 * time.Hour

// Os 5 clientes do README. Ver `.claude/docs/02-regras.md`, seção 2 — e a
// advertência de NÃO cadastrar o cliente 6, cujo 404 é parte do teste.
var clientesEsperados = map[int32]int32{
	1: 100_000,
	2: 80_000,
	3: 1_000_000,
	4: 10_000_000,
	5: 500_000,
}

func criarPool(ctx context.Context, cfg Config) (*pgxpool.Pool, error) {
	conexao := fmt.Sprintf(
		"postgres://%s:%s@%s:%d/%s",
		cfg.DBUser, cfg.DBPassword, cfg.DBHost, cfg.DBPort, cfg.DBName,
	)

	poolCfg, erro := pgxpool.ParseConfig(conexao)
	if erro != nil {
		return nil, erro
	}

	poolCfg.MaxConns = int32(cfg.DBPoolMax)
	poolCfg.MinConns = int32(cfg.DBPoolMin)
	// As conexões vivem pelo tempo de vida do processo. `django/04` mediu 4,75x
	// entre conexão persistente e conexão nova por requisição — cada conexão no
	// Postgres é um processo do sistema operacional, não um handle barato.
	//
	// CUIDADO: zero aqui NÃO é "sem limite", ao contrário do
	// `max_inactive_connection_lifetime=0` do asyncpg, que é o que o FastAPI usa
	// na mesma posição. Em `pgxpool/pool.go:463`, `isExpired` é
	// `time.Now().After(res.Value().maxAgeTime)`, e `maxAgeTime` é a criação
	// MAIS o `MaxConnLifetime` — com zero, toda conexão nasce vencida e é
	// destruída no primeiro `Acquire` (`pool.go:624`). A stack não subia:
	// `too many failed attempts acquiring connection`.
	//
	// Um valor grande e finito é a forma de dizer "nunca recicle" a esta API.
	poolCfg.MaxConnLifetime = vidaEterna
	poolCfg.MaxConnIdleTime = vidaEterna

	// EXPLÍCITO, e não deixado no padrão, porque foi exatamente aqui que o
	// projeto Elixir perdeu 3,97x de CPU de banco: `performance/elixir/04`
	// mediu `plans = calls` e 62,2% do tempo de banco planejando, por uma opção
	// de driver que eu supus em vez de conferir.
	//
	// Conferido no fonte desta vez (`pgx@v5.10.0/conn.go:191`): este JÁ é o
	// padrão do pgx, e `conn.go:537-543` mostra o modo procurando o SQL no
	// cache LRU da conexão antes de chamar `Prepare`. Escrever a linha mesmo
	// assim é barato e torna a decisão visível — mas quem decide a questão é
	// `just diag-prepared go`, que precisa marcar `plans = 0`.
	poolCfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeCacheStatement

	pool, erro := pgxpool.NewWithConfig(ctx, poolCfg)
	if erro != nil {
		return nil, erro
	}

	// `NewWithConfig` é preguiçoso: sem isto o servidor HTTP passaria a aceitar
	// conexões antes de existir uma conexão de banco, e o `curl` de prontidão
	// do `just up` pegaria uma janela de 500. É o papel do `lifespan` do
	// FastAPI e da ordem da árvore de supervisão do Elixir.
	if erro := pool.Ping(ctx); erro != nil {
		pool.Close()
		return nil, erro
	}
	return pool, nil
}

// verificarClientes aborta a subida se a carga inicial não bater com o README.
//
// Equivalente ao `manage.py verificar_clientes` do Django, ao
// `db.verificar_clientes` do FastAPI e ao `Rinha.DB.verificar!` do Elixir.
// Falhar aqui é muito melhor que descobrir a divergência no relatório da carga
// — um banco com saldo residual produz "inconsistências" que não são da
// aplicação.
func verificarClientes(ctx context.Context, pool *pgxpool.Pool) error {
	linhas, erro := pool.Query(ctx, "SELECT id, limite, saldo FROM crebitos_cliente ORDER BY id")
	if erro != nil {
		return erro
	}
	defer linhas.Close()

	encontrados := map[int32][2]int32{}
	for linhas.Next() {
		var id, limite, saldo int32
		if erro := linhas.Scan(&id, &limite, &saldo); erro != nil {
			return erro
		}
		encontrados[id] = [2]int32{limite, saldo}
	}
	if erro := linhas.Err(); erro != nil {
		return erro
	}

	var problemas []string
	for id, limite := range clientesEsperados {
		valores, existe := encontrados[id]
		if !existe {
			problemas = append(problemas, fmt.Sprintf("cliente %d ausente", id))
			continue
		}
		if valores[0] != limite {
			problemas = append(problemas,
				fmt.Sprintf("cliente %d: limite %d, esperado %d", id, valores[0], limite))
		}
		if valores[1] != 0 {
			problemas = append(problemas,
				fmt.Sprintf("cliente %d: saldo %d, esperado 0", id, valores[1]))
		}
	}
	// O cliente 6 não pode existir: o Gatling verifica que ele devolve 404.
	for id := range encontrados {
		if _, esperado := clientesEsperados[id]; !esperado {
			problemas = append(problemas, fmt.Sprintf("cliente %d não deveria existir", id))
		}
	}

	if len(problemas) == 0 {
		return nil
	}
	// Ordenado porque a iteração de mapa em Go é aleatória por construção: sem
	// isto a mesma falha imprimiria as linhas em ordem diferente a cada subida.
	sort.Strings(problemas)
	return fmt.Errorf("carga inicial divergente do README:\n  %s", strings.Join(problemas, "\n  "))
}

// contextoCurto limita o que a subida pode esperar pelo banco. O limite da
// competição para a stack inteira ficar de pé é 40s.
func contextoCurto() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 10*time.Second)
}
