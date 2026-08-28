-- Documenta (traz pro controle de versão) a lógica de negócio mais crítica do sistema: a função que
-- baixa estoque e gera a receita quando um pedido vira "entregue". Essa função já existia direto no
-- banco, criada fora do repositório — nenhum arquivo de migration a descrevia até agora. Isso é um
-- CREATE OR REPLACE com o EXATO mesmo comportamento já em produção (confirmado via
-- pg_get_functiondef antes de escrever isto) — não muda nada, só documenta.
--
-- IMPORTANTE pro trabalho de offline-first: essa função já tem uma trava de idempotência embutida
-- (`new.stock_applied = false` na condição) — se a transição de status pra "entregue" for reenviada
-- duas vezes (ex: conexão caiu antes da confirmação chegar ao cliente), a segunda execução não duplica
-- estoque nem receita, porque `stock_applied` já estará `true`. Isso é uma base útil, mas NÃO cobre
-- duplicação na CRIAÇÃO do pedido em si (um INSERT reenviado ainda criaria 2 pedidos, cada um com
-- fulfill_order rodando uma vez) — isso precisa ser resolvido na camada de sincronização (ex: upsert por
-- UUID gerado no cliente, já que todas as tabelas principais usam UUID como PK).

CREATE OR REPLACE FUNCTION public.fulfill_order()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare item record; client_name text;
begin
  if new.status = 'entregue' and old.status is distinct from 'entregue' and new.stock_applied = false then
    select name into client_name from clients where id = new.client_id;
    for item in select * from order_items where order_id = new.id loop
      update stock_items set qty = qty - item.qty, updated_at = now() where id = item.stock_item_id;
      insert into stock_movements (stock_item_id, type, qty, source, order_id, note)
        values (item.stock_item_id, 'saida', item.qty, 'pedido', new.id, 'Pedido — ' || coalesce(client_name,'cliente'));
    end loop;
    insert into transactions (type, description, category, amount, due_date, status, client_id, order_id)
      values ('receita', 'Venda — Pedido ' || new.order_number, 'Vendas', new.total, current_date, 'pago', new.client_id, new.id);
    new.stock_applied := true;
    new.delivered_at := now();
  end if;
  return new;
end;
$function$;

-- Idem pra numeração de pedidos (sequência do Postgres — só existe no servidor, relevante pra offline:
-- um pedido criado offline não pode ter esse número final até sincronizar).
CREATE OR REPLACE FUNCTION public.set_order_number()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if new.order_number is null then
    new.order_number := 'PED-' || lpad(nextval('orders_number_seq')::text, 6, '0');
  end if;
  return new;
end;
$function$;
