-- Log de auditoria pra "entrar como outro usuário" — toda vez que o proprietário usar isso, fica
-- registrado quem acessou, o que virou, e quando. Não é opcional numa funcionalidade dessas.
CREATE TABLE IF NOT EXISTS impersonation_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES auth.users(id),
  target_user_id uuid NOT NULL REFERENCES auth.users(id),
  target_email text,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE impersonation_logs ENABLE ROW LEVEL SECURITY;
-- Só leitura, só admin (é um log de auditoria — ninguém deveria conseguir apagar/alterar pela API normal,
-- só o backend com service role grava, e mesmo assim ninguém edita depois de criado).
DROP POLICY IF EXISTS p_read_admin ON impersonation_logs;
CREATE POLICY p_read_admin ON impersonation_logs FOR SELECT
  USING (auth_user_role() = 'admin');
