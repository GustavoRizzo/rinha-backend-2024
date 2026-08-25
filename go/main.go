// API da Rinha de Backend 2024/Q1 em Go: `net/http` + `pgx`, escutando num
// socket Unix.
//
// Um binário só, com dois modos: sem argumento serve HTTP; com
// `preparar-bench` planta o estado da bancada e sai. É o equivalente do
// `bin/rinha eval Rinha.PrepararBench.run()` do Elixir e do
// `python -m app.preparar_bench` do FastAPI — e aqui sai de graça, porque o
// código já está compilado dentro do mesmo executável.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"
)

func main() {
	// Sem prefixo de data/hora: o que sai daqui vai para o `docker logs`, que
	// já carimba o horário. Duas marcações por linha só confundem.
	log.SetFlags(0)

	if len(os.Args) > 1 && os.Args[1] == "preparar-bench" {
		if erro := prepararBench(); erro != nil {
			log.Fatalf("preparar-bench: %v", erro)
		}
		return
	}

	if erro := servir(); erro != nil {
		log.Fatalf("erro: %v", erro)
	}
}

func servir() error {
	cfg, erro := carregarConfig()
	if erro != nil {
		return erro
	}

	ctx, cancelar := contextoCurto()
	defer cancelar()

	pool, erro := criarPool(ctx, cfg)
	if erro != nil {
		return fmt.Errorf("banco: %w", erro)
	}
	defer pool.Close()

	if cfg.VerificarClientes {
		if erro := verificarClientes(ctx, pool); erro != nil {
			return erro
		}
	}

	ouvinte, erro := ouvirUnix(cfg.Bind)
	if erro != nil {
		return erro
	}

	servidor := &http.Server{
		Handler: novoServidor(pool, cfg),
		// O nginx fala com esta API por socket Unix, com keep-alive e sem
		// exposição à internet. Timeouts existem para não vazar goroutine se o
		// nginx morrer no meio de um request, não como defesa contra
		// slowloris.
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       75 * time.Second,
		// Sem log de erro de protocolo: é I/O no caminho quente, pelo mesmo
		// motivo do `access_log off` do nginx (`django/01`). Vale para
		// requisição malformada, que o Gatling manda de propósito.
		ErrorLog: log.New(io.Discard, "", 0),
	}

	// `GOMAXPROCS` sob cota é o experimento central deste projeto, e não uma
	// nota de rodapé: o Go 1.27 lê a cota do cgroup mas **arredonda para cima
	// até 2** (`runtime/cgroup_linux.go:85-92`), enquanto o OTP 27 desce a 1
	// sob a mesma cota. Registrar o valor efetivo na subida é o que permite
	// conferir depois, no log, com que dimensionamento cada série rodou.
	//
	// `NumCPU()` vai ao lado de propósito: ele continua devolvendo 20 dentro de
	// um container com 0.40 CPU, exatamente como o `os.cpu_count()` do Python
	// em `django/02`. Nada nesta aplicação dimensiona nada por ele.
	log.Printf("rinha-go: GOMAXPROCS=%d NumCPU=%d pool=%d bind=%s extrato=%s serializacao=%s",
		runtime.GOMAXPROCS(0), runtime.NumCPU(), cfg.DBPoolMax, cfg.Bind,
		cfg.ExtratoQuery, cfg.Serializacao)

	// SIGTERM é o que o `docker stop` manda. Sem o desligamento ordenado, toda
	// derrubada da stack esperaria os 10s do timeout do Docker.
	parar := make(chan os.Signal, 1)
	signal.Notify(parar, syscall.SIGTERM, syscall.SIGINT)

	erroServidor := make(chan error, 1)
	go func() { erroServidor <- servidor.Serve(ouvinte) }()

	select {
	case erro := <-erroServidor:
		if errors.Is(erro, http.ErrServerClosed) {
			return nil
		}
		return erro
	case <-parar:
		ctx, cancelar := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancelar()
		return servidor.Shutdown(ctx)
	}
}

// ouvirUnix abre o socket Unix em que o nginx vai bater.
//
// Socket e não TCP porque `performance/django/03` mediu 2,9x em vazão alta no
// salto nginx->API, com a amplitude entre repetições caindo de 246% para 3,9%.
func ouvirUnix(caminho string) (net.Listener, error) {
	// Um socket Unix é um ARQUIVO. Se o container reiniciar sem que o volume
	// seja recriado, o arquivo antigo continua lá e o `bind` falha com "address
	// already in use" — erro que não tem nada a ver com porta ocupada e leva
	// meia hora para ser diagnosticado. Remover antes é o que o nginx, o
	// gunicorn e as outras duas stacks deste repositório também fazem.
	if erro := os.Remove(caminho); erro != nil && !errors.Is(erro, os.ErrNotExist) {
		return nil, erro
	}

	ouvinte, erro := net.Listen("unix", caminho)
	if erro != nil {
		return nil, erro
	}

	// O nginx roda com OUTRO usuário e precisa escrever no socket. O
	// entrypoint já faz `umask 0`, como no FastAPI e no Elixir; o `Chmod`
	// explícito existe porque o `net.Listen` cria o arquivo com a máscara do
	// processo e um `umask` esquecido viraria "permission denied" no nginx —
	// falha silenciosa do lado da API, que continuaria de pé sem receber nada.
	if erro := os.Chmod(caminho, 0o666); erro != nil {
		ouvinte.Close()
		return nil, erro
	}
	return ouvinte, nil
}
