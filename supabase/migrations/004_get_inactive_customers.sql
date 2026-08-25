-- get_inactive_customers — NÃO espelha nenhuma tela existente (não havia uma lista agregada disso no
-- ERP ainda, só o detalhe por cliente individual). Usa o mesmo critério já usado na ficha do cliente:
-- "dias sem comprar" = hoje - data do último pedido entregue. Considera inativo > 30 dias, mesmo limiar
-- visual (cor de alerta) já usado na tela de detalhe do cliente.
-- Minimização de dados: retorna só nome + métricas — sem telefone, e-mail, CPF/CNPJ ou endereço.

CREATE OR REPLACE FUNCTION get_inactive_customers(p_min_days int DEFAULT 30, p_limit int DEFAULT 10)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
  v_active_count int;
  v_inactive_count int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  WITH last_orders AS (
    SELECT o.client_id, MAX(o.delivered_at::date) AS last_order_date, COUNT(*) AS total_orders
    FROM orders o WHERE o.status='entregue' AND o.deleted_at IS NULL
    GROUP BY o.client_id
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'name', c.name,
      'days_since_last_order', (CURRENT_DATE - lo.last_order_date),
      'total_orders_lifetime', lo.total_orders
    ) ORDER BY (CURRENT_DATE - lo.last_order_date) DESC) FILTER (WHERE (CURRENT_DATE - lo.last_order_date) >= p_min_days), '[]'::jsonb)
  INTO v_result
  FROM clients c
  JOIN last_orders lo ON lo.client_id = c.id
  WHERE c.status='ativo' AND c.deleted_at IS NULL;

  -- limita a lista aos p_limit mais inativos (a query acima já ordena; corta em SQL puro no jsonb)
  SELECT jsonb_agg(elem) INTO v_result
  FROM (SELECT elem FROM jsonb_array_elements(v_result) elem LIMIT p_limit) t;
  v_result := COALESCE(v_result, '[]'::jsonb);

  SELECT COUNT(*) INTO v_active_count FROM clients WHERE status='ativo' AND deleted_at IS NULL;
  SELECT COUNT(*) INTO v_inactive_count FROM (
    SELECT o.client_id FROM orders o WHERE o.status='entregue' AND o.deleted_at IS NULL
    GROUP BY o.client_id HAVING (CURRENT_DATE - MAX(o.delivered_at::date)) >= p_min_days
  ) x;

  RETURN jsonb_build_object(
    'active_customers', v_active_count,
    'inactive_customers_count', v_inactive_count,
    'threshold_days', p_min_days,
    'top_inactive', v_result
  );
END;
$$;

REVOKE ALL ON FUNCTION get_inactive_customers(int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_inactive_customers(int, int) TO authenticated;
