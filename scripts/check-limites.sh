#!/usr/bin/env bash
# Valida as restrições de CPU e memória da Rinha.
#
# Lê o compose já resolvido (`config`), e não o YAML cru: assim overrides,
# âncoras YAML e variáveis de ambiente entram na conta — é o que o avaliador
# efetivamente sobe.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker compose "$@" config --format json | python3 "$RAIZ/scripts/check-limites.py"
