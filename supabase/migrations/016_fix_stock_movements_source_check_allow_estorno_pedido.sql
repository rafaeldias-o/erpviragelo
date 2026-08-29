-- Corrige a constraint stock_movements_source_check pra aceitar 'estorno_pedido' — valor usado desde
-- antes em 3 funções do frontend (estornarPedidoCore, hardDeleteDuplicateOrder, e agora também
-- deleteOrder) toda vez que uma quantidade é devolvida ao estoque por causa de um pedido estornado,
-- excluído ou removido por duplicidade. A constraint só aceitava 'manual', 'producao' e 'pedido' —
-- 'estorno_pedido' NUNCA esteve na lista, desde que essas funções foram escritas.
--
-- Consequência real (só descoberta agora, ao investigar por que o estoque de dois pedidos excluídos
-- não tinha voltado): a atualização da QUANTIDADE em stock_items é uma chamada separada do INSERT do
-- movimento em stock_movements — a primeira sempre funcionou normalmente (não tem essa constraint), só
-- a segunda falhava. Como nenhuma das 3 funções checava o erro desse INSERT específico (até uma
-- correção separada no frontend, feita junto com esta migration), a falha era 100% silenciosa: a
-- quantidade voltava certa pro estoque, mas o registro rastreável no histórico de movimentações nunca
-- era criado — sem avisar ninguém. Diagnosticado via
-- `select pg_get_constraintdef(oid) from pg_constraint where conname='stock_movements_source_check'`.
--
-- O frontend já foi corrigido numa mudança separada pra nunca mais deixar esse tipo de erro passar em
-- silêncio (agora avisa se acontecer de novo, sem desfazer a devolução da quantidade) — mas o certo é a
-- constraint bater com os valores que a aplicação realmente usa, por isso esta migration.

ALTER TABLE stock_movements DROP CONSTRAINT stock_movements_source_check;
ALTER TABLE stock_movements ADD CONSTRAINT stock_movements_source_check
  CHECK (source = ANY (ARRAY['manual'::text, 'producao'::text, 'pedido'::text, 'estorno_pedido'::text]));
