-- get_production_summary — Fase 6, item de alta prioridade. Fecha a lacuna que faltava no módulo:
-- Financeiro, Vendas, Estoque e Clientes já existiam; faltava Produção, peça central da operação.
--
-- Espelha a lógica real: capacidade diária = soma de capacity_kg_day das máquinas ativas (mesmo cálculo
-- já usado no painel "Capacidade de Armazenamento"/Início do ERP). Produção real = soma de "kg" da
-- tabela production no período. Utilização = produção real diária média / capacidade diária.

CREATE OR REPLACE FUNCTION get_production_summary(p_from date, p_to date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total_kg numeric;
  v_days int;
  v_avg_daily_kg numeric;
  v_capacity_kg_day numeric;
  v_utilization numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT COALESCE(SUM(kg),0) INTO v_total_kg
  FROM production
  WHERE date BETWEEN p_from AND p_to AND deleted_at IS NULL;

  v_days := GREATEST(1, (p_to - p_from) + 1);
  v_avg_daily_kg := v_total_kg / v_days;

  SELECT COALESCE(SUM(capacity_kg_day),0) INTO v_capacity_kg_day
  FROM production_machines WHERE active;

  v_utilization := CASE WHEN v_capacity_kg_day > 0 THEN ROUND(v_avg_daily_kg / v_capacity_kg_day * 100, 1) ELSE NULL END;

  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'total_produced_kg', ROUND(v_total_kg, 1),
    'avg_daily_production_kg', ROUND(v_avg_daily_kg, 1),
    'daily_capacity_kg', v_capacity_kg_day,
    'capacity_utilization_pct', v_utilization
  );
END;
$$;

REVOKE ALL ON FUNCTION get_production_summary(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_production_summary(date, date) TO authenticated;
