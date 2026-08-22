-- GERADO por scripts/gerar-sql.sh — não edite à mão.
-- Fonte da verdade: django/crebitos/fixtures/clientes.json
-- Regenere com: just gen-sql

--
-- PostgreSQL database dump
--

\restrict chvvrOXqvtiZI1kVTLtfekdTjVVIbObYKTn2LjDZJ3i9oSGUHhLpvjBdfifN1Wy

-- Dumped from database version 18.6
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: crebitos_cliente; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.crebitos_cliente (id, limite, saldo) FROM stdin;
2	80000	0
3	1000000	0
4	10000000	0
5	500000	0
1	100000	100
\.


--
-- Name: crebitos_cliente_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.crebitos_cliente_id_seq', 5, true);


--
-- PostgreSQL database dump complete
--

\unrestrict chvvrOXqvtiZI1kVTLtfekdTjVVIbObYKTn2LjDZJ3i9oSGUHhLpvjBdfifN1Wy

