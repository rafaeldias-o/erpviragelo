-- Fase Final — "Atalhos" (não chamamos de "prompt" na interface, só no banco/código) e conversas fixadas.
-- Ambos privados por usuário, mesmo padrão de RLS já usado em ai_conversations/ai_messages.

CREATE TABLE IF NOT EXISTS ai_saved_prompts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title text NOT NULL,
  prompt text NOT NULL,
  mode text NOT NULL DEFAULT 'company' CHECK (mode IN ('company','general')),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE ai_saved_prompts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_all_own ON ai_saved_prompts;
CREATE POLICY p_all_own ON ai_saved_prompts FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

ALTER TABLE ai_conversations ADD COLUMN IF NOT EXISTS pinned boolean NOT NULL DEFAULT false;
