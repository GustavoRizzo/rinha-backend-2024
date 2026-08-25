# syntax=docker/dockerfile:1
#
# Imagem da API em Elixir. Mesma estrutura das outras duas (multi-stage, usuário
# sem privilégios, /sockets pré-criado) de propósito: se as imagens diferissem
# em base ou em usuário, a diferença medida entre os projetos não seria
# atribuível só à linguagem.
#
# O que muda aqui, e por quê: o Elixir compila para bytecode `.beam`, que precisa
# da máquina virtual BEAM para rodar. O `mix release` empacota o bytecode JUNTO
# com a VM (o ERTS), produzindo um diretório autocontido — por isso o estágio
# final pode ser um Alpine pelado, sem Erlang nem Elixir instalados. O
# compilador, o Mix, os fontes `.ex` e as dependências em código-fonte ficam
# todos para trás no estágio `build`.
#
# Ver `.claude/docs/performance/elixir/00-indice.md`, seção 2.

ARG ALPINE=3.21
ARG ELIXIR=1.18.4
ARG ERLANG=27.3.4
# A tag do hexpm exige a versão COMPLETA do Alpine (3.21.3), enquanto a imagem
# oficial do Alpine usa a série (3.21). Duas variáveis, e não uma, porque com
# uma só um dos dois `FROM` fica sem tag existente — foi o primeiro build a
# falhar aqui.
ARG ALPINE_BUILD=3.21.3

FROM hexpm/elixir:${ELIXIR}-erlang-${ERLANG}-alpine-${ALPINE_BUILD} AS build

# `MIX_ENV=prod` liga as otimizações de compilação e, mais importante aqui, faz
# o `mix release` montar um release sem as ferramentas de desenvolvimento.
ENV MIX_ENV=prod

RUN apk add --no-cache build-base
RUN mix local.hex --force && mix local.rebar --force

WORKDIR /src

# Só os manifestos primeiro: esta camada só é reconstruída quando as
# dependências mudam. Mesma técnica do `COPY pyproject.toml uv.lock` do FastAPI.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config config
COPY lib lib
RUN mix compile && mix release

# ---------------------------------------------------------------------------

FROM alpine:${ALPINE} AS runtime

# O ERTS é ligado dinamicamente contra estas três: `libcrypto` (do openssl) para
# o módulo `:crypto`, que o Postgrex usa na autenticação; `ncurses` para o
# terminal; `libstdc++` para partes do runtime compiladas em C++. Sem elas o
# release sobe e morre com "error loading shared library".
RUN apk add --no-cache libstdc++ ncurses-libs openssl

WORKDIR /app

# Sem cluster: este serviço não fala com nenhum outro nó. Desligar a distribuição
# evita subir o `epmd` (um processo e uma porta a mais) e economiza memória, que
# é o recurso apertado aqui — 100MB por instância.
ENV RELEASE_DISTRIBUTION=none \
    LANG=C.UTF-8

COPY --from=build /src/_build/prod/rel/rinha ./
COPY docker-entrypoint.sh ./

# /sockets guarda o socket Unix compartilhado com o nginx. Precisa existir na
# imagem e pertencer ao usuário: um volume nomeado herda a posse do diretório da
# imagem na primeira criação — se não existir, o Docker o cria como root e a
# aplicação não consegue escrever nele.
#
# /app precisa ser gravável porque o script do release escreve em /app/tmp.
RUN adduser --uid 10001 --disabled-password --home /home/rinha rinha \
 && mkdir -p /sockets /app/tmp \
 && chown -R rinha:rinha /app /home/rinha /sockets
USER rinha

ENTRYPOINT ["/app/docker-entrypoint.sh"]
