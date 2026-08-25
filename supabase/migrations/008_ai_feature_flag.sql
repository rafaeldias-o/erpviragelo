-- Fase 6 — feature flag ai_module_enabled. Barato e valioso: se o Gemini tiver problema, estourar cota,
-- ou aparecer um bug, dá pra desligar SÓ a Inteligência sem mexer no resto do ERP.
-- Reaproveita company_settings (tabela de linha única já usada pra outras configurações do sistema).
ALTER TABLE company_settings ADD COLUMN IF NOT EXISTS ai_module_enabled boolean NOT NULL DEFAULT true;
