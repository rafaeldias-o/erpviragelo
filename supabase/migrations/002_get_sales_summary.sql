-- get_sales_summary — espelha renderPedidosDashboard() do index.html (aba Pedidos):
-- pedidos criados no período (created_at), status='entregue', faturamento = soma de "total",
-- ticket médio = faturamento / qtd de pedidos entregues, pacotes = soma de qty dos itens.

CREATE OR REPLACE FUNCTION get_sales_summary(p_from date, p_to date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_orders_count int;
  v_revenue numeric;
  v_avg_ticket numeric;
  v_packages int;
  v_new_customers int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT COUNT(*), COALESCE(SUM(total),0)
  INTO v_orders_count, v_revenue
  FROM orders
  WHERE status='entregue' AND created_at::date BETWEEN p_from AND p_to AND deleted_at IS NULL;

  v_avg_ticket := CASE WHEN v_orders_count > 0 THEN v_revenue / v_orders_count ELSE 0 END;

  SELECT COALESCE(SUM(oi.qty),0) INTO v_packages
  FROM order_items oi
  JOIN orders o ON o.id = oi.order_id
  WHERE o.status='entregue' AND o.created_at::date BETWEEN p_from AND p_to AND o.deleted_at IS NULL;

  -- clientes novos: primeira compra (entregue) do cliente caiu dentro do período
  SELECT COUNT(*) INTO v_new_customers FROM (
    SELECT o.client_id, MIN(o.created_at::date) AS first_order
    FROM orders o WHERE o.status='entregue' AND o.deleted_at IS NULL
    GROUP BY o.client_id
    HAVING MIN(o.created_at::date) BETWEEN p_from AND p_to
  ) x;

  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'orders_delivered', v_orders_count,
    'revenue', v_revenue,
    'average_ticket', ROUND(v_avg_ticket, 2),
    'packages_sold', v_packages,
    'new_customers', v_new_customers
  );
END;
$$;

REVOKE ALL ON FUNCTION get_sales_summary(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_sales_summary(date, date) TO authenticated;
