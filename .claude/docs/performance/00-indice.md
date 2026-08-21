# Testes de performance — índice

Cada experimento tem arquivo próprio. A convenção de escrita está descrita em
`.claude/memory/documentacao-testes-performance.md`.

| # | Experimento | Data | Estado |
| - | - | - | - |
| [01](./01-debug-vs-producao.md) | Custo do `DEBUG=True` e de `runserver` vs. Gunicorn (SQLite) | 2026-08-21 | **concluído** |
| 02 | Latência sob taxa fixa (modelo aberto) | — | planejado |
| 03 | `POST /transacoes` — exige Postgres | — | planejado |
| 04 | Servidores alternativos (Granian, uWSGI, gthread) sob cota de CPU | — | planejado |

## Regras de ouro destes documentos

1. **Ressalvas antes dos números.** Todo arquivo abre dizendo o que o teste
   *não* mede.
2. **Commit registrado.** Sem o hash, o número não é replicável.
3. **Uma variável por vez.** Se A e B diferem em duas coisas, a diferença não é
   atribuível.
4. **Comando no `justfile`.** Se não dá para re-rodar com um comando, não está
   documentado.
5. **Árvore limpa.** `bench-local.sh` aborta com mudanças não commitadas —
   um hash que não descreve o código medido é pior que hash nenhum.
6. **Nunca comparar números entre ferramentas ou versões diferentes** de
   gerador de carga. Ver a regra derivada em `04-aprendizados.md`.
