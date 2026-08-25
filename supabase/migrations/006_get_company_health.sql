-- get_company_health — Fase 4 (Inteligência Proativa). Score de Saúde da Empresa.
--
-- Princípio importante: o CÁLCULO é 100% determinístico e reaproveita as RPCs já validadas (não duplica
-- nenhuma regra de negócio — chama get_financial_summary, get_sales_summary, get_inventory_status e
-- get_inactive_customers, que já batem com o ERP). O Gemini nunca calcula esse número, só interpreta o
-- resultado que essa função devolve.
--
-- Pesos (documentados, ajustáveis depois com mais dados históricos — hoje o negócio é novo, poucos meses
-- de histórico, então os pesos abaixo são uma primeira hipótese razoável, não uma fórmula definitiva):
-- Financeiro 35% | Vendas 30% | Estoque 20% | Clientes 15%
-- (o documento original sugeria incluir "Produção/Operação" também — ainda não existe uma tool validada
-- pra isso, então fica de fora por enquanto, redistribuído entre os outros 4 pilares)

CREATE OR REPLACE FUNCTION get_company_health()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_from date := date_trunc('month', CURRENT_DATE)::date;
  v_to date := CURRENT_DATE;
  v_fin jsonb;
  v_sales jsonb;
  v_inv jsonb;
  v_cust jsonb;
  v_financial_score numeric;
  v_sales_score numeric;
  v_inventory_score numeric;
  v_customer_score numeric;
  v_overall numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  v_fin := get_financial_summary(v_from, v_to);
  v_sales := get_sales_summary(v_from, v_to);
  v_inv := get_inventory_status();
  v_cust := get_inactive_customers(30, 1);

  -- Financeiro: resultado positivo/negativo (base) + liquidez (saldo em conta vs. contas a pagar em aberto)
  DECLARE
    v_result numeric := (v_fin->>'result')::numeric;
    v_balance numeric := (v_fin->>'account_balance_total')::numeric;
    v_payable numeric := (v_fin->>'payable_open')::numeric;
    v_liquidity_ratio numeric;
  BEGIN
    v_financial_score := CASE WHEN v_result >= 0 THEN 60 ELSE 30 END;
    IF v_payable > 0 THEN
      v_liquidity_ratio := v_balance / v_payable;
      v_financial_score := v_financial_score + LEAST(40, GREATEST(0, v_liquidity_ratio * 40));
    ELSE
      v_financial_score := v_financial_score + 40;
    END IF;
    v_financial_score := LEAST(100, v_financial_score);
  END;

  -- Vendas: volume de pedidos entregues no mês (proxy simples de atividade comercial — comparação com o
  -- mês anterior fica pra uma próxima versão, pra não aumentar o escopo agora)
  DECLARE
    v_orders int := (v_sales->>'orders_delivered')::int;
  BEGIN
    v_sales_score := CASE
      WHEN v_orders = 0 THEN 20
      WHEN v_orders < 5 THEN 50
      WHEN v_orders < 15 THEN 75
      ELSE 95
    END;
  END;

  -- Estoque: cobertura em dias (mesmo limiar já usado visualmente no card do Início: <3 dias = crítico)
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

  -- Clientes: proporção de clientes inativos (>30 dias sem comprar) sobre o total ativo
  DECLARE
    v_active int := (v_cust->>'active_customers')::int;
    v_inactive int := (v_cust->>'inactive_customers_count')::int;
    v_ratio numeric;
  BEGIN
    v_ratio := CASE WHEN v_active > 0 THEN v_inactive::numeric / v_active ELSE 0 END;
    v_customer_score := GREATEST(0, 100 - v_ratio*150);
  END;

  v_overall := ROUND(v_financial_score*0.35 + v_sales_score*0.30 + v_inventory_score*0.20 + v_customer_score*0.15);

  RETURN jsonb_build_object(
    'overall_score', v_overall,
    'overall_label', CASE WHEN v_overall>=75 THEN 'Saudável' WHEN v_overall>=50 THEN 'Atenção' ELSE 'Crítico' END,
    'dimensions', jsonb_build_object(
      'financial', jsonb_build_object('score', ROUND(v_financial_score), 'weight', 35),
      'sales', jsonb_build_object('score', ROUND(v_sales_score), 'weight', 30),
      'inventory', jsonb_build_object('score', ROUND(v_inventory_score), 'weight', 20),
      'customers', jsonb_build_object('score', ROUND(v_customer_score), 'weight', 15)
    ),
    'raw_metrics', jsonb_build_object(
      'result', (v_fin->>'result')::numeric,
      'account_balance_total', (v_fin->>'account_balance_total')::numeric,
      'payable_open', (v_fin->>'payable_open')::numeric,
      'orders_delivered', (v_sales->>'orders_delivered')::int,
      'coverage_days', (v_inv->>'coverage_days')::numeric,
      'critical_products', v_inv->'critical_products',
      'active_customers', (v_cust->>'active_customers')::int,
      'inactive_customers_count', (v_cust->>'inactive_customers_count')::int
    ),
    'period', jsonb_build_object('from', v_from, 'to', v_to)
  );
END;
$$;

REVOKE ALL ON FUNCTION get_company_health() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_company_health() TO authenticated;
