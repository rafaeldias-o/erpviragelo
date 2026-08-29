-- Corrige a constraint transactions_status_check pra aceitar 'cancelado' — valor usado desde antes em 3
-- lugares do frontend (estornarPedidoCore, cancelTransaction, e agora também deleteOrder) toda vez que
-- uma receita ou despesa precisa ser cancelada sem apagar o registro (mantém auditável, só marca como
-- cancelada). A constraint só aceitava 'pago' e 'pendente' — 'cancelado' NUNCA esteve na lista.
--
-- Gravidade confirmada com o usuário via consulta direta: `select distinct type, status, count(*) from
-- transactions group by type, status` não retornou NENHUMA linha com status='cancelado' em toda a base —
-- confirma que esse valor nunca foi gravado com sucesso, desde que essas funções existem.
--
-- Consequência real: toda vez que alguém usou "Estornar" num pedido entregue por engano, ou "Cancelar
-- lançamento" no Financeiro numa receita de pedido, o pedido/estoque eram corrigidos normalmente, mas a
-- receita antiga CONTINUAVA "pago" pra sempre — só ficava invisível na Conciliação porque o pedido não
-- é mais "entregue" (a checagem de "Pedido sem receita"/"Receita duplicada" olha pedidos com status
-- entregue). Se esse mesmo pedido fosse corrigido e reentregue depois, o gatilho fulfill_order() criava
-- uma SEGUNDA receita — essa é, com grande probabilidade, a causa raiz real por trás da maioria dos
-- casos de "Receita duplicada" já vistos e corrigidos manualmente na Conciliação, sem que a causa de
-- fundo (esta constraint) tivesse sido corrigida até agora.
--
-- O frontend já foi corrigido numa mudança separada pra checar erro nessa atualização especificamente
-- (estornarPedidoCore e deleteOrder) e avisar se acontecer de novo — cancelTransaction já checava erro
-- desde antes, só nunca soube o motivo real da falha. Mas o certo é a constraint bater com os valores
-- que a aplicação realmente usa, por isso esta migration.

ALTER TABLE transactions DROP CONSTRAINT transactions_status_check;
ALTER TABLE transactions ADD CONSTRAINT transactions_status_check
  CHECK (status = ANY (ARRAY['pago'::text, 'pendente'::text, 'cancelado'::text]));
