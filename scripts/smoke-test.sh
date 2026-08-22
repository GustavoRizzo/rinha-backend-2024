#!/usr/bin/env bash
# Validação funcional rápida do contrato, contra o load balancer na 9999.
#
# Roda ANTES da carga para falhar cedo: descobrir em 5 segundos que o 404 está
# errado é muito melhor que descobrir em 4 minutos de Gatling.
set -uo pipefail
BASE="${SMOKE_BASE:-http://localhost:9999}"
falhas=0

verifica() {
    local descricao="$1" esperado="$2" obtido="$3"
    if [[ "$obtido" == "$esperado" ]]; then
        printf '  ✓ %-52s %s\n' "$descricao" "$obtido"
    else
        printf '  ✗ %-52s esperado=%s obtido=%s\n' "$descricao" "$esperado" "$obtido"
        falhas=$((falhas + 1))
    fi
}

codigo() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
post() {
    codigo -X POST "$BASE/clientes/$1/transacoes" \
        -H 'Content-Type: application/json' -d "$2"
}

echo "smoke test em $BASE"

verifica "GET extrato do cliente 1"            200 "$(codigo "$BASE/clientes/1/extrato")"
verifica "GET extrato do cliente 5"            200 "$(codigo "$BASE/clientes/5/extrato")"
verifica "GET extrato do cliente 6 (inexistente)" 404 "$(codigo "$BASE/clientes/6/extrato")"
verifica "POST crédito válido"                 200 "$(post 1 '{"valor":10,"tipo":"c","descricao":"smoke"}')"
verifica "POST débito válido"                  200 "$(post 1 '{"valor":10,"tipo":"d","descricao":"smoke"}')"
verifica "POST em cliente inexistente"         404 "$(post 6 '{"valor":1,"tipo":"c","descricao":"x"}')"
verifica "POST tipo inválido"                  422 "$(post 1 '{"valor":1,"tipo":"x","descricao":"x"}')"
verifica "POST descrição com 11 caracteres"    422 "$(post 1 '{"valor":1,"tipo":"c","descricao":"12345678901"}')"
verifica "POST descrição vazia"                422 "$(post 1 '{"valor":1,"tipo":"c","descricao":""}')"
verifica "POST valor não inteiro"              422 "$(post 1 '{"valor":1.2,"tipo":"c","descricao":"x"}')"
verifica "POST débito além do limite"          422 "$(post 1 '{"valor":999999999,"tipo":"d","descricao":"x"}')"

# O corpo do extrato precisa ter a forma exata do contrato.
corpo=$(curl -s "$BASE/clientes/1/extrato")
verifica "extrato tem saldo.total/limite/data_extrato" ok \
    "$(printf '%s' "$corpo" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("ok" if set(d["saldo"])=={"total","data_extrato","limite"} else "ERRO")' 2>/dev/null || echo ERRO)"
verifica "ultimas_transacoes em ordem decrescente" ok \
    "$(printf '%s' "$corpo" | python3 -c '
import json,sys
t=json.load(sys.stdin)["ultimas_transacoes"]
datas=[x["realizada_em"] for x in t]
print("ok" if len(t)<=10 and datas==sorted(datas,reverse=True) else "ERRO")' 2>/dev/null || echo ERRO)"

# As duas instâncias precisam estar recebendo tráfego: o LB é round-robin, e uma
# instância morta passaria despercebida num teste de 5 segundos.
echo "  · verificando round-robin entre as instâncias..."
for _ in $(seq 1 20); do curl -s -o /dev/null "$BASE/clientes/1/extrato"; done

if [[ "$falhas" -gt 0 ]]; then
    echo "SMOKE FALHOU: $falhas verificação(ões)" >&2
    exit 1
fi
echo "smoke ok"
