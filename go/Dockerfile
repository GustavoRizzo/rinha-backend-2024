# syntax=docker/dockerfile:1
#
# Imagem da API em Go. Mesma estrutura das outras três (multi-stage, usuário sem
# privilégios, /sockets pré-criado) de propósito: se as imagens diferissem em
# base ou em usuário, a diferença medida entre os projetos não seria atribuível
# só à linguagem.
#
# O que muda aqui, e por quê: o Go compila para **código de máquina**. Não há
# runtime separado para copiar — nem o ERTS do Elixir, nem o interpretador do
# Python. O estágio final recebe um único arquivo executável.
#
# Ver `.claude/docs/performance/go/00-indice.md`, seção 4.

ARG GO=1.27
ARG ALPINE=3.21

FROM golang:${GO}-alpine AS build

WORKDIR /src

# Só os manifestos primeiro: esta camada só é reconstruída quando as
# dependências mudam. Mesma técnica do `COPY pyproject.toml uv.lock` do FastAPI
# e do `COPY mix.exs mix.lock` do Elixir.
COPY go.mod go.sum ./
RUN go mod download

COPY *.go ./

# CGO_ENABLED=0 produz um binário estático: sem ele o Go linkaria contra a musl
# do estágio de build e a imagem final precisaria da mesma libc. Aqui não muda
# funcionalidade nenhuma — o `pgx` é Go puro e não há dependência em C — mas
# torna a imagem final indiferente à base.
#
# `-trimpath` tira o caminho de build do binário; `-ldflags=-s -w` tira a tabela
# de símbolos e o DWARF. Os três valem tamanho de imagem, não velocidade: nada
# aqui muda o código gerado, e o `.claude/docs` é claro sobre não confundir uma
# coisa com a outra.
ENV CGO_ENABLED=0
RUN go build -trimpath -ldflags="-s -w" -o /rinha .

# ---------------------------------------------------------------------------

FROM alpine:${ALPINE} AS runtime

WORKDIR /app

COPY --from=build /rinha /app/rinha
COPY docker-entrypoint.sh /app/

# /sockets guarda o socket Unix compartilhado com o nginx. Precisa existir na
# imagem e pertencer ao usuário: um volume nomeado herda a posse do diretório da
# imagem na primeira criação — se não existir, o Docker o cria como root e a
# aplicação não consegue escrever nele.
RUN adduser --uid 10001 --disabled-password --home /home/rinha rinha \
 && mkdir -p /sockets \
 && chown -R rinha:rinha /app /home/rinha /sockets
USER rinha

ENTRYPOINT ["/app/docker-entrypoint.sh"]
