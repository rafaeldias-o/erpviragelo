-- Fase 5 — observabilidade básica de consumo da IA. Guarda o essencial pra futuramente montar uma tela
-- de consumo (seção 31 do roadmap) — sem criar dashboard nenhum agora, só capturando o dado enquanto ele
-- já está disponível na resposta da própria API do Gemini (usageMetadata), que seria desperdício não
-- guardar.
CREATE TABLE IF NOT EXISTS ai_usage_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  conversation_id uuid REFERENCES ai_conversations(id) ON DELETE SET NULL,
  mode text,
  model text,
  tools_used jsonb,
  prompt_tokens int,
  completion_tokens int,
  total_tokens int,
  duration_ms int,
  status text NOT NULL, -- 'success' | 'error' | 'rate_limited_internal' | 'rate_limited_gemini'
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_usage_logs_user ON ai_usage_logs(user_id, created_at DESC);

ALTER TABLE ai_usage_logs ENABLE ROW LEVEL SECURITY;

-- Cada usuário vê os próprios logs; admin vê todos (útil pra observabilidade futura sem precisar mudar
-- política depois).
DROP POLICY IF EXISTS p_read ON ai_usage_logs;
CREATE POLICY p_read ON ai_usage_logs FOR SELECT
  USING (user_id = auth.uid() OR auth_user_role() = 'admin');

-- Só a Edge Function grava (via client autenticado do próprio usuário) — não precisa de política de
-- escrita ampla, o INSERT sempre parte do usuário logado registrando a própria chamada.
DROP POLICY IF EXISTS p_insert_own ON ai_usage_logs;
CREATE POLICY p_insert_own ON ai_usage_logs FOR INSERT
  WITH CHECK (user_id = auth.uid());
