# go/03 — As quatro stacks sob a cota da Rinha, e quanto código cada uma custou

Comparativo das quatro implementações **no regime da competição**: API em 0.40
CPU, banco em 0.60, mesmo schema, mesmo SQL, mesma bancada.

> **Versão 2.** A primeira comparava séries de quatro commits diferentes. **As
> oito séries foram re-executadas no commit `2b408eb`**, no mesmo dia e no mesmo
> host, com cgroup do banco em todas — inclusive na do Django, que nunca o
> tivera. Os números mudaram de 0,7% a 3,9% e nenhuma posição trocou; o que
> mudou de verdade foi a seção 4, que passou a mostrar o Go com o banco saturado
> **também na escrita**.

E responde a uma curiosidade que atravessa o projeto inteiro: **linguagem que
ajuda mais o programador tende a ser pior em desempenho?** A seção 5 mede os dois
eixos e a resposta não é a que a pergunta espera.

---

## 1. Ressalvas metodológicas

1. **As oito séries foram re-executadas no mesmo commit** (`2b408eb`), no mesmo
   dia e no mesmo host — a versão anterior deste documento comparava quatro
   commits diferentes, e essa ressalva morreu. Os números mudaram de 0,7% a
   3,9% em relação aos publicados antes, sem trocar nenhuma posição.
2. **A leitura do Go é instável sob 0.60 CPU de banco** (amplitude de **31,4%**),
   porque ali o Postgres é a parede. O número de CPU por requisição da API
   continua válido — é o rps que não se pode citar como valor absoluto.
3. **A contagem de linhas mede este repositório, não as linguagens.** Quatro
   implementações escritas pela mesma pessoa, com a mesma arquitetura, no mesmo
   mês. Um projeto real teria dispersão maior.
4. **A pontuação satura em todas.** USD 100.000 nas quatro; nada aqui melhora
   nota.

---

## 2. Custo por requisição — a métrica que vale sob cgroup

`oha`, 10s, concorrência 50, 5 repetições, aquecimento descartado. **Sob cota, a
métrica é CPU por requisição**; vazão é consequência (cota ÷ custo).

### Escrita — `POST /clientes/1/transacoes`

| stack | CPU da API | vs. Django | rps | amplitude | CPU do banco | **quem congela** |
| - | - | - | - | - | - | - |
| Django + Gunicorn sync + psycopg | 856,1 µs | — | 486,7 | 2,1% | 390,9 µs | API 95,3% |
| FastAPI + uvicorn + asyncpg | 511,8 µs | 1,67x | 806,8 | 3,0% | 496,5 µs | API 93,5% |
| Elixir + Bandit + Postgrex | 444,4 µs | 1,93x | 930,0 | 3,1% | 475,0 µs | API 95,3% |
| **Go + net/http + pgx** | **323,0 µs** | **2,65x** | **1262,4** | 4,1% | 488,0 µs | **banco 93,5%** |
| *Go com `GOMAXPROCS=1`* | *241,5 µs* | *3,54x* | *1239,2* | *5,3%* | *496,9 µs* | *banco 93,5%* |

### Leitura — `GET /clientes/1/extrato`

| stack | CPU da API | vs. Django | rps | CPU do banco | **quem congela** |
| - | - | - | - | - | - |
| Django (ORM) | 1224,4 µs | — | 344,0 | 341,6 µs | API 95,3% |
| FastAPI | 256,9 µs | 4,77x | 1597,5 | 171,5 µs | API 92,6% |
| Elixir | 157,5 µs | 7,77x | 2608,2 | 118,4 µs | API 94,3% |
| **Go** | **105,2 µs** | **11,64x** | 2971,8 ⚠️ | 206,6 µs | **banco 92,7%** |
| *Go com `GOMAXPROCS=1`* | *74,0 µs* | *16,55x* | *2997,3* ⚠️ | *169,4 µs* | *banco 24,8%* |

⚠️ amplitude de 31,4% e 44,3%: o rps é diagnóstico, não medida (ressalva 2).

**O custo do banco é o mesmo para todos** — 475 a 497 µs na escrita nas três
stacks que reusam statements, com SQL idêntico. (O Django marca 390,9 µs por um
motivo que não é mérito: ele **não** reusa statements, e o número dele é de uma
carga 2,6x menor —
[`django/07`](../django/07-o-django-tambem-nao-reusava.md).) É a confirmação, agora com quatro drivers, do
que [`elixir/04`, §5.2](../elixir/04-o-statement-que-nao-era-reusado.md) mostrou
com dois: o que muda entre stacks é a aplicação, não o que o Postgres faz.

---

## 3. A prova oficial — onde a diferença toda desaparece

| | Django | FastAPI | Elixir | **Go** |
| - | - | - | - | - |
| pontuação | 100.000 | 100.000 | 100.000 | **100.000** |
| abaixo de 250ms | 100% | 100% | ~100% | **100%** (5 execuções) |
| p98 | 7 ms | 5 ms | 5 ms | **4 ms** |
| máximo | 76–94 ms | 246 ms | 51–101 ms | 104–216 ms |
| subida da stack | ~20 s | 7 s | 7 s | 7–8 s |
| inconsistências | 0 | 0 | 0 | **0** |
| CPU da API na carga real | — | — | 297–301 µs | **225–232 µs** |
| % do orçamento de 1.5 CPU | — | — | ~17% | **~13%** |

**Uma diferença de 2,65x na bancada virou 3ms de p98 na prova.** O pico da
simulação é 340 req/s e a stack mais lenta das quatro já entrega 483 rps de
escrita com **uma** instância sob 0.40 CPU (486,7 rps medidos). Toda a vantagem medida é folga que a
competição nunca pede — a conclusão de
[`fastapi/03`, §4.3](../fastapi/03-o-que-a-troca-de-framework-comprou.md),
agora com a quarta linguagem confirmando.

---

## 4. Onde está o gargalo em cada stack

Esta é a leitura mais útil da tabela da seção 2, e ela muda com a linguagem:

| stack | escrita | leitura |
| - | - | - |
| Django | **API** (95,3% congelada) | **API** (95,3%) |
| FastAPI | **API** (93,5%) | **API** (92,6%) |
| Elixir | **API** (95,3%) | **API** (94,3%) |
| **Go** | **o banco** (93,5%) — a API em 82,1% | **o banco** (92,7%) — a API em **0,9%** |
| *Go com `GOMAXPROCS=1`* | *o banco (93,5%)* | *o banco (24,8%)* |

**O Go é a primeira stack deste laboratório em que a aplicação sai da frente —
e agora nos DOIS endpoints.** A re-execução no commit único mostrou o banco
congelado em 93,5% também na escrita, com a API em 82,1%. Nas outras três, dar
mais cota à API sempre renderia; nesta, não renderia nada — o Postgres é a
parede, e é ele que precisa de cota.

Vale a ressalva que este projeto já pagou duas vezes: *throttling alto diz que um
serviço satura a própria cota, não que ele seja o limite do sistema*
([`fastapi/02`, §5.2](../fastapi/02-onde-esta-o-gargalo.md)). A prova operacional
foi feita: com o banco em 2 CPU, a leitura do Go sobe de 2753,9 para 3832,9 rps e
a amplitude cai de 35% para 9,1%
([`01`, §5.2](./01-a-aplicacao-sai-da-frente.md)).

---

## 5. Quanto código cada uma custou

Contagem por `scripts/contar-codigo.py` (`just codigo`), que exclui comentários,
docstrings/`@moduledoc` e linhas em branco. **Não usa `tokei` nem `cloc`**: as
duas contam docstring como código, o que puniria Python e Elixir por
documentarem com strings.

| grupo | Django | FastAPI | Elixir | **Go** |
| - | - | - | - | - |
| **aplicação** | **200** | **318** | **403** | **688** |
| configuração de framework | 89 | 0 | 39 | 0 |
| gerado (migrations) | 32 | 0 | 0 | 0 |
| **aplicação + framework** | **289** | **318** | **442** | **688** |
| testes | 312 | 316 | 243 | 483 |
| infra (Dockerfile, entrypoint, compose) | 142 | 121 | 121 | 112 |

A linha "infra" é o controle: 112 a 142 linhas nas quatro, como esperado de
arquivos que fazem a mesma coisa. Se ela destoasse, haveria variável escondida na
comparação.

### 5.1 A pergunta: linguagem que ajuda o programador é pior em desempenho?

Cruzando os dois eixos — código escrito e CPU por requisição na escrita:

| stack | linhas (app+framework) | CPU/req | linhas × CPU |
| - | - | - | - |
| Django | **289** (o menor) | 856,1 µs (o maior) | 247.413 |
| FastAPI | 318 | 511,8 µs | 162.752 |
| Elixir | 442 | 444,4 µs | 196.425 |
| Go | **688** (o maior) | **323,0 µs** (o menor) | 222.224 |

**A correlação existe nas pontas e some no meio.** Django escreve 2,4x menos
código e paga 2,65x mais CPU; o Go faz o contrário. Mas FastAPI e Elixir
desmentem a régua: o FastAPI escreve **menos** que o Elixir *e* é quase tão
rápido (15% de diferença), e a coluna "linhas × CPU" — que seria constante se a
troca fosse justa — varia 52% entre a melhor e a pior.

Três razões para não levar a correlação a sério:

**1. O Django não é pequeno por ser Python, é pequeno por ser Django.** As 200
linhas de aplicação escondem o ORM, o roteador, a validação e o `manage.py` — que
existem, custam CPU e foram escritos por outra pessoa. A comparação honesta é
FastAPI (318) contra Elixir (442) contra Go (688): três stacks que escrevem o
próprio caminho quente. E aí o Django sai da tabela por não ser comparável, não
por ser ruim.

**2. As 688 linhas do Go não são complexidade, são cerimônia.** **156 delas —
23% — são blocos `if erro != nil { ... }`.** Descontá-las põe o Go em ~530, entre
Elixir e o dobro do FastAPI. O programador não pensou mais; digitou mais.

**3. O que custa CPU não é o que custa linha.** O caso mais claro está no próprio
Go: `marshalExtratoManual` são ~40 linhas escritas para ser rápido, e medem
**1,4% de diferença** contra o `encoding/json`
([`02`, §5.2](./02-tirando-proveito-da-stack.md)). Quarenta linhas de esforço, zero
de ganho. E no sentido inverso, o ganho de 4,00x que o FastAPI teve na leitura
sobre o Django veio em boa parte de **remover** o ORM — isto é, de escrever menos
abstração, não mais código.

### 5.2 A resposta

**Não é a linguagem que ajuda o programador que custa desempenho — é a
abstração que ele não escreveu.** O eixo que separa 862 µs de 303 µs neste
projeto não é Python contra Go: é quanto trabalho por requisição a stack faz sem
que ninguém tenha pedido. O Django com ORM instancia 11 objetos por extrato; o
Django com SQL cru na escrita já custa o mesmo tipo de trabalho que os outros.

E o corolário incômodo, que este repositório mediu quatro vezes: **nada disso
mudou a nota**. As quatro stacks marcam USD 100.000. A linguagem que ajuda o
programador entrega o mesmo resultado com 2,4x menos código escrito — e, no
regime desta competição, "ajudar o programador" é a única variável que sobrou
com valor prático.

---

## 6. Conclusões

1. **O Go é a stack mais barata das quatro** — 2,65x sobre o Django e 1,38x
   sobre o Elixir na escrita; 11,64x e 1,50x na leitura.
2. **É também a primeira em que a aplicação sai da frente**, nos dois endpoints:
   o Postgres vira a parede, com a API a 0,9% de saturação na leitura.
3. **A prova oficial não distingue nenhuma das quatro.** p98 de 4 a 7ms contra
   um SLA de 250ms, pontuação máxima em todas.
4. **Custou 2,4x mais código que o Django e 1,6x mais que o Elixir**, e um quarto
   disso é tratamento de erro.
5. **A correlação "mais ajuda, menos desempenho" só aparece nas pontas** e não
   sobrevive ao meio da tabela.

---

## 7. Ações decorrentes

- [ ] O comparativo **sem restrição de cota** — [`04`](./04-sem-cota.md), que é
      onde as diferenças de runtime deixam de ser mascaradas pelo cgroup.
- [x] Re-executar as oito séries no mesmo commit — feito, `2b408eb`, com cgroup
      do banco em todas.
- [ ] Investigar a amplitude de 31,4% da leitura do Go. A causa provável é o
      banco saturado ([`01`, §5.2](./01-a-aplicacao-sai-da-frente.md)), mas com
      o banco em 2 CPU ela caiu para 9,1% — e nunca foi medida três vezes
      seguidas para separar mecanismo de dispersão.
