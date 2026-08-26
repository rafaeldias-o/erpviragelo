-- Coluna pra guardar o limite diário de requisições do Gemini (RPD) configurado manualmente — o valor
-- exato muda de tempos em tempos conforme o Google atualiza os planos, então fica editável na tela em
-- vez de fixo no código. Usado só pra calcular "quanto falta hoje" — não afeta nenhum bloqueio real
-- (o bloqueio real é o próprio 429 que o Gemini já retorna).
ALTER TABLE company_settings ADD COLUMN IF NOT EXISTS gemini_daily_request_limit integer NOT NULL DEFAULT 1500;
