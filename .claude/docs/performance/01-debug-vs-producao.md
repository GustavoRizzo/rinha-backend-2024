# 01 — Custo do `DEBUG=True` e de `runserver` vs. Gunicorn

**Data**: 2026-08-21 · **Commit**: `cbec18a` (árvore limpa)
**Ferramenta**: `oha` 1.15.0 · **Banco**: SQLite · **Sem Docker**

---

## 1. Ressalvas metodológicas — leia antes dos números

**Estas ressalvas vêm antes dos resultados de propósito.** Daqui a alguns meses
a tabela continua legível e o contexto some.

**1. Este teste não prevê nada sobre a Rinha.** Roda em SQLite, sem Docker, sem
limite de cgroup, sem load balancer, com uma instância só. Os números absolutos
não têm relação com o que vai acontecer sob 1.5 CPU e 550MB.

**2. Só o `GET /clientes/1/extrato` foi medido.** Escolhido por ser **somente
leitura**: o SQLite serializa escritas num único writer global, então qualquer
número de `POST /transacoes` mediria o SQLite, não o Django. O extrato, sendo
leitura concorrente, isola razoavelmente o custo do framework.

**3. O gerador de carga disputa a mesma máquina que o servidor.** São 20 vCPUs e
o `oha` roda com `--no-tui`, mas a contaminação existe. Ela afeta todas as
configurações igualmente, então a **comparação relativa** se sustenta; o valor
absoluto, menos.

**4. Modelo fechado (saturação), não aberto.** `oha -c 50` sem `-q`: 50 conexões
que esperam resposta antes de pedir de novo. Responde "quanto aguenta", não
"qual a latência sob 340 req/s". **Os p99 aqui não são comparáveis com o SLA de
250ms da Rinha** — sob saturação a fila é o resultado, não um defeito. Taxa fixa
fica para o experimento 02.

**5. A resolução deste setup é de ~3%.** A amplitude relativa entre repetições
fica em 0,7–3,3%. Diferenças menores que isso **não são atribuíveis** e não devem
ser reportadas como efeito. Foi por isso que o efeito do DEBUG precisou de 5
repetições para ser afirmado com segurança — com 3 ele ficava na fronteira.

**6. Nada disto vale contra números do Gatling.** Ferramentas diferentes nunca se
comparam — ver a regra derivada em `04-aprendizados.md`.

---

## 2. Metodologia

Cinco configurações, mudando **uma variável por vez**:

| Config | Servidor | `DJANGO_DEBUG` | Workers | Isola |
| - | - | - | - | - |
| `runserver-debug` | `manage.py runserver` | 1 | thread por conexão | o dia a dia real |
| `runserver-prod` | `manage.py runserver` | 0 | thread por conexão | efeito do DEBUG no runserver |
| `gunicorn-1w-debug` | Gunicorn sync | 1 | 1 | efeito do DEBUG sem o runserver mascarar |
| `gunicorn-1w` | Gunicorn sync | 0 | 1 | efeito do servidor, sem paralelismo |
| `gunicorn-4w` | Gunicorn sync | 0 | 4 | efeito do paralelismo |

Cada série: **uma rodada de aquecimento descartada + 3 repetições de 10s**
(5 de 15s para o par que isola o DEBUG), concorrência 50. Antes de cada rodada o
banco é recriado do zero (`migrate` → `loaddata clientes` → `preparar_bench`, que
planta 50 transações por cliente para o extrato ter as 10 do contrato e algo a
descartar no `ORDER BY`).

Uma bateria extra com **concorrência 1**, para separar custo por requisição de
contenção sob carga.

### Duas armadilhas descobertas medindo

**O aquecimento não é ritual.** A primeira execução de `gunicorn-1w` deu 757 rps;
as seguintes, 833–877. Sem descartá-la, o efeito do DEBUG (~4%) ficava soterrado
— a ponto de a primeira medição sugerir que `DEBUG=True` era *mais rápido*.

**O commit precisa ser anterior à medição.** A primeira versão deste documento
registrou um hash que **não continha** o interruptor `DJANGO_DEBUG` — quem
fizesse checkout dele não conseguiria sequer rodar o experimento. Agora
`bench-local.sh` **aborta** com a árvore suja (`BENCH_PERMITIR_SUJO=1` para
exploração deliberada). Proveniência falsa é pior que proveniência nenhuma.

---

## 3. Comandos para replicar

```bash
cargo install oha            # 1.15.0
git status --porcelain       # precisa estar vazio, senão o bench aborta
just bench-01                # reproduz o experimento inteiro (~5 min)
just bench-tabela            # imprime a tabela a partir dos JSON arquivados
```

Peças individuais:

```bash
just bench-serie gunicorn-1w extrato 15s 5      # série de uma configuração
BENCH_CONCORRENCIA=1 just bench-1 runserver-prod extrato 10s
just bench-mem gunicorn-1w-debug extrato 30     # crescimento de RSS
```

Resultados crus, com metadados e commit: `resultados/bench/*.serie.json`.

---

## 4. Resultados

### Saturação (concorrência 50)

```
config              endpoint          rps  ampl%   p50ms    p99ms  vs base
--------------------------------------------------------------------------
runserver-debug     extrato         200.4    1.8   247.9   1407.2     1.0x
runserver-prod      extrato         222.9    1.4   221.5   1368.4     1.1x
gunicorn-1w-debug   extrato         839.9    8.1    58.4     65.6     4.2x
gunicorn-1w         extrato         875.9    1.4    57.0     62.6     4.4x
gunicorn-4w         extrato        3239.1    2.6    15.2     19.1    16.2x
```

`rps` é a **mediana**; `ampl%` é a amplitude relativa `(max-min)/mediana`.

### Concorrência 1 — o dado que explica tudo

```
c=1   runserver-prod    rps=646.3   p50=1.49ms
c=1   gunicorn-1w       rps=887.2   p50=1.08ms
```

### Efeitos isolados

| Comparação | Efeito |
| - | - |
| `DEBUG=True` sob Gunicorn (n=5) | **−4,1%** — separação limpa, sem sobreposição |
| `DEBUG=True` sob `runserver` | −10,1% |
| Gunicorn vs. `runserver`, **c=1** | 1,37x |
| Gunicorn vs. `runserver`, **c=50** | 3,9x |
| Gunicorn 4 workers vs. 1 worker | 3,7x |

### Memória sob carga (30s)

```
gunicorn-1w      : RSS inicial=27.2MB final=27.2MB crescimento=+0.0MB
gunicorn-1w-debug: RSS inicial=27.2MB final=27.2MB crescimento=+0.0MB
```

---

## 5. Conclusões

### O `DEBUG=True` custa −4,1%, não "10x"

O mecanismo é estreito: o Django troca o cursor por `CursorDebugWrapper`, que
cronometra e registra cada query. O custo é **por query**, e este endpoint faz
apenas duas — num endpoint com 50 queries o percentual seria muito maior.

O efeito é pequeno o bastante para exigir disciplina estatística: com 3
repetições ele ficava na fronteira do ruído (−2,7%, amplitude 3,3%). Só com 5
repetições apareceu separação limpa — o **mínimo** das rodadas de produção
(872,6 rps) ficou acima do **máximo** das rodadas com DEBUG (852,0 rps).

### O vazamento de memória do DEBUG **não existe** sob WSGI

Correção mais valiosa do experimento — eu havia afirmado o contrário, com
confiança, em dois lugares do código, antes de medir.

A crença comum é que `connection.queries` cresce sem limite com `DEBUG=True`. Sob
um servidor WSGI, **não cresce**: o Django liga `reset_queries` ao sinal
`request_started` (`django/db/__init__.py:52`), então a lista zera no início de
cada request. RSS estável nos dois modos, ao longo de 30s de carga.

O vazamento é real, mas **só fora do ciclo de request** — management commands,
workers de fila, scripts longos, qualquer laço que nunca dispare
`request_started`. É lá que ele morde.

### O `runserver` não é lento: ele tem escalabilidade negativa

Este é o achado principal, e derruba a primeira explicação que eu tinha dado
(que ele não faria keep-alive — falso: `basehttp.py:179` define
`protocol_version = "HTTP/1.1"`).

Decompondo os 3,9x com o dado de concorrência 1:

**~1,37x é custo por requisição.** Parsing de HTTP em Python puro via
`http.server`, mais um detalhe que pesa: o `runserver` **loga toda requisição**
pelo logger `django.server` (`basehttp.py:185`) — I/O síncrono a cada request. O
Gunicorn tem `accesslog` desligado por padrão.

**O resto é contenção.** Repare que o `runserver` **piora com carga**: 646 rps
com uma conexão, 222,9 rps com 50. Perde 65% do próprio desempenho. O Gunicorn vai
de 887 para 875,9 — praticamente plano.

A causa está em `basehttp.py:87`: `ThreadedWSGIServer(socketserver.ThreadingMixIn, ...)`
— **uma thread por conexão, sem pool**. Com 50 conexões são 50 threads Python
disputando o GIL, trocando de contexto sem que nenhuma progrida. Daí o p99 de
1368ms contra 62,6ms.

O worker sync do Gunicorn faz o oposto: um processo, uma thread, um request por
vez, em laço. Zero contenção. **Ele ganha fazendo menos** — a mesma lição
contraintuitiva do doc 01, seção 3.

**Consequência prática: nunca medir nada sob `runserver`.** Ele mascarou
completamente o efeito do DEBUG na primeira tentativa deste próprio experimento.

### O 3,7x de 4 workers **não** autoriza 4 workers no compose

Sem surpresa **neste contexto**: 20 vCPUs ociosos, carga de leitura, SQLite sem
contenção de escrita. Sob o cgroup da Rinha a lógica se inverte, por três motivos:

**O container não sabe que tem 1.5 CPU.** O cgroup limita a *cota*, não a
visibilidade — `os.cpu_count()` continua devolvendo 20 lá dentro. Deixar o
Gunicorn autoconfigurar (`2 × cpu + 1`) subiria **41 workers**.

**Throttling é penhasco, não ladeira.** Com ~0,45 CPU por API, são 45ms de cota
por janela de 100ms. Quatro workers ocupados queimam isso em ~11ms e o cgroup
**congela por 89ms** — todas as threads, de uma vez. Um worker espalha o consumo
pela janela e pode nunca ser throttlado.

**Memória, com número medido aqui:** 27,2MB de RSS por worker. São 2 APIs, num
orçamento de 550MB **somando tudo**, do qual o Postgres quer 150–200MB. Sobram
~165MB por API — teto em ~6 workers só por memória, antes do throttling entrar
na conta. Estourar não deixa lento: o OOM killer mata o processo.

**Mas 1 worker também não é a resposta**: enquanto ele espera o round-trip do
banco, o processo está ocioso e a cota não usada **evapora** (não acumula). O
ótimo é pequeno e maior que 1 — e **tem que ser medido sob o cgroup**.

---

## 6. Ações decorrentes

- [x] `DEBUG` vem de `DJANGO_DEBUG` (`kernel/settings.py`), com o custo medido
      anotado no comentário e no `.env.example`.
- [x] Corrigidas as duas afirmações erradas sobre vazamento de memória sob WSGI.
- [x] Gunicorn adicionado como dependência.
- [x] `bench-local.sh` aborta com a árvore suja.
- [x] Receitas `just bench-*` para replicar.
- [ ] Escolher o número de workers **medindo sob cgroup**, não a partir daqui.
- [ ] Experimento 02: **taxa fixa** (modelo aberto) para falar de latência de
      forma comparável ao SLA. Usar `oha --latency-correction` — sem ela, os
      números saem otimistas por coordinated omission.
- [ ] Experimento 03: `POST /transacoes` — exige Postgres para ter sentido.
- [ ] Experimento 04: servidores alternativos (Granian, uWSGI, gthread) medidos
      por **CPU por request sob cota**, não por rps em máquina livre.

---

## 7. Aprendizados transversais

Registrados em `04-aprendizados.md` por valerem além deste experimento:

- A primeira execução de qualquer configuração é lixo. Aquecimento descartado
  não é opcional.
- Sem repetições e amplitude relativa, não há como distinguir efeito de ruído —
  e um efeito de 4% é invisível numa medição única.
- Medir sob o servidor de desenvolvimento não mede o seu código; mede o servidor
  de desenvolvimento.
- Benchmark com árvore suja grava proveniência falsa. O script deve recusar.
