# Testes de performance — Elixir

Índice geral em [../00-indice.md](../00-indice.md). A numeração reinicia aqui: o
experimento 01 do Elixir **não** é continuação do 03 do FastAPI.

| # | Experimento | Data | Estado |
| - | - | - | - |
| [01](./01-a-beam-sob-cota.md) | A BEAM sob cota: as duas armadilhas **não aparecem**. A parte *"mais caro que o FastAPI"* foi **derrubada pelo 04** | 2026-08-25 | **parcialmente superado** |
| [02](./02-ocioso-na-carga-real.md) | Ocioso por serviço na carga real: ninguém passa de 42% da cota — **não há o que redistribuir** | 2026-08-25 | **concluído** (números anteriores ao 04) |
| [03](./03-sem-cota-varios-nucleos.md) | Sem limitação de hardware, em 20 vCPU. A inversão do braço B **sumiu depois do 04** | 2026-08-25 | **superado pelo 04** |
| [04](./04-o-statement-que-nao-era-reusado.md) | O statement não era reusado: `plans = calls` e **62,2% do tempo de banco planejando**. Corrigido, o Elixir vira o **mais barato dos três** | 2026-08-25 | **concluído** |

## Por que este projeto existe

Ele fecha a última pendência de linguagem registrada em
[`django/06`, seção 8](../django/06-tipos-de-worker.md), junto com o Go: *"e se
trocássemos de linguagem?"*. O FastAPI respondeu a pergunta **dentro** do Python
— trocar de framework comprou 1,73x na escrita e 4,00x na leitura
([fastapi/03](../fastapi/03-o-que-a-troca-de-framework-comprou.md)). O Elixir
responde a pergunta **fora** dele: outra linguagem, outra máquina virtual, outro
modelo de concorrência.

E traz uma pergunta que nenhum experimento anterior pôde fazer: **o
escalonamento preemptivo da BEAM ajuda ou atrapalha sob cota de cgroup?** A
previsão registrada diz que atrapalha — quando a cota acaba, o cgroup congela
todos os schedulers de uma vez, e não existe escalonamento justo dentro de um
processo congelado.

---

## 1. Vocabulário: quem é quem no Elixir

Esta seção existe porque o autor deste repositório vem de Python e não conhecia
nada do ecossistema Elixir quando o projeto começou. Ela mapeia cada peça para
o equivalente que já está medido nos projetos `django/` e `fastapi/`.

| Camada | Python (já medido aqui) | Elixir | O que faz |
| - | - | - | - |
| Driver do banco | `asyncpg`, `psycopg` | **Postgrex** | Fala o protocolo binário do Postgres. SQL entra, tupla sai |
| ORM / camada de dados | Django ORM, SQLAlchemy | **Ecto** | Mapeia tabelas para estruturas, gera SQL, valida, faz migrations |
| Servidor HTTP | `uvicorn`, `gunicorn` | **Bandit**, **Cowboy** | Aceita conexões TCP e faz parsing de HTTP |
| Especificação + cola | ASGI, WSGI | **Plug** | O contrato entre servidor e aplicação, mais middlewares. `Plug.Router` dá roteamento |
| Framework completo | Django, FastAPI | **Phoenix** | Controllers, views, WebSockets, LiveView, geradores |
| Gerenciador de pacotes | `uv`, `pip` | **Hex** (via `mix`) | Baixa e resolve dependências |
| Ferramenta de projeto | `manage.py`, `uv run` | **Mix** | Compila, roda testes, roda tarefas, monta releases |
| Framework de teste | `pytest` | **ExUnit** | Vem na biblioteca padrão |
| Gerenciador de versão | `pyenv`, `nvm` | **`mise`**, **`asdf`** | Instala várias versões da linguagem lado a lado |

### `mise` / `asdf`

São o que `pyenv` e `nvm` já são para este ambiente, só que genéricos: um único
gerenciador para Erlang, Elixir, Python, Node, Go. Aqui isso importa por um
motivo concreto: **Elixir e Erlang são dois pacotes que precisam casar de
versão** (Elixir 1.18 exige OTP 25–27), e o `apt` do Ubuntu empacota versões
velhas. `mise use -g erlang@27 elixir@1.18` resolve o par.

Instalar no host é opcional — a medição acontece toda em container. Serve para
rodar o ExUnit rápido, que é o mesmo papel de `just fa-serve` e `just dj-serve`.

### As duas decisões de escopo, e por quê

**Sem Ecto.** Os dois projetos existentes já executam SQL cru no caminho quente:
o Django abandonou o ORM ali em [`django/04`](../django/04-postgres.md), e o
FastAPI nunca teve ORM. Usar Ecto aqui mediria "SQL cru vs. Ecto" **misturado**
com "CPython vs. BEAM" — duas variáveis num salto, exatamente o erro que
[`fastapi/03`, seção 4.1](../fastapi/03-o-que-a-troca-de-framework-comprou.md)
identificou na própria comparação Django↔FastAPI. Postgrex direto é o par
honesto do `asyncpg`.

**Sem Phoenix.** Phoenix não é alternativa ao Plug: ele é construído **em cima**
do Plug, que por sua vez roda sobre o Bandit. Escolher Phoenix é escolher
Plug + controllers + views + LiveView + Channels + PubSub + i18n, e nada disso
é usado por dois endpoints JSON. O par estrutural do FastAPI (uma casca fina
sobre Starlette) é Bandit + Plug; o par do Django seria Phoenix, e a stack
Django já existe. A decisão vale só para este experimento: se um dia a pergunta
for "quanto custa o Phoenix", ele entra como projeto próprio, não como variável
de ambiente — a escolha é de compilação, não de `env`.

---

## 2. A BEAM não vira binário — e por que isso muda o Dockerfile

Comparação com o que já está no repositório:

- **Go** compila para **código de máquina**. O binário roda direto no kernel; não
  existe "runtime do Go" separado, ele foi embutido.
- **Elixir** compila para **bytecode `.beam`**, que exige a **BEAM** — uma
  máquina virtual, mesmo papel do CPython para o Python e da JVM para o Java.
  Desde o OTP 24 a BEAM tem um JIT (BeamAsm) que traduz o bytecode para código
  de máquina no carregamento, o que a coloca bem acima do CPython e bem abaixo
  do Go.

O `mix release` produz um **diretório**, não um binário:

```
_build/prod/rel/rinha/
├─ bin/rinha       <- script shell, não executável nativo
├─ erts-15.x/      <- a máquina virtual inteira, copiada para dentro
├─ lib/            <- o bytecode .beam da app e das dependências
└─ releases/
```

É **autocontido** — não exige Erlang instalado no destino, e por isso o estágio
final do Dockerfile pode ser um `alpine` pelado — mas não é um binário único.

### Multi-stage não é novidade do Elixir

O [`fastapi/Dockerfile`](../../../../fastapi/Dockerfile) já tem dois estágios
(`deps` e `runtime`). O princípio é o mesmo em toda linguagem: **o que se precisa
para construir não é o que se precisa para executar**, e o `COPY --from=` copia
só o resultado. O que muda é o **quanto** cada linguagem descarta.

| Linguagem | O que sobra no estágio final | Ganho do multi-stage |
| - | - | - |
| Go, Rust, C | um binário; a imagem pode ser `scratch` | enorme |
| Elixir/Erlang | bytecode `.beam` + ERTS (~15–25MB) | grande: some o compilador, o Mix e os fontes |
| Java, C# | `.jar`/`.dll` + JVM ou runtime .NET | grande, mas o runtime é pesado sem `jlink`/AOT |
| Python, Node | interpretador + dependências | modesto: joga fora `gcc` e caches de build |

Aqui isso tem uma consequência medida e uma não medida: a imagem **não** conta
no orçamento de 550MB, mas o **tempo de subida** conta — limite de 40s, e o
FastAPI sobe em 7s.

---

## 3. As três armadilhas da BEAM sob cgroup

Este é o conteúdo técnico do experimento, e as três têm precedente registrado.

**1. Schedulers por núcleo visível.** [`django/02`](../django/02-container-e-cgroup.md)
mediu `os.cpu_count() = 20` dentro de um container com 0.40 CPU: **o cgroup
limita a cota, não a visibilidade**. A BEAM sobe, por padrão, um scheduler por
núcleo visível, mais dirty schedulers — ou seja, ~20 + 10 + 10 threads
disputando 0.40 CPU. É a mesma armadilha do `GOMAXPROCS` prevista para o Go, e o
mesmo mecanismo que fez 4 workers de Gunicorn perderem para 1 em
[`django/04`](../django/04-postgres.md). Correção: `+S 1:1 +SDcpu 1:1 +SDio 1`.

**2. Busy-wait queima cota sem fazer trabalho.** Esta **não** estava prevista em
`django/06` e é a hipótese própria deste experimento. Os schedulers da BEAM
fazem *spin* antes de dormir, apostando que trabalho novo chega logo — uma
troca boa numa máquina dedicada e possivelmente péssima sob cota, porque o
cgroup cobra o spin como CPU usada. Correção candidata:
`+sbwt none +sbwtdcpu none +sbwtdio none +swt very_low`.

**3. Socket Unix.** [`django/03`](../django/03-nginx-e-socket-unix.md) mediu 2,9x
e queda de amplitude de 246% para 3,9% no salto nginx→API. Manter isso exige
que o Bandit escute num socket Unix (`ip: {:local, caminho}` no ThousandIsland),
e que o socket seja legível pelo nginx, que roda com outro usuário — daí o
`umask 0` no entrypoint, igual ao do FastAPI. **Se não funcionar, o experimento
perde comparabilidade com os outros dois projetos**, e isso precisa virar
ressalva, não silêncio.

Uma quarta, menor: o JIT da BEAM aquece. A bancada `oha` é de 10s, com a
primeira rodada descartada; se o aquecimento não couber aí, vira ressalva.

---

## 4. Previsão registrada ANTES de medir

Copiada de [`django/06`, seção 8](../django/06-tipos-de-worker.md), escrita em
2026-08-22, antes de existir uma linha de Elixir. **Não editar** — o valor deste
registro está em poder estar errado, e o do FastAPI já mostrou como isso
funciona: certo na escrita, subestimado na leitura, e pelo motivo errado.

| | CPU/req | vs. Django | pontuação |
| - | - | - | - |
| Django + Gunicorn sync (**medido**) | **862,4 µs** | — | 100.000 |
| FastAPI + uvicorn + asyncpg (**medido**) | **499,7 µs** | 1,73x | 100.000 |
| Elixir/BEAM (**previsto**) | 150–400 µs | 2–6x | 100.000 |

Ou seja: a previsão de 2026-08-22 coloca o Elixir **entre empatar e ganhar 3,3x
do FastAPI** na escrita — e admite abertamente a possibilidade de empate. A BEAM
não é uma máquina de números rápida; a força dela é outra.

As previsões qualitativas, todas testáveis:

1. **A pontuação continua em USD 100.000**, e continua não significando nada.
   São 50x de folga contra o SLA; não existe nota acima do teto.
2. **`SCHEDULERS=auto` terá cauda pior que o Django atual**, mesmo sendo mais
   rápido por requisição — 40 threads disputando 0.40 CPU. Mesma forma da
   previsão registrada para o Go.
3. **`BUSY_WAIT=default` custará mais CPU/req que `SCHEDULERS=auto`.** Aposta
   própria deste experimento: sob cota, spin é desperdício puro, enquanto
   schedulers demais pelo menos fazem trabalho entre as trocas de contexto.
4. **A vantagem da BEAM aparecerá na cauda, não na média** — e só nos regimes em
   que a cota **não** está saturada. Sob throttling, o cgroup congela todos os
   schedulers juntos e a justiça interna não tem o que resolver.
5. **A comparação sofrerá do mesmo problema de atribuição da seção 4.1 de
   [fastapi/03](../fastapi/03-o-que-a-troca-de-framework-comprou.md)**: mudam
   linguagem, VM, servidor HTTP e driver de uma vez.
6. **A memória é o risco real, não a CPU.** O limite é 100MB por instância de
   API, e a BEAM pré-aloca mais que um processo Python. Se estourar, a saída
   seria tirar memória do banco — e aí muda mais uma variável.

---

## 5. O que se mantém idêntico (uma variável por vez)

A lista vem de [`fastapi/03`, seção 6](../fastapi/03-o-que-a-troca-de-framework-comprou.md).
Sem isto a comparação não vale:

- schema e carga inicial: `infra/sql/ddl.sql` e `dml.sql`, tabelas `crebitos_*`,
  índice `idx_transacao_extrato` — inclusive a tabela `django_migrations`, peso
  morto mantido de propósito
- estratégia de concorrência: `UPDATE ... WHERE saldo + $1 >= -limite RETURNING`
- load balancer: `infra/nginx/nginx-rinha.conf`, socket Unix, round-robin
- configuração do banco: `infra/postgres/postgresql.conf`, `max_connections = 20`
- repartição da cota: nginx 0.10, API 0.40 × 2, banco 0.60 — a que a prova
  oficial preferiu em [`fastapi/02`](../fastapi/02-onde-esta-o-gargalo.md)
- bancada: `oha`, 10s, 5 repetições, aquecimento descartado, concorrência 50
- estado inicial: 50 transações por cliente, mesmos valores, mesma ordem
- hacks: os mesmos, isolados num módulo só (`lib/rinha/hacks.ex`)

## 6. As variantes deste projeto

Variáveis de ambiente, não branches — convenção do `CLAUDE.md`.

| Variável | Valores | O que isola |
| - | - | - |
| `SCHEDULERS` | `1` (padrão) / `auto` | armadilha nº 1: schedulers por núcleo visível |
| `BUSY_WAIT` | `none` (padrão) / `default` | armadilha nº 2: spin sob cota |
| `EXTRATO_QUERY` | `unica` (padrão) / `duas` | a mesma variante que rendeu 1,25x no FastAPI |
| `JSON_LIB` | `jason` (padrão) / `otp` | custo do serializador, paralelo ao `SERIALIZACAO` do FastAPI |
| `DB_POOL_MAX` | `8` (padrão) | teto por instância: 2 APIs × 8 + folga ≤ 20 conexões |

Toda opção desconhecida **aborta a subida**. Regra do projeto: três bugs já
produziram números plausíveis em vez de erro.

---

## 7. Observações da subida — antes de qualquer medição

Não são resultado de experimento: são o que a stack mostrou ao subir pela
primeira vez, no commit em que este documento foi escrito. Ficam registradas
aqui porque **duas delas já colocam previsões da seção 4 em dúvida**, e o
registro precisa acontecer antes de a medição existir.

### 7.1 A armadilha nº 1 pode não existir no OTP 27

A previsão diz que a BEAM sobe um scheduler por núcleo **visível**, e que
`SCHEDULERS=auto` seria a armadilha. Medindo a BEAM crua, sem a aplicação:

```bash
for c in 0.4 1 2 4; do
  docker run --rm --cpus=$c hexpm/elixir:1.18.4-erlang-27.3.4-alpine-3.21.3 \
    elixir -e 'IO.puts("#{:erlang.system_info(:schedulers_online)} / #{:erlang.system_info(:logical_processors_available)}")'
done
```

| cota | schedulers online | dirty-cpu | núcleos visíveis |
| - | - | - | - |
| sem cota | 20 | 20 | 20 |
| 0.40 CPU | **1** | 1 | 20 |
| 1 CPU | 1 | 1 | 20 |
| 2 CPU | 2 | 2 | 20 |
| 4 CPU | 4 | 4 | 20 |

**O OTP 27 lê a cota do cgroup e se dimensiona por ela**, mesmo continuando a
enxergar 20 núcleos. Ou seja: nesta versão a BEAM **não** cai na armadilha que
`os.cpu_count()` cravou para o Python e que a previsão do Go crava para o
`GOMAXPROCS`.

Isso não apaga a variante `SCHEDULERS` — apaga a **expectativa** sobre ela. A
previsão nº 2 da seção 4 ("`SCHEDULERS=auto` terá cauda pior que o Django
atual") está, antes de medir, provavelmente errada: `auto` e `1` devem coincidir
sob 0.40 CPU. O experimento passa a responder outra pergunta, mais interessante:
**a partir de que cota `auto` e um valor fixo divergem?** — e o rig
`postgres-sem-limite` é onde eles divergem por construção.

A previsão fica como está, na seção 4. Um documento que só tem acertos não é um
diário.

### 7.2 A memória não é o problema previsto — mas encosta no teto ao subir

A previsão nº 6 dizia que a memória seria o risco real. Com a stack de pé e
ociosa, dentro do container de API:

```
memory.current  38 MB de 100 MB       (anon 17 MB, page cache 17 MB)
memory.events   max 566, oom 0, oom_kill 0
```

Duas leituras, e elas discordam de propósito: **17MB de memória anônima** é
bastante folgado — menos que o processo Python, ao contrário do previsto. Mas
`max 566` diz que o cgroup bateu no teto 566 vezes e teve de recuperar páginas,
tudo cache de arquivo, sem uma única morte por OOM. É custo de subida (ler o
release do disco), não de regime.

Fica como ponto a vigiar sob carga, não como problema resolvido.

### 7.3 O socket Unix funciona no Bandit

Era o risco que poderia inviabilizar a comparação (seção 3, armadilha 3). O
`ThousandIsland` aceita `transport_options: [ip: {:local, caminho}]` com
`port: 0`, o nginx do `infra/nginx-rinha.conf` faz round-robin entre os dois
sockets sem alteração alguma, e os 13 testes do `smoke` passam.

### 7.4 A stack sobe em ~4s

Contra 7s do FastAPI e ~20s do Django, num limite de 40s. Não é resultado de
experimento — é o `just up` cronometrando a si mesmo — mas confirma que o
release não paga custo de inicialização relevante.
