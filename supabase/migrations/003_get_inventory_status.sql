-- get_inventory_status — espelha renderCoberturaEstoque() do index.html (card "Cobertura de Estoque" no
-- Início): estoque atual em kg de produtos acabados, consumo médio diário (janela de 30 dias, ou desde a
-- 1a entrega se o negócio for mais novo que isso), cobertura estimada em dias.
-- Peso de cada item: usa weight_kg se tiver, senão tenta extrair "Xkg" do nome do produto — mesma lógica
-- de inferWeightKg() no frontend.

CREATE OR REPLACE FUNCTION get_inventory_status()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_estoque_kg numeric := 0;
  v_earliest_delivery date;
  v_window_start date;
  v_window_days int;
  v_consumo_kg numeric := 0;
  v_media_diaria numeric;
  v_cobertura_dias numeric;
  v_critical jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  -- estoque atual em kg (produtos acabados)
  SELECT COALESCE(SUM(
    s.qty * COALESCE(s.weight_kg, (regexp_match(s.name, '(\d+(\.\d+)?)\s*kg', 'i'))[1]::numeric)
  ), 0) INTO v_estoque_kg
  FROM stock_items s
  WHERE s.category = 'produto_acabado' AND s.deleted_at IS NULL
  AND COALESCE(s.weight_kg, (regexp_match(s.name, '(\d+(\.\d+)?)\s*kg', 'i'))[1]::numeric) IS NOT NULL;

  -- janela: 30 dias, ou desde a 1a entrega se o negócio começou há menos de 30 dias
  SELECT MIN(delivered_at::date) INTO v_earliest_delivery
  FROM orders WHERE status='entregue' AND delivered_at IS NOT NULL AND deleted_at IS NULL;

  IF v_earliest_delivery IS NOT NULL AND v_earliest_delivery > (CURRENT_DATE - 30) THEN
    v_window_start := v_earliest_delivery;
    v_window_days := GREATEST(1, (CURRENT_DATE - v_earliest_delivery) + 1);
  ELSE
    v_window_start := CURRENT_DATE - 30;
    v_window_days := 30;
  END IF;

  SELECT COALESCE(SUM(
    oi.qty * COALESCE(s.weight_kg, (regexp_match(s.name, '(\d+(\.\d+)?)\s*kg', 'i'))[1]::numeric)
  ), 0) INTO v_consumo_kg
  FROM order_items oi
  JOIN orders o ON o.id = oi.order_id
  JOIN stock_items s ON s.id = oi.stock_item_id
  WHERE o.status='entregue' AND o.delivered_at::date >= v_window_start AND o.deleted_at IS NULL;

  v_media_diaria := v_consumo_kg / v_window_days;
  v_cobertura_dias := CASE WHEN v_media_diaria > 0 THEN ROUND(v_estoque_kg / v_media_diaria, 1) ELSE NULL END;

  -- produtos críticos: estoque abaixo do mínimo cadastrado (min_qty) — ORDER BY + LIMIT precisam vir
  -- numa subconsulta ANTES do jsonb_agg, senão o Postgres não sabe se é pra ordenar as linhas ou o
  -- agregado em si.
  SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb)
  INTO v_critical
  FROM (
    SELECT name, qty, min_qty
    FROM stock_items
    WHERE active AND deleted_at IS NULL AND min_qty > 0 AND qty < min_qty
    ORDER BY (qty::numeric / NULLIF(min_qty,0)) ASC
    LIMIT 10
  ) t;

  RETURN jsonb_build_object(
    'stock_kg', ROUND(v_estoque_kg, 1),
    'avg_daily_consumption_kg', ROUND(v_media_diaria, 1),
    'coverage_days', v_cobertura_dias,
    'window_days_used', v_window_days,
    'critical_products', v_critical
  );
END;
$$;

REVOKE ALL ON FUNCTION get_inventory_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_inventory_status() TO authenticated;
