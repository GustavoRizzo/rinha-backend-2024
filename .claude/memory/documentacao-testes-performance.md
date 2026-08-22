---
name: documentacao-testes-performance
description: Convenção de como documentar cada teste de performance/comparativo deste projeto
metadata:
  type: project
---

Cada experimento de performance ganha **um arquivo próprio e detalhado** em
`.claude/docs/performance/`, nunca uma seção dentro de um documento maior. O
índice fica em `.claude/docs/performance/00-indice.md`.

Nomenclatura: `NN-assunto-curto.md`. A numeração reflete a **ordem cronológica**
em que os experimentos foram feitos e **pode ser renumerada** quando a ordem
mudar — o usuário prefere que os números contem a história da evolução do
projeto, em vez de servirem como identificador estável.

Todo arquivo de experimento tem, **nesta ordem**:

1. **Ressalvas metodológicas primeiro**, antes de qualquer número. O que este
   teste mede de verdade e o que ele *não* mede. Vem antes dos resultados de
   propósito: daqui a meses o gráfico continua lá, o contexto some.
2. **Ambiente**: hardware, versões de tudo, e o **hash do commit** em que o
   teste foi rodado. Sem o commit, o resultado não é replicável — o código muda.
3. **Comandos exatos** usados, copiáveis. Toda execução também vira receita no
   `justfile` (grupo `bench`), para poder ser re-rodada quando mudar hardware ou
   versão de biblioteca.
4. **Resultados** com números crus, não só conclusões.
5. **Conclusões e ações** decorrentes.

**Por que**: os testes são muitos e cada um tem armadilhas próprias. Um documento
único vira ilegível, e conclusão sem metodologia registrada é como as pessoas
acabam citando o próprio número errado meses depois.

**Como aplicar**: ao terminar qualquer comparativo, criar o arquivo em
`performance/`, adicionar a linha no índice, e garantir que as receitas do
`justfile` reproduzem exatamente o que está escrito. Aprendizados transversais
(que valem além daquele experimento) vão para [[aprendizados-vao-para-doc-04]].
