# Instruções do projeto

Laboratório de estudo sobre a Rinha de Backend 2024/Q1. A competição encerrou;
usamos as regras como especificação de um exercício sobre teste de carga,
concorrência e limitação de recursos. **O objetivo é aprender e medir**, não
vencer nada — resultado sem metodologia registrada não vale.

Comece pelo [README](./README.md) e por
[`.claude/docs/00-indice.md`](./.claude/docs/00-indice.md).

## Idioma

Documentação, comentários de código, mensagens de commit e conversa **em
português**. Nomes de variáveis, funções e arquivos também — o código já usa
`transacao`, `saldo`, `verificar_clientes`. Termos técnicos consagrados ficam em
inglês (*throttling*, *keep-alive*, *worker*, *pool*).

## A regra que atravessa tudo: medir antes de afirmar

Este projeto derrubou várias afirmações que eu tinha feito com confiança —
"`DEBUG` vaza memória", "o Gunicorn ganha por keep-alive", "o Postgres vai pedir
mais workers". Todas falsas, e todas registradas em `04-aprendizados.md`, seção
**Erros cometidos**.

Consequências práticas:

- **Verificar no fonte antes de afirmar** comportamento de biblioteca. O fonte
  está em `django/.venv/lib/python3.14/site-packages/`. Citar arquivo e linha.
- **Registrar a hipótese antes de medir**, para o placar ficar honesto.
- **Corrigir o registro quando a medição contradiz.** Um documento que só tem
  acertos não é um diário, é propaganda.

## Ferramental de medição

Duas ferramentas, papéis separados, **nunca comparadas entre si**:

| | Papel |
| - | - |
| **`oha`** | comparar configurações. Mede folga em saturação, em 10s |
| **Gatling** | aprovar. A prova oficial, 4 minutos, com asserções de consistência |

A pontuação do Gatling **satura**: com 35x de folga no SLA, toda configuração
razoável marca USD 100.000. Ela aprova, não compara.

### Regras de medição, todas aprendidas na marra

- **Descartar a rodada de aquecimento.** A primeira execução de qualquer
  configuração é sistematicamente mais lenta.
- **Repetir e reportar amplitude.** Diferença abaixo de ~3% é ruído. Amplitude
  alta não é ruído a ser mediado: é um mecanismo pedindo para ser encontrado.
- **Commitar antes de medir.** Os scripts abortam com a árvore suja, porque o
  resultado grava o hash do commit. `resultados/` é exceção — é saída.
- **Sob cgroup, a métrica é CPU por requisição**, não rps. Vazão é consequência:
  cota ÷ custo.
- **Olhar `nr_throttled` por serviço** antes de culpar a aplicação.
- **Todo script de medição deve abortar** quando não reconhecer o que está
  lendo. Três bugs deste projeto produziram números plausíveis em vez de erro.

## Convenções

### Documentação de experimentos

Um arquivo por experimento em `.claude/docs/performance/<projeto>/` — um
diretório por pasta de framework (`django/`, `fastapi/`, `elixir/`, `go/`), cada um com seu
índice. A numeração é **cronológica**, reinicia em cada projeto e pode ser
renumerada; ao citar experimento de outro projeto, use o caminho (`django/06`).

Ordem obrigatória dentro do arquivo: ressalvas metodológicas → ambiente e commit
→ comandos para replicar → números crus → conclusões. As ressalvas vêm **antes**
dos números de propósito: o gráfico sobrevive, o contexto some.

Aprendizados que valem além de um experimento vão para
`04-aprendizados.md`. Atalhos que só existem por ser competição vão para
`05-hacks-da-competicao.md`, isolados num arquivo `hacks.*` por stack — os
mesmos atalhos nas quatro, com o mesmo nome.

### Código

- **Comentários explicam o porquê, com o número que sustenta a decisão.** Ver
  `django/kernel/settings.py` e `infra/nginx/nginx-rinha.conf`.
- **Type hints** no código de produção.
- Testes de domínio em `crebitos/tests.py`; os que só fazem sentido por causa
  dos hacks, em `crebitos/tests_hacks.py`.
- `shellcheck` em todo shell antes de rodar — ele já pegou bugs reais aqui.
- Python de mais de ~15 linhas vira arquivo, não heredoc dentro do justfile:
  `{{` é sintaxe do just e linha não indentada encerra a receita.

### justfile e scripts

O justfile é a **interface** (quais comandos existem); `scripts/` é a
**implementação**. Receita inline só para orquestração — uma lista de chamadas.
Se tem `if`, `case`, `trap` ou parsing, vira arquivo em `scripts/`.

### Estrutura

Monorepo. Outras stacks entram como **diretórios irmãos** de `django/`, não como
branches — `resultados/` precisa ficar plano para os comparativos funcionarem, e
`infra/`, `scripts/` e o `justfile` são compartilhados.

Configurações alternativas são **variáveis de ambiente**, não branches:
`BENCH_SERVER`, `BENCH_POOL`, `API_SERVER`, `DB_PERSISTENTE`. Elas convivem no
mesmo commit, e é isso que torna a comparação possível.

## Armadilhas específicas deste ambiente

- **Docker Desktop sobre WSL2**: containers rodam numa VM, então
  `network_mode: host` **não** alcança o localhost do WSL.
- **`MB` no Docker é MiB.** Uma stack declarando 550MB recebe 577 MB decimais.
  `scripts/check-limites.py` compara na unidade declarada, que é o critério da
  competição.
- **O container não sabe que tem 0.40 CPU**: `os.cpu_count()` devolve 20 lá
  dentro. Todo runtime que se dimensiona por número de núcleos cai nessa
  armadilha.
- **Rigs de bancada e stack de produção usam nomes de projeto Compose
  diferentes.** Com o mesmo nome, um container remanescente bloqueia o outro.
- **`pg_isready` sem `-h 127.0.0.1` aprova o servidor temporário** que a imagem
  do Postgres sobe durante a inicialização.
- **O bundle do Gatling mudou na 3.13**: não existe mais `bin/gatling.sh`. O
  projeto Maven em `gatling/` traz o `scala-maven-plugin` necessário.

## Não modificar

`rinha-de-backend-2024-q1/` é o clone oficial, read-only e gitignored. A
simulação em `gatling/src/test/scala/` é cópia bit a bit da oficial — alterá-la
invalida a comparação.
