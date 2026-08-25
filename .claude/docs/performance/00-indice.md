# Testes de performance — índice

Um diretório por **projeto** (pasta de framework), porque a numeração dos
experimentos é cronológica **dentro de cada projeto** — o experimento 01 do
FastAPI não é continuação do 06 do Django, é o primeiro de outra linha.

| Projeto | Experimentos | Estado |
| - | - | - |
| [django/](./django/00-indice.md) | 01 a 06 | **concluídos** — USD 100.000, zero inconsistências |
| [fastapi/](./fastapi/00-indice.md) | 01 a 03 | **concluídos** — 1,73x na escrita, 4,00x na leitura |
| [elixir/](./elixir/00-indice.md) | 01 a 04 | **em andamento** — o **mais barato dos três** depois que o 04 derrubou um erro meu |

A convenção de escrita está descrita em
`.claude/memory/documentacao-testes-performance.md`.

## Regras de ouro destes documentos

0. **A numeração é cronológica, e reinicia por projeto.** Os números contam a
   ordem em que os experimentos foram feitos, e são renumerados quando a ordem
   muda. Ao citar um experimento de outro projeto, cite o caminho completo
   (`django/06`), nunca só o número.
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
7. **Comparação entre projetos exige a mesma bancada.** `oha` do FastAPI só
   vale contra `oha` do Django se o rig, a cota de CPU, o endpoint e a duração
   forem os mesmos. A métrica de comparação é **CPU por requisição**, não rps.
