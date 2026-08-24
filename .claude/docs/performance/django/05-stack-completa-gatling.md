# 05 — A stack completa e a prova oficial com Gatling

**Data**: 2026-08-21 · **Gatling**: 3.15.1 · **6 execuções**
**Relatórios HTML versionados**: `resultados/django/<timestamp>/index.html`

Quinto degrau, e o primeiro que testa **corretude**, não só desempenho: a
simulação oficial verifica consistência de saldo no meio da carga.

Arquitetura final: nginx (round-robin) + 2 APIs Django/Gunicorn + Postgres,
somando **1.50 CPU e 550MB** — o orçamento inteiro da competição.

---

## 1. Ressalvas metodológicas — leia antes dos números

**1. Máquina local com 20 vCPUs; a oficial tinha 4 (2 físicos com
hyper-threading).** Os limites de cgroup se aplicam igual, mas lá o Gatling
disputava CPU com a aplicação. **Estes números não se comparam com o ranking
oficial** — só entre si.

**2. Docker Desktop sobre WSL2**, com containers numa VM e proxy de porta.

**3. Gatling 3.15.1, não a 3.10.3 da competição.** Ver a regra em
`04-aprendizados.md`: números de versões diferentes não se comparam.

**4. `synchronous_commit = off` no Postgres.** Decisão de durabilidade
deliberada e documentada em `infra/postgres/postgresql.conf`. Legítima num
exercício de 4 minutos; inaceitável num sistema real de pagamentos.

**5. Seis execuções, três por configuração.** Suficiente para distinguir o
efeito do rebalanceamento do ruído, insuficiente para um intervalo de confiança.

---

## 2. Metodologia

`scripts/rodar-carga.sh` executa, em ordem:

1. `down -v` — **recria o volume do banco**. Estado residual faz a verificação
   de consistência acusar inconsistência que não existe.
2. `up -d --build`, aguardando prontidão em janelas de 2s por até 40s (o mesmo
   critério da competição).
3. `smoke-test.sh` — 13 verificações do contrato. Falhar aqui em 5 segundos é
   muito melhor que descobrir em 4 minutos de Gatling.
4. `down -v` / `up -d` de novo — o smoke test alterou saldos.
5. A simulação oficial, sem modificações.
6. Arquivamento do relatório com `metadata.json` (commit, recursos, ambiente).

**O `gatling.conf` foi ajustado** para `lowerBound = 250` e `percentile3 = 98`:
com os padrões (800ms e p95) o relatório não responde à pergunta do regulamento.

A simulação injeta 61.503 requisições em 4 minutos: rampa de 1 a 220 débitos/s
somada a 110 créditos/s e 10 extratos/s, seguida de 2 minutos em regime
constante.

---

## 3. Comandos para replicar

```bash
just check django      # confere 1.5 CPU / 550MB a partir do compose resolvido
just up django         # sobe e espera prontidão
just smoke django      # 13 verificações de contrato
just load django       # a simulação oficial (4 min)
just score django/<timestamp>
just run django        # up -> smoke -> load -> down
```

---

## 4. Resultados

```
execução            CPU/API   %<250ms   p98   max  incons   pontuação  subida
20260821T230911         0.30   98.756%   217   473       0     100,000     21s
20260821T231528         0.30   99.218%   159   367       0     100,000     20s
20260821T232058         0.30  100.000%     6    76       0     100,000     21s
20260821T232708         0.40  100.000%     7   111       0     100,000     21s
20260821T233215         0.40  100.000%     8    67       0     100,000     21s
20260821T233713         0.40  100.000%     7    89       0     100,000     18s
```

Relatórios completos, navegáveis, em
`resultados/django/<timestamp>/index.html`.

### Throttling por serviço, antes e depois do rebalanceamento

```
                 antes (api 0.30)        depois (api 0.40)
api01            73 / 2460 = 3,0%        35 / 2441 = 1,4%
api02            76 / 2469 = 3,1%        38 / 2447 = 1,6%
nginx             3 / 2397 = 0,1%        16 / 2394 = 0,7%
db                8 / 2523 = 0,3%        12 / 2469 = 0,5%
```

---

## 5. Conclusões

### Zero inconsistências em 6 execuções

**369.018 requisições, nenhuma inconsistência de saldo.** É o resultado que mais
importa, e o que a competição existe para testar.

A simulação faz coisas desagradáveis de propósito: 25 débitos concorrentes
tentando estourar o limite exato, e um POST seguido de 5 GETs paralelos exigindo
que **todos** já enxerguem a transação recém-criada.

O que sustentou isso foi a decisão tomada lá no início, antes de qualquer linha
de código: o `UPDATE ... WHERE saldo + delta >= -limite RETURNING`, que resolve
leitura, validação e escrita numa instrução só, sem janela entre ler e gravar.
`READ COMMITTED` — o padrão do Postgres — **não** impede *lost update*; a
estratégia é que impede.

### O throttling era a cauda inteira, e a cota estava no lugar errado

Na configuração original, duas execuções ficaram em 98,76% e 99,22% — acima do
limiar de 98%, mas com margem de menos de 1,3 ponto. Uma terceira deu 100%. Essa
dispersão (p98 entre 6ms e 217ms) não era ruído de medição: era **throttling
intermitente**.

Os números do cgroup mostraram exatamente onde: as APIs congelavam em **3% dos
períodos**, enquanto o nginx congelava em 0,1% e o Postgres em 0,3%. Havia cota
parada em serviços que não precisavam dela.

Movendo 0.10 CPU de cada (nginx e banco) para as APIs — **soma inalterada em
1.50** — o throttling das APIs caiu pela metade e o resultado virou:

| | p98 | max | % abaixo de 250ms |
| - | - | - | - |
| API com 0.30 CPU | 6 – 217ms | 76 – 473ms | 98,76% – 100% |
| API com 0.40 CPU | **7 – 8ms** | **67 – 111ms** | **100% nas três** |

O p98 deixou de variar 36x e passou a variar 15%. **Não ganhamos CPU: mudamos
de lugar a que já tínhamos.** Foi a otimização mais barata do projeto inteiro, e
só foi possível porque `nr_throttled` estava sendo medido — sem esse número, a
conclusão natural seria "o Django é lento na cauda".

### A margem confortável esconde onde ela veio

Com 61.503 requisições e p98 de 7ms contra um SLA de 250ms, a folga é de mais de
30x. Vale lembrar de onde ela veio, porque nenhuma dessas escolhas foi óbvia
antes de ser medida:

| Decisão | Experimento | Efeito medido |
| - | - | - |
| Conexão de banco persistente | 04 | 4,75x de vazão |
| Socket Unix entre nginx e APIs | 03 | 2,9x, e a amplitude cai de 246% para 3,9% |
| 1 worker por API | 02 e 04 | 4 workers custam 28% |
| Cota nas APIs, não no banco | 05 | p98 de 217ms para 7ms |
| `UPDATE` atômico condicional | — | zero inconsistências |

### A subida leva ~20s, com 40s de orçamento

Metade da folga. Vem quase toda do Postgres inicializando o volume; as APIs não
rodam `migrate` (o schema vem de `infra/sql/`, executado uma vez pela imagem do
banco). Sem esse cuidado, duas APIs correriam para criar as mesmas tabelas.

---

## 6. Ações decorrentes

- [x] `docker-compose.yml` definitivo: 1.50 CPU e 550MB exatos.
- [x] `check-limites.py` valida o orçamento a partir do compose **resolvido**.
- [x] `smoke-test.sh` com 13 verificações de contrato.
- [x] `pontuacao.py` aplica as duas multas do regulamento.
- [x] Cota rebalanceada com base em `nr_throttled`.
- [x] Relatórios HTML do Gatling versionados.
- [ ] Experimento 06: tipo de worker (`gthread`, ASGI/uvicorn) e async — agora
      sobre a arquitetura real.
- [ ] Revisitar `synchronous_commit` como variável medida.
- [ ] Investigar se a cauda restante (max de 67–111ms) ainda é throttling ou
      passou a ser outra coisa.

---

## 7. Aprendizados transversais

- **Distribuir a cota é tão importante quanto tê-la.** O mesmo 1.5 CPU rendeu
  p98 de 217ms ou de 7ms dependendo de onde estava.
- **`nr_throttled` por serviço é o primeiro lugar para olhar** quando a cauda
  piora. Sem ele, a explicação natural teria sido "a aplicação é lenta".
- **Variância entre execuções é sintoma, não ruído a ser mediado.** A dispersão
  de 36x no p98 era um mecanismo pedindo para ser encontrado.
- **Um teste de carga que verifica corretude vale mais que dois que só medem
  tempo.** A parte difícil da Rinha nunca foi a vazão.
