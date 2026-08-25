-- get_financial_summary — espelha renderFinDashboard() do index.html, casa decimal por casa decimal.
-- SECURITY DEFINER + checagem manual de auth.uid() -- só usuário autenticado chama, RLS de "transactions"
-- continua valendo pras consultas internas via auth.uid() do contexto.
--
-- Correções pós-validação (comparando com a tela real, número por número):
-- 1) Faltava somar "initial_balance" de cada conta (accountBalance() do JS soma
--    account.initialBalance + net + transfersNet; a 1ª versão só somava net + transfersNet).
-- 2) Faltava "deleted_at IS NULL" em transactions, financial_accounts e account_transfers — o
--    frontend SEMPRE filtra isso na hora de carregar os dados (soft delete), e minha função estava
--    contando 2 despesas excluídas (R$85 + R$30 = R$115) que a tela corretamente ignora. Foi assim que
--    achamos a divergência real: R$306 (SQL, errado) vs R$421 (tela, certo) na conta Caixa.

CREATE OR REPLACE FUNCTION get_financial_summary(p_from date, p_to date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_saldo_total numeric;
  v_receita_total numeric;
  v_despesa_total numeric;
  v_receivable_open numeric;
  v_payable_open numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  -- Saldo total: mesma definição de accountBalance() somada por todas as contas ativas e não excluídas —
  -- initial_balance + líquido de transactions não excluídas (pago/parcial) + líquido de account_transfers não excluídas
  SELECT COALESCE(SUM(
    fa.initial_balance
    + (SELECT COALESCE(SUM(CASE WHEN t.type='receita' THEN
        CASE WHEN t.status='pago' THEN t.amount WHEN t.status='parcial' THEN t.paid_amount ELSE 0 END
      ELSE -1 * CASE WHEN t.status='pago' THEN t.amount WHEN t.status='parcial' THEN t.paid_amount ELSE 0 END
      END), 0)
     FROM transactions t WHERE t.account_id = fa.id AND t.status IN ('pago','parcial') AND t.deleted_at IS NULL)
    + COALESCE((SELECT SUM(CASE WHEN tr.to_account_id=fa.id THEN tr.amount WHEN tr.from_account_id=fa.id THEN -tr.amount ELSE 0 END)
     FROM account_transfers tr WHERE (tr.to_account_id=fa.id OR tr.from_account_id=fa.id) AND tr.deleted_at IS NULL), 0)
  ), 0) INTO v_saldo_total
  FROM financial_accounts fa WHERE fa.status='ativa' AND fa.deleted_at IS NULL;

  SELECT COALESCE(SUM(amount),0) INTO v_receita_total
  FROM transactions
  WHERE type='receita' AND status='pago' AND payment_date BETWEEN p_from AND p_to AND deleted_at IS NULL;

  SELECT COALESCE(SUM(amount),0) INTO v_despesa_total
  FROM transactions
  WHERE type='despesa' AND status='pago' AND payment_date BETWEEN p_from AND p_to AND deleted_at IS NULL;

  SELECT COALESCE(SUM((amount - COALESCE(discount,0) + COALESCE(interest,0) + COALESCE(fine,0)) - COALESCE(paid_amount,0)),0) INTO v_receivable_open
  FROM transactions WHERE type='receita' AND status NOT IN ('pago','cancelado') AND deleted_at IS NULL;

  SELECT COALESCE(SUM((amount - COALESCE(discount,0) + COALESCE(interest,0) + COALESCE(fine,0)) - COALESCE(paid_amount,0)),0) INTO v_payable_open
  FROM transactions WHERE type='despesa' AND status NOT IN ('pago','cancelado') AND deleted_at IS NULL;

  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'account_balance_total', v_saldo_total,
    'revenue', v_receita_total,
    'expenses', v_despesa_total,
    'result', v_receita_total - v_despesa_total,
    'receivable_open', v_receivable_open,
    'payable_open', v_payable_open
  );
END;
$$;

-- Só usuários autenticados podem chamar (a Edge Function chama com o JWT do usuário, não service role)
REVOKE ALL ON FUNCTION get_financial_summary(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_financial_summary(date, date) TO authenticated;
