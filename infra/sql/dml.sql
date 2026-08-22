-- GERADO por scripts/gerar-dml.py — não edite à mão.
-- Fonte da verdade: django/crebitos/fixtures/clientes.json
-- Regenere com: just gen-sql

INSERT INTO public.crebitos_cliente (id, limite, saldo) VALUES
    (1, 100000, 0),
    (2, 80000, 0),
    (3, 1000000, 0),
    (4, 10000000, 0),
    (5, 500000, 0);

-- A sequence precisa continuar de onde os IDs explícitos pararam.
SELECT setval('public.crebitos_cliente_id_seq', (SELECT MAX(id) FROM public.crebitos_cliente));
