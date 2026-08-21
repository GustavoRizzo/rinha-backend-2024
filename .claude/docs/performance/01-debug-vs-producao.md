# 01 — Custo do `DEBUG=True` e de `runserver` vs. Gunicorn

**Data**: 2026-08-21 · **Commit**: `b61f4c7` (árvore suja — ver ressalva 5)
**Ferramenta**: `oha` 1.15.0 · **Banco**: SQLite · **Sem Docker**

---

## 1. Ressalvas metodológicas — leia antes dos números

**Estas ressalvas vêm antes dos resultados de propósito.** Daqui a alguns meses
a tabela continua legível e o contexto não.

**1. Este teste não prevê nada sobre a Rinha.** Roda em SQLite, sem Docker, sem
limite de cgroup, sem load balancer, com uma única instância. Os números
absolutos não têm relação com o que vai acontecer sob 1.5 CPU e 550MB.

**2. Só o `GET /clientes/1/extrato` foi medido.** Escolhido justamente porque é
**somente leitura**: o SQLite serializa escritas num único writer global, então
qualquer número de `POST /transacoes` mediria o SQLite, não o Django. O extrato,
sendo leitura concorrente, isola razoavelmente o custo do framework.

**3. O gerador de carga disputa a mesma máquina que o servidor.** São 20 vCPUs e
o `oha` roda com `--no-tui`, mas a contaminação existe. Ela afeta todas as
configurações igualmente, então a **comparação relativa** se sustenta; o valor
absoluto, menos.

**4. Modelo fechado (saturação), não aberto.** `oha -c 50` sem `-q`: 50 conexões
que esperam resposta antes de pedir de novo. Isso responde "quanto aguenta", não
"qual a latência sob 340 req/s". Os p99 aqui **não** são comparáveis com o SLA de
250ms da Rinha — sob saturação, a fila é o resultado, não um defeito. O regime de
taxa fixa fica para um experimento próprio.

**5. A árvore de trabalho estava suja** durante a coleta. O commit registrado é o
último, mas havia mudanças não commitadas. Para réplicas futuras, commitar antes
de rodar; o script já grava `git_sujo` para não deixar isso passar em silêncio.

**6. Nada disto vale contra números do Gatling.** Ferramentas diferentes nunca se
comparam — ver a regra derivada em `04-aprendizados.md`.

---

## 2. Metodologia

Cinco configurações, mudando **uma variável por vez**:

| Config | Servidor | `DJANGO_DEBUG` | Workers | Isola |
| - | - | - | - | - |
| `runserver-debug` | `manage.py runserver` | 1 | 1 (threaded) | o dia a dia real |
| `runserver-prod` | `manage.py runserver` | 0 | 1 (threaded) | efeito do DEBUG no runserver |
| `gunicorn-1w-debug` | Gunicorn sync | 1 | 1 | efeito do DEBUG sem o runserver mascarar |
| `gunicorn-1w` | Gunicorn sync | 0 | 1 | efeito do servidor, sem paralelismo |
| `gunicorn-4w` | Gunicorn sync | 0 | 4 | efeito do paralelismo |

Cada série: **uma rodada de aquecimento descartada + 3 repetições de 10s**,
concorrência 50. Antes de cada rodada, o banco é recriado do zero
(`migrate` → `loaddata clientes` → `preparar_bench`, que planta 50 transações por
cliente para o extrato ter as 10 do contrato e algo a descartar no `ORDER BY`).

O aquecimento não é ritual: **descobri o problema medindo.** A primeira execução
de `gunicorn-1w` deu 757 rps; as seguintes, 833–855. Sem descartá-la, o efeito do
`DEBUG` (que é de ~4%) ficava inteiramente soterrado — a ponto de a primeira
medição sugerir que `DEBUG=True` era *mais rápido*.

---

## 3. Comandos para replicar

```bash
cargo install oha            # 1.15.0
just bench-01                # reproduz o experimento inteiro (~5 min)
just bench-tabela            # imprime a tabela a partir dos JSON arquivados
```

Peças individuais:

```bash
just bench-serie gunicorn-1w extrato 10s 3   # série de uma configuração
just bench-1 runserver-debug extrato 10s     # rodada única
just bench-mem gunicorn-1w-debug extrato 30  # crescimento de RSS
```

Resultados crus, com metadados e commit: `resultados/bench/*.serie.json`.

---

## 4. Resultados

```
config              endpoint          rps  ampl%   p50ms    p99ms  vs base
--------------------------------------------------------------------------
runserver-debug     extrato         195.4    2.8   252.6   1420.9     1.0x
runserver-prod      extrato         215.2    0.7   229.2   1357.0     1.1x
gunicorn-1w-debug   extrato         824.5    1.1    60.4     79.0     4.2x
gunicorn-1w         extrato         863.4    1.0    57.8     62.3     4.4x
gunicorn-4w         extrato        3151.6    0.6    15.7     19.3    16.1x
```

`rps` é a **mediana** de 3 repetições; `ampl%` é a amplitude relativa
(`(max-min)/mediana`). **Toda diferença menor que ~3% deve ser tratada como
ruído.**

### Efeitos isolados

| Comparação | Efeito |
| - | - |
| `DEBUG=True` sob Gunicorn | **−4,5%** de vazão |
| `DEBUG=True` sob `runserver` | −9,2% de vazão |
| Gunicorn 1 worker vs. `runserver` | **4,0x** mais vazão |
| Gunicorn 4 workers vs. 1 worker | 3,7x (de 4 workers — escala quase linear) |

### Memória sob carga (30s, `just bench-mem`)

```
gunicorn-1w      : RSS inicial=27.2MB final=27.2MB crescimento=+0.0MB
gunicorn-1w-debug: RSS inicial=26.9MB final=26.9MB crescimento=+0.0MB
```

---

## 5. Conclusões

### O `DEBUG=True` custa muito menos do que a fama sugere

**−4,5%** de vazão sob Gunicorn. Não é o "10x mais lento" do folclore. O
mecanismo real é estreito: o Django troca o cursor por `CursorDebugWrapper`, que
cronometra e registra cada query. O custo é **por query**, e este endpoint faz
apenas duas — num endpoint com 50 queries o percentual seria bem maior.

Sob `runserver` o efeito medido dobra (−9,2%), mas isso é artefato: a base é tão
lenta que qualquer custo fixo pesa proporcionalmente mais.

### O vazamento de memória do DEBUG **não existe** sob WSGI

Esta foi a correção mais valiosa do experimento — eu havia afirmado o contrário,
com confiança, antes de medir.

A crença comum é que `connection.queries` cresce sem limite com `DEBUG=True`.
Sob um servidor WSGI, **não cresce**: o Django liga `reset_queries` ao sinal
`request_started` (`django/db/__init__.py:52`), então a lista zera no início de
cada request. O RSS ficou estável nos dois modos, ao longo de 30s de carga.

O vazamento é real, mas **só fora do ciclo de request** — management commands,
workers de fila, scripts de longa duração, qualquer laço que nunca dispare
`request_started`. É lá que ele morde.

### `runserver` é o gargalo, e por uma razão específica

4x mais lento que Gunicorn com **um único worker** — ou seja, não é paralelismo.
O `runserver` não é um servidor lento "em geral": ele é um servidor de
desenvolvimento que não faz keep-alive de forma útil, e a p99 de **1357ms** (vs.
62ms do Gunicorn) mostra o comportamento de fila que isso produz.

Consequência prática imediata: **nunca medir nada sob `runserver`**. Ele mascarou
completamente o efeito do DEBUG na primeira tentativa deste próprio experimento.

### Gunicorn escala quase linearmente aqui

4 workers deram 3,7x. Sem surpresa **neste contexto** — 20 vCPUs ociosos, carga
de leitura, SQLite sem contenção de escrita. Sob o cgroup de 1.5 CPU da Rinha a
história muda completamente, e o doc 01 (seção 3) explica por quê: mais threads
sob cota queimam a cota mais rápido e provocam throttling. **Este número não
autoriza escolher 4 workers no compose.**

---

## 6. Ações decorrentes

- [x] `DEBUG` passa a vir de `DJANGO_DEBUG` (`kernel/settings.py`), com o custo
      medido anotado no comentário.
- [x] Corrigido o comentário do `settings.py` que afirmava o vazamento de
      memória sob WSGI.
- [x] Gunicorn adicionado como dependência.
- [x] Receitas `just bench-*` para replicar.
- [ ] Escolher o número de workers **medindo sob cgroup**, não a partir daqui.
- [ ] Experimento 02: regime de **taxa fixa** (modelo aberto) para falar de
      latência de forma comparável ao SLA de 250ms.
- [ ] Experimento 03: `POST /transacoes` — exige Postgres para ter sentido.

---

## 7. Aprendizados transversais

Registrados em `04-aprendizados.md` por valerem além deste experimento:

- A primeira execução de qualquer configuração é lixo. Aquecimento descartado
  não é opcional.
- Sem repetições e amplitude relativa, não há como distinguir efeito de ruído —
  e um efeito de 4% é invisível numa medição única.
- Medir sob o servidor de desenvolvimento não mede o seu código; mede o servidor
  de desenvolvimento.
