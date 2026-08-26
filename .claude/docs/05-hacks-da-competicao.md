# 05 — Hacks da competição

Catálogo dos atalhos que só se justificam por isto ser um desafio fechado, com
regras congeladas e um único cenário de carga conhecido. **Nada aqui sobreviveria
a uma aplicação real.**

Cada entrada segue o mesmo formato: qual premissa do desafio o atalho explora, o
que se ganha, o que se perde, e onde ele vive no código — para ser fácil de
desligar numa comparação A/B ou apagar de vez.

Convenção adotada: código de atalho fica isolado num arquivo só por stack, e os
testes que o cobrem ficam separados. **Os quatro projetos usam os mesmos hacks,
com o mesmo nome, no mesmo lugar** — se uma stack ganhasse por ter um atalho a
mais, a diferença medida não seria da linguagem:

| stack | arquivo |
| - | - |
| Django | `django/crebitos/hacks.py` + `tests_hacks.py` |
| FastAPI | `fastapi/app/hacks.py` |
| Elixir | `elixir/lib/rinha/hacks.ex` |
| Go | `go/hacks.go` |

Comentários no código apontam
para cá em vez de repetir a justificativa.

---

## Modelagem

### M1 — `saldo` desnormalizado em `clientes`

**Premissa explorada**: nenhuma. Este não é bem um hack — é a decisão correta
também num sistema real de contas, e está aqui só para contraste.

O saldo é a fonte da verdade, não um `SUM(transacoes.valor)`. Sem isso não existe
o `UPDATE ... WHERE saldo + delta >= -limite RETURNING`, que é o que resolve
validação e escrita num único passo atômico.

**Onde**: `crebitos/models.py`, `Cliente.saldo`.

---

### M2 — Sem foreign key no banco (`db_constraint=False`)

**Premissa explorada**: só existe um caminho de escrita, e ele já garante a
integridade — a transação só é inserida depois do `UPDATE` condicional ter dado
match num cliente existente.

**Ganho**: uma FK real faz cada INSERT tomar um `SELECT ... FOR KEY SHARE` na
linha do cliente. São 5 linhas absorvendo ~330 writes/s — é lock adicional
exatamente no ponto de maior contenção do sistema.

**Perda**: o banco passa a aceitar transações órfãs. Qualquer segundo caminho de
escrita (script, migração, correção manual) pode corromper os dados em silêncio.

**Status**: candidato a A/B. Medir com e sem FK antes de cravar.

**Onde**: `crebitos/models.py`, `Transacao.cliente`.
**Testes**: `SemForeignKeyNoBancoTest`.

---

### M3 — Índice único e composto `(cliente, -id)`

**Premissa explorada**: existe exatamente **um** padrão de leitura em
`transacoes` — as 10 últimas de um cliente. Nada mais é consultado, nunca.

**Ganho**: um índice serve 100% das leituras; o índice simples que o Django
criaria por padrão em `cliente_id` seria peso morto pago em todo INSERT.

**Perda**: qualquer consulta nova (por período, por tipo, agregações, relatórios)
vira seq scan.

**Onde**: `crebitos/models.py`, `Transacao.Meta.indexes`.

---

### M4 — Desempate por `id` em vez de só `realizada_em` *(candidato)*

**Premissa explorada**: a sequence é monotônica e, num único banco, a ordem de
`id` coincide com a ordem cronológica de inserção.

**Contexto**: o README exige ordem decrescente por data/hora, e o Gatling
**verifica** — a simulação faz um crédito `toma` seguido de um débito `devolve` e
exige `ultimas_transacoes[0] == devolve`. Sob 340 req/s os timestamps empatam, e
`ORDER BY realizada_em DESC` sozinho tem ordem indefinida no empate.

**Perda**: num sistema distribuído, ou com múltiplos bancos, ou com importação de
dados históricos, `id` deixa de refletir cronologia.

**Onde**: `crebitos/models.py`, `Transacao.Meta.ordering`.
**Testes**: `ExtratoTest.test_ordem_e_estavel_quando_os_timestamps_empatam`.

---

### M5 — Últimas 10 transações num `JSONB` no próprio cliente *(não implementado)*

**Premissa explorada**: o extrato expõe no máximo 10 transações e **nada mais lê
essa tabela**. O histórico completo não tem consumidor.

**Ideia**: eliminar a tabela `transacoes` e guardar um array/JSONB de 10 posições
em `clientes`. Débito e registro viram um **único** `UPDATE`: aplica o delta,
empurra a transação na frente do array, corta em 10, `RETURNING`.

**Ganho**: mata o INSERT, a sequence e o índice. Um round-trip por transação em
vez de dois, e uma linha tocada em vez de duas.

**Perda**: o histórico deixa de existir. A lógica de janela deslizante migra para
o SQL. Auditoria e conciliação ficam impossíveis — num sistema financeiro real,
inaceitável.

**Status**: variante planejada para o benchmark comparativo. O modelo
normalizado é o baseline.

---

### M7 — `IntegerField` em vez de `PositiveIntegerField` em `valor`

**Premissa explorada**: só existe um caminho de escrita, e `validar_payload` já
garante `valor > 0` antes de qualquer INSERT.

**Contexto**: `PositiveIntegerField` parece a escolha óbvia — o valor de fato só
pode ser positivo. Mas no Postgres ele não vira um tipo diferente: vira
`integer` **mais uma CHECK constraint** (`valor >= 0`), avaliada em todo INSERT.
É o mesmo raciocínio de M2, em escala menor: constraint no caminho mais quente
para reafirmar algo que a aplicação já garantiu.

E há um detalhe que decide a questão: `PositiveIntegerField` expressa `>= 0`,
não `> 0`. Ele **aceitaria** `valor = 0`, que o contrato proíbe. Ou seja, nem
sequer substitui a validação da aplicação — só a duplicaria pela metade.

**Perda**: o banco aceita `valor` negativo se alguém escrever por fora do fluxo.

**Nota honesta**: numa aplicação real eu usaria a constraint. O custo é pequeno
e defesa em profundidade vale mais que microssegundos. Aqui, com 330 INSERTs/s
sob 1.5 CPU somando tudo, a conta muda.

**Onde**: `crebitos/models.py`, `Transacao.valor`.

---

### M6 — Ausência da coluna `nome`

O exemplo do README cadastra `nome`, mas nenhum endpoint o devolve. Fora do
modelo. Custo zero, ganho marginal — registrado só por completude.

---

## Validações

### V1 — Existência do cliente resolvida em memória (`1 <= id <= 5`)

**Premissa explorada**: o README fixa exatamente 5 clientes, criados na carga
inicial, e **proíbe** cadastrar o ID 6 — parte do teste é confirmar que ele
devolve 404. Não existe endpoint de cadastro. O conjunto de IDs é imutável e
conhecido em tempo de compilação.

**Ganho duplo**:
1. Zero round-trips para responder 404.
2. Desambigua o `UPDATE ... RETURNING` que devolve zero linhas. Sem o atalho, ao
   receber zero linhas você não sabe se foi cliente inexistente (404) ou limite
   estourado (422), e precisa de uma segunda query para descobrir.

**Perda**: o código passa a mentir se o banco divergir. Um cliente real fora da
faixa fica invisível para a API.

**Status**: **ligado**. As duas views chamam `cliente_existe()` antes de
qualquer outra coisa. `Cliente.transacao` mantém a desambiguação por query como
rede de segurança — ela só roda no caminho de erro, nunca no caminho quente, e é
o que sobra se o atalho for desligado.

**Como fazer o A/B**: comentar o `if not cliente_existe(...)` nas duas views. O
comportamento externo não muda; o que muda é o número de round-trips.

**Onde**: `crebitos/hacks.py` (`cliente_existe`), acionado em `crebitos/views.py`.
**Testes**: `ClientesHardcodedTest`, `EndpointsComAtalhoTest`.

---

### V4 — 404 tem precedência sobre 422

Consequência de V1: como a verificação de ID vem antes do parse do corpo, um
request para o cliente 6 com JSON inválido devolve **404**, não 422. O README não
define precedência e o Gatling nunca envia payload inválido para um ID
inexistente — o caso conflitante não existe no teste.

**Testes**: `EndpointsComAtalhoTest.test_404_vem_antes_da_validacao_de_payload`.

---

### V2 — Ordem das validações: payload → cliente → limite

**Premissa explorada**: o README não define precedência entre 422 e 404, e o
teste de carga nunca envia um payload inválido para o cliente 6 — o caso
conflitante não é exercitado.

**Ganho**: payload inválido é rejeitado sem tocar no banco.

**Perda**: nenhuma prática, mas a escolha é arbitrária e outra implementação
poderia devolver 404 onde devolvemos 422 no caso conflitante.

**Onde**: `crebitos/models.py`, `Cliente.transacao`.
**Testes**: `TransacaoTest.test_payload_invalido_nao_toca_no_banco`.

---

### V3 — Corpo de resposta vazio nos erros

O README diz explicitamente que o corpo de 404 e 422 **não é testado**. Não vale
serializar mensagem de erro alguma: é CPU e bytes gastos em algo que ninguém lê.

**Perda**: API impossível de depurar do lado do cliente.

---

## Infraestrutura

### I1 — Django sem DRF

**Premissa explorada**: são **dois** endpoints, sem autenticação, sem negociação
de conteúdo, sem paginação e sem relacionamentos aninhados.

**Ganho**: cada request do DRF paga instanciação de `Request`/`Response`
próprios, resolução de parser e renderer, cadeia de autenticação e permissão
(iterada mesmo quando vazia), e um `Serializer` com metaclasse construindo
`fields`. Nada disso compra nada aqui — a validação inteira cabe em 12 linhas, e
é *mais* precisa que a de um `Serializer`, que não barra `bool` num
`IntegerField` sem configuração extra.

**Perda**: nenhuma feature que usaríamos. O que se perde é a consistência que o
DRF impõe num projeto com dezenas de endpoints — irrelevante com dois.

**Status**: "quanto custa o DRF nesta carga?" é uma pergunta mensurável e sem
resposta pública. Vale como variante do Bloco D mais adiante.

**Onde**: `crebitos/views.py` — views de função, `HttpResponse` cru.

---

### I2 — `settings.py` esvaziado

**Premissa explorada**: nenhum dos apps e middlewares padrão do `startproject`
participa dos dois endpoints do contrato.

Por decisão de projeto, as linhas estão **comentadas e não apagadas**, para o
tamanho do corte ficar visível ao abrir o arquivo. Cada linha carrega o motivo.

| O que foi cortado | Por quê |
| - | - |
| `admin`, `auth`, `contenttypes` | não há rota de admin nem autenticação |
| `sessions` | nada é guardado entre requests; o middleware consultaria o banco |
| `messages`, `staticfiles` | nenhuma resposta é HTML; nenhum arquivo é servido |
| `SecurityMiddleware` | HSTS e redirect SSL — estamos atrás do LB, sem TLS |
| `CsrfViewMiddleware` | **barraria todo POST da carga** por falta de token |
| `CommonMiddleware` | `APPEND_SLASH`, ETag, User-Agent banidos |
| `AuthenticationMiddleware` | `request.user` nunca é lido |
| `TEMPLATES` | o motor de templates nunca é acionado |
| `USE_I18N` | desligado: evita a maquinaria de tradução por request |

`MIDDLEWARE` fica **vazio**. Isso significa que não há nada entre o handler e a
view — nem CSRF, nem `ALLOWED_HOSTS` reforçado por middleware, nem compressão.

**Perda**: o projeto deixa de ser um Django "normal". Adicionar qualquer coisa
que dependa de sessão, admin ou template exige religar peças, e o erro aparece
como `ImproperlyConfigured` no lugar errado.

**Onde**: `kernel/settings.py`.

---

### I3 — `ALLOWED_HOSTS = ['*']`

Atrás do load balancer o `Host` chega como o nome do serviço (`api01`/`api02`)
ou o IP do container. Validar isso não protege nada num ambiente fechado, custa
uma comparação por request, e um mismatch derrubaria a API inteira com HTTP 400 —
risco assimétrico e sem contrapartida.

**Perda**: em produção real, `Host` header poisoning.

**Onde**: `kernel/settings.py`.

---

### I4 — Fixture como fonte única da carga inicial

Os 5 clientes vivem em `crebitos/fixtures/clientes.json`, carregados por
`just dj-seed`. O comando `manage.py verificar_clientes` (`just dj-verify`)
confere que o estado do banco bate com a tabela do README e que o ID 6 **não**
existe — pensado para rodar também no entrypoint do container, porque falhar na
subida é muito melhor que descobrir a divergência no relatório do Gatling.

**Atenção à duplicação**: quando existir `infra/sql/` com o `ddl.sql`/`dml.sql`
do Postgres, os limites passarão a estar em dois lugares. `dj-verify` é a trava
que detecta a divergência, e `FixtureDosCincoClientesTest` é a que trava a
fixture contra `hacks.IDS_VALIDOS`.

---

## Armadilhas (não são hacks — são erros a evitar)

Registrado aqui para não se perder, mesmo não sendo atalho:

- **`bool` é subclasse de `int`.** `isinstance(True, int)` é `True`. Sem teste
  explícito, `{"valor": true}` vira um crédito de 1 centavo em vez de 422.
- **`descricao` de 1 a 10 caracteres** exclui `""` e `null`, não só o >10.
- **`now()` do Postgres é o timestamp de início da transação**, idêntico para
  tudo dentro do mesmo BEGIN. Usamos `timezone.now()` por linha, no Python.
- **`data_extrato` não é coluna** — é o instante da consulta, calculado na
  serialização.
- **Read-your-writes é obrigatório.** O Gatling faz um POST e 5 GETs paralelos
  exigindo que todos vejam a transação. Proíbe write-behind, cache sem
  invalidação síncrona e réplica de leitura com lag.
