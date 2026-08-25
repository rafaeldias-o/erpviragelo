-- Correção da escalação de privilégio em "profiles" (revisão 2, após feedback):
-- - role/active: só quem já é admin pode mudar (de qualquer perfil, inclusive o próprio)
-- - id: NINGUÉM pode mudar via UPDATE normal, nem admin — é o vínculo com auth.users, mudar isso corrompe
--   o login da pessoa, não é "gerenciar usuário", é quebrar a conta.
-- - Qualquer outro campo (name, etc.) continua editável exatamente como já é hoje, sem mudança nenhuma.

CREATE OR REPLACE FUNCTION prevent_self_role_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Não é permitido alterar o id de um perfil (é o vínculo com a conta de login).';
  END IF;

  IF (NEW.role IS DISTINCT FROM OLD.role OR NEW.active IS DISTINCT FROM OLD.active)
     AND auth_user_role() <> 'admin' THEN
    RAISE EXCEPTION 'Só administradores podem alterar cargo (role) ou status (active) de um perfil.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_self_role_escalation ON profiles;
CREATE TRIGGER trg_prevent_self_role_escalation
BEFORE UPDATE ON profiles
FOR EACH ROW
EXECUTE FUNCTION prevent_self_role_escalation();
