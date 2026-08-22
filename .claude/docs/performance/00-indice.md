# Testes de performance — índice

Cada experimento tem arquivo próprio. A convenção de escrita está descrita em
`.claude/memory/documentacao-testes-performance.md`.

| # | Experimento | Data | Estado |
| - | - | - | - |
| [01](./01-debug-vs-producao.md) | Custo do `DEBUG=True` e de `runserver` vs. Gunicorn (SQLite) | 2026-08-21 | **concluído** |
| [02](./02-container-e-cgroup.md) | Container + cgroup (SQLite): workers sob cota, throttling | 2026-08-21 | **parcial** |
| 03 | Worker e protocolo: `sync` vs. `gthread` vs. ASGI/uvicorn | — | **próximo** |
| 04 | Adição do Postgres | — | planejado |
| 05 | Adição do nginx e da 2ª instância | — | planejado |

## Regras de ouro destes documentos

0. **A numeração é cronológica.** Os números contam a ordem em que os
   experimentos foram feitos, e são renumerados quando a ordem muda.
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
