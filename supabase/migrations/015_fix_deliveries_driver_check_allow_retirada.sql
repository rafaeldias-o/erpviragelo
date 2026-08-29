-- Corrige a constraint deliveries_driver_check pra aceitar 'retirada' (cliente busca o pedido no local,
-- sem custo de entrega) — opção adicionada na tela de confirmação de entrega em algum momento posterior,
-- mas nunca refletida aqui na constraint do banco (criada fora do controle de versão, mesmo padrão do
-- fulfill_order() antes da migration 013). A constraint só aceitava 'beto' e 'gui'.
--
-- Isso fazia o INSERT na tabela deliveries falhar toda vez que alguém escolhia "🏪 Retirada no local" na
-- confirmação de entrega — erro real visto pelo usuário: 'new row for relation "deliveries" violates
-- check constraint "deliveries_driver_check"'. Como esse erro interrompia a função ANTES dela vincular a
-- conta financeira à receita (a receita já tinha sido criada pelo gatilho fulfill_order, SEM conta, no
-- momento em que o pedido virou "entregue"), a receita ficava presa como "Pago sem conta" na Conciliação
-- pra sempre — mesmo o usuário tendo escolhido uma conta na hora de confirmar a entrega. Causa raiz
-- confirmada dos pedidos PED-000033 e PED-000034 (diagnosticado via
-- `select pg_get_constraintdef(oid) from pg_constraint where conname='deliveries_driver_check'`).
--
-- Motorista NULL ("— Não definido —" / botão "Pular") já passava normalmente por essa constraint — CHECK
-- do Postgres só rejeita quando a expressão dá FALSE; NULL = ANY(...) dá NULL (desconhecido), que o
-- Postgres trata como constraint satisfeita. Só 'retirada' (um valor não-NULL fora da lista) dava FALSE
-- de verdade. Por isso não precisa de tratamento especial pra NULL aqui, só adicionar 'retirada' à lista.
--
-- IMPORTANTE: o código do frontend (index.html) já foi ajustado numa correção separada pra não deixar a
-- receita pendurada mesmo se esse tipo de erro acontecer de novo no futuro (ex: uma 4ª opção de motorista
-- ser adicionada e esquecerem de novo de atualizar essa constraint) — mas o certo mesmo é a constraint
-- bater com o que a interface realmente oferece, por isso esta migration.

ALTER TABLE deliveries DROP CONSTRAINT deliveries_driver_check;
ALTER TABLE deliveries ADD CONSTRAINT deliveries_driver_check
  CHECK (driver = ANY (ARRAY['beto'::text, 'gui'::text, 'retirada'::text]));
