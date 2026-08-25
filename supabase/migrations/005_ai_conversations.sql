-- Fase 3 — histórico de conversas do Analista IA.
-- Segue os padrões já usados no projeto: uuid, created_at/updated_at, soft delete (deleted_at),
-- políticas nomeadas p_read/p_write_... como as demais tabelas (confirmado na auditoria de Fase 0).
--
-- Diferença importante em relação ao resto do ERP: como este sistema é single-tenant (dados
-- operacionais compartilhados entre toda a equipe), MAS as conversas de IA são PRIVADAS por usuário —
-- ninguém deve ver o histórico de chat de outra pessoa, mesmo sendo admin. Por isso o RLS aqui é
-- diferente do padrão "qualquer autenticado lê tudo" usado nas tabelas operacionais.

CREATE TABLE IF NOT EXISTS ai_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title text,
  mode text NOT NULL DEFAULT 'company' CHECK (mode IN ('company','general')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  deleted_at timestamptz
);

CREATE TABLE IF NOT EXISTS ai_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES ai_conversations(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('user','model')),
  content text NOT NULL,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_conversations_user ON ai_conversations(user_id, updated_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_ai_messages_conversation ON ai_messages(conversation_id, created_at ASC);

ALTER TABLE ai_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_messages ENABLE ROW LEVEL SECURITY;

-- Conversas: cada usuário só vê/mexe nas próprias. Nada de "qualquer autenticado" aqui — diferente do
-- padrão das tabelas operacionais, de propósito, porque conversa de IA é dado pessoal.
DROP POLICY IF EXISTS p_read ON ai_conversations;
CREATE POLICY p_read ON ai_conversations FOR SELECT
  USING (user_id = auth.uid() AND deleted_at IS NULL);

DROP POLICY IF EXISTS p_write_own ON ai_conversations;
CREATE POLICY p_write_own ON ai_conversations FOR ALL
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Mensagens: só acessíveis se a conversa-mãe pertencer ao usuário autenticado.
DROP POLICY IF EXISTS p_read ON ai_messages;
CREATE POLICY p_read ON ai_messages FOR SELECT
  USING (EXISTS (SELECT 1 FROM ai_conversations c WHERE c.id = conversation_id AND c.user_id = auth.uid()));

DROP POLICY IF EXISTS p_write_own ON ai_messages;
CREATE POLICY p_write_own ON ai_messages FOR ALL
  USING (EXISTS (SELECT 1 FROM ai_conversations c WHERE c.id = conversation_id AND c.user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM ai_conversations c WHERE c.id = conversation_id AND c.user_id = auth.uid()));

-- Mantém updated_at em dia sempre que uma nova mensagem é inserida (pra ordenação "mais recente primeiro"
-- refletir conversa que RECEBEU mensagem hoje, não só as criadas hoje).
CREATE OR REPLACE FUNCTION touch_ai_conversation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE ai_conversations SET updated_at = now() WHERE id = NEW.conversation_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_ai_conversation ON ai_messages;
CREATE TRIGGER trg_touch_ai_conversation
AFTER INSERT ON ai_messages
FOR EACH ROW
EXECUTE FUNCTION touch_ai_conversation();
