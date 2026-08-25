-- get_company_health — Fase 4 (Inteligência Proativa), com comparação de período e Produção (Fase 6).
--
-- Princípio importante: o CÁLCULO é 100% determinístico e reaproveita as RPCs já validadas (não duplica
-- nenhuma regra de negócio). O Gemini nunca calcula esse número, só interpreta o resultado.
--
-- Pesos (documentados, ajustáveis depois com mais dados históricos — hoje o negócio é novo, poucos meses
-- de histórico, então os pesos abaixo são uma primeira hipótese razoável, não uma fórmula definitiva):
-- Financeiro 30% | Vendas 25% | Produção 15% | Estoque 15% | Clientes 15%
-- (redistribuído em relação à versão anterior — antes Produção não existia como tool validada)
--
-- LIMITAÇÃO CONHECIDA da comparação com o mês anterior: Financeiro e Vendas são recalculados de verdade
-- pro mês anterior (aceitam período como parâmetro). Estoque, Clientes e Produção NÃO recalculam
-- historicamente — Estoque/Clientes porque não existe snapshot histórico salvo, e Produção porque nesta
-- 1a versão optamos por manter simples. Documentado aqui e explicado na interface, não escondido.

CREATE OR REPLACE FUNCTION calc_partial_health_score(p_from date, p_to date)
RETURNS TABLE(financial_score numeric, sales_score numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fin jsonb;
  v_sales jsonb;
  v_result numeric;
  v_balance numeric;
  v_payable numeric;
  v_liquidity_ratio numeric;
  v_fscore numeric;
  v_orders int;
  v_sscore numeric;
BEGIN
  v_fin := get_financial_summary(p_from, p_to);
  v_sales := get_sales_summary(p_from, p_to);

  v_result := (v_fin->>'result')::numeric;
  v_balance := (v_fin->>'account_balance_total')::numeric;
  v_payable := (v_fin->>'payable_open')::numeric;
  v_fscore := CASE WHEN v_result >= 0 THEN 60 ELSE 30 END;
  IF v_payable > 0 THEN
    v_liquidity_ratio := v_balance / v_payable;
    v_fscore := v_fscore + LEAST(40, GREATEST(0, v_liquidity_ratio * 40));
  ELSE
    v_fscore := v_fscore + 40;
  END IF;
  v_fscore := LEAST(100, v_fscore);

  v_orders := (v_sales->>'orders_delivered')::int;
  v_sscore := CASE
    WHEN v_orders = 0 THEN 20
    WHEN v_orders < 5 THEN 50
    WHEN v_orders < 15 THEN 75
    ELSE 95
  END;

  RETURN QUERY SELECT v_fscore, v_sscore;
END;
$$;
REVOKE ALL ON FUNCTION calc_partial_health_score(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION calc_partial_health_score(date, date) TO authenticated;

CREATE OR REPLACE FUNCTION get_company_health()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from date := date_trunc('month', CURRENT_DATE)::date;
  v_to date := CURRENT_DATE;
  v_prev_from date := date_trunc('month', CURRENT_DATE - interval '1 month')::date;
  v_prev_to date := (date_trunc('month', CURRENT_DATE) - interval '1 day')::date;
  v_inv jsonb;
  v_cust jsonb;
  v_prod jsonb;
  v_financial_score numeric;
  v_sales_score numeric;
  v_inventory_score numeric;
  v_customer_score numeric;
  v_production_score numeric;
  v_overall numeric;
  v_prev_financial_score numeric;
  v_prev_sales_score numeric;
  v_prev_overall numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  SELECT financial_score, sales_score INTO v_financial_score, v_sales_score FROM calc_partial_health_score(v_from, v_to);

  v_inv := get_inventory_status();
  v_cust := get_inactive_customers(30, 1);
  v_prod := get_production_summary(v_from, v_to);

  DECLARE
    v_coverage numeric := (v_inv->>'coverage_days')::numeric;
  BEGIN
    v_inventory_score := CASE
      WHEN v_coverage IS NULL THEN 50
      WHEN v_coverage >= 7 THEN 100
      WHEN v_coverage >= 3 THEN 40 + (v_coverage-3)/4*60
      ELSE GREATEST(0, v_coverage/3*40)
    END;
  END;

  DECLARE
    v_active int := (v_cust->>'active_customers')::int;
    v_inactive int := (v_cust->>'inactive_customers_count')::int;
    v_ratio numeric;
  BEGIN
    v_ratio := CASE WHEN v_active > 0 THEN v_inactive::numeric / v_active ELSE 0 END;
    v_customer_score := GREATEST(0, 100 - v_ratio*150);
  END;

  -- Produção: utilização de capacidade saudável fica numa faixa média (nem ociosa, nem sobrecarregada) —
  -- 40-90% pontua bem; abaixo disso indica capacidade parada à toa; acima disso indica risco de
  -- sobrecarga/insustentabilidade no médio prazo.
  DECLARE
    v_util numeric := (v_prod->>'capacity_utilization_pct')::numeric;
  BEGIN
    v_production_score := CASE
      WHEN v_util IS NULL THEN 50
      WHEN v_util BETWEEN 40 AND 90 THEN 100
      WHEN v_util < 40 THEN GREATEST(0, v_util/40*70)
      ELSE GREATEST(30, 100 - (v_util-90)*3)
    END;
  END;

  v_overall := ROUND(
    v_financial_score*0.30 + v_sales_score*0.25 + v_production_score*0.15 + v_inventory_score*0.15 + v_customer_score*0.15
  );

  SELECT financial_score, sales_score INTO v_prev_financial_score, v_prev_sales_score FROM calc_partial_health_score(v_prev_from, v_prev_to);
  v_prev_overall := ROUND(
    v_prev_financial_score*0.30 + v_prev_sales_score*0.25 + v_production_score*0.15 + v_inventory_score*0.15 + v_customer_score*0.15
  );

  RETURN jsonb_build_object(
    'overall_score', v_overall,
    'overall_label', CASE WHEN v_overall>=75 THEN 'Saudável' WHEN v_overall>=50 THEN 'Atenção' ELSE 'Crítico' END,
    'previous_overall_score', v_prev_overall,
    'score_delta', v_overall - v_prev_overall,
    'dimensions', jsonb_build_object(
      'financial', jsonb_build_object('score', ROUND(v_financial_score), 'weight', 30),
      'sales', jsonb_build_object('score', ROUND(v_sales_score), 'weight', 25),
      'production', jsonb_build_object('score', ROUND(v_production_score), 'weight', 15),
      'inventory', jsonb_build_object('score', ROUND(v_inventory_score), 'weight', 15),
      'customers', jsonb_build_object('score', ROUND(v_customer_score), 'weight', 15)
    ),
    'raw_metrics', jsonb_build_object(
      'result', (get_financial_summary(v_from, v_to)->>'result')::numeric,
      'account_balance_total', (get_financial_summary(v_from, v_to)->>'account_balance_total')::numeric,
      'payable_open', (get_financial_summary(v_from, v_to)->>'payable_open')::numeric,
      'orders_delivered', (get_sales_summary(v_from, v_to)->>'orders_delivered')::int,
      'coverage_days', (v_inv->>'coverage_days')::numeric,
      'critical_products', v_inv->'critical_products',
      'active_customers', (v_cust->>'active_customers')::int,
      'inactive_customers_count', (v_cust->>'inactive_customers_count')::int,
      'capacity_utilization_pct', (v_prod->>'capacity_utilization_pct')::numeric,
      'avg_daily_production_kg', (v_prod->>'avg_daily_production_kg')::numeric
    ),
    'period', jsonb_build_object('from', v_from, 'to', v_to),
    'data_coverage_note', 'Estoque, Clientes e Produção refletem o cálculo do período atual em ambos os pontos comparados (sem histórico salvo desses três ainda) — a variação do score vem principalmente de Financeiro e Vendas.'
  );
END;
$$;

REVOKE ALL ON FUNCTION get_company_health() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_company_health() TO authenticated;
