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
-- 3) "payable_open"/"receivable_open" somavam TODO o futuro (inclusive parcelas/recorrências de meses
--    seguintes), sem filtrar por vencimento — isso fazia o Analista IA soar um alarme de liquidez
--    desproporcional (ex: R$1.401,87 "em aberto" quando só ~R$90 vencia de fato dentro do mês em
--    análise, o resto era compromisso do resto do ano). Agora existem dois números pra cada lado:
--    "*_due_this_period" (vence dentro do p_from/p_to perguntado — a urgência real) e "*_open_total"
--    (todo o saldo em aberto, qualquer vencimento — bom pra planejamento, não pra alarme de caixa do mês).

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
  v_receivable_open_total numeric;
  v_payable_open_total numeric;
  v_receivable_due_this_period numeric;
  v_payable_due_this_period numeric;
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

  -- Totais (qualquer vencimento, presente ou futuro) — bom pra planejamento de longo prazo
  SELECT COALESCE(SUM((amount - COALESCE(discount,0) + COALESCE(interest,0) + COALESCE(fine,0)) - COALESCE(paid_amount,0)),0) INTO v_receivable_open_total
  FROM transactions WHERE type='receita' AND status NOT IN ('pago','cancelado') AND deleted_at IS NULL;

  SELECT COALESCE(SUM((amount - COALESCE(discount,0) + COALESCE(interest,0) + COALESCE(fine,0)) - COALESCE(paid_amount,0)),0) INTO v_payable_open_total
  FROM transactions WHERE type='despesa' AND status NOT IN ('pago','cancelado') AND deleted_at IS NULL;

  -- Só o que vence DENTRO do período perguntado (p_from/p_to) — é isso que representa urgência real de
  -- caixa nesse mês, não o compromisso do ano inteiro
  SELECT COALESCE(SUM((amount - COALESCE(discount,0) + COALESCE(interest,0) + COALESCE(fine,0)) - COALESCE(paid_amount,0)),0) INTO v_receivable_due_this_period
  FROM transactions WHERE type='receita' AND status NOT IN ('pago','cancelado') AND due_date BETWEEN p_from AND p_to AND deleted_at IS NULL;

  SELECT COALESCE(SUM((amount - COALESCE(discount,0) + COALESCE(interest,0) + COALESCE(fine,0)) - COALESCE(paid_amount,0)),0) INTO v_payable_due_this_period
  FROM transactions WHERE type='despesa' AND status NOT IN ('pago','cancelado') AND due_date BETWEEN p_from AND p_to AND deleted_at IS NULL;

  RETURN jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'account_balance_total', v_saldo_total,
    'revenue', v_receita_total,
    'expenses', v_despesa_total,
    'result', v_receita_total - v_despesa_total,
    -- mantidos com o nome antigo por compatibilidade com quem já lia esses campos — continuam sendo o
    -- TOTAL (qualquer vencimento), nunca só o do período
    'receivable_open', v_receivable_open_total,
    'payable_open', v_payable_open_total,
    'receivable_open_total', v_receivable_open_total,
    'payable_open_total', v_payable_open_total,
    'receivable_due_this_period', v_receivable_due_this_period,
    'payable_due_this_period', v_payable_due_this_period
  );
END;
$$;

-- Só usuários autenticados podem chamar (a Edge Function chama com o JWT do usuário, não service role)
REVOKE ALL ON FUNCTION get_financial_summary(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_financial_summary(date, date) TO authenticated;
