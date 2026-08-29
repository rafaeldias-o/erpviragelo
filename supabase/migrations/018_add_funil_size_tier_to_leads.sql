-- Funil de Prospecção (Visitas Comerciais > Funil) — nova aba pedida pelo usuário pra separar leads por
-- tamanho/importância (Pequenos ~10 pacotes/semana, Bons ~20, Grandes 30+, Importantes = grandes contas e
-- eventos como casas de show). É uma dimensão INDEPENDENTE da etapa de negociação que já existe
-- (leads.stage: lead/contato/respondeu/negociando/fechado/pausado/perdido) — um lead pode estar
-- "negociando" (stage) e ao mesmo tempo classificado como "grande" (size_tier). Reaproveita a tabela
-- `leads` já existente (com toda a infraestrutura de tarefas/histórico/kanban já pronta) em vez de criar
-- uma tabela nova — só adiciona as colunas que faltam.
--
-- size_tier NULL = lead ainda não "ativado" no Funil de Prospecção (continua existindo normalmente no
-- CRM por etapa, só não aparece na nova aba). Isso implementa o pedido de "não quero que todos os
-- prospects apareçam de imediato no funil" — a ativação é uma ação explícita do usuário.

ALTER TABLE leads ADD COLUMN IF NOT EXISTS size_tier text;
ALTER TABLE leads ADD CONSTRAINT leads_size_tier_check
  CHECK (size_tier IS NULL OR size_tier = ANY (ARRAY['pequeno'::text, 'bom'::text, 'grande'::text, 'importante'::text]));

-- Estimativa de pacotes vendidos por semana — é o critério usado pra sugerir/justificar o tier acima.
ALTER TABLE leads ADD COLUMN IF NOT EXISTS estimated_weekly_packages numeric;

-- Tipo de negócio (Mercado, Bar, Restaurante, Casa de show, etc.) — mesmo conceito já usado em
-- field_prospects.segment, duplicado aqui pra não precisar de join só pra mostrar/filtrar no Funil.
ALTER TABLE leads ADD COLUMN IF NOT EXISTS segment text;

-- Marcação manual de "quente" — independente do tier, pra sinalizar um lead que precisa de atenção
-- prioritária agora, seja qual for o tamanho dele.
ALTER TABLE leads ADD COLUMN IF NOT EXISTS hot boolean NOT NULL DEFAULT false;

-- Vínculo com Cidade/Bairro já cadastrados em Visitas Comerciais > Regiões (visit_cities/
-- visit_neighborhoods) — usado só pelo Funil de Prospecção, pra saber com que field_prospect vincular
-- ou criar (leads.city/neighborhood continuam sendo texto livre, usados no cadastro geral do CRM; estes
-- dois aqui existem só quando o lead tem uma região "oficial" das Visitas Comerciais escolhida).
ALTER TABLE leads ADD COLUMN IF NOT EXISTS region_city_id uuid REFERENCES visit_cities(id);
ALTER TABLE leads ADD COLUMN IF NOT EXISTS region_neighborhood_id uuid REFERENCES visit_neighborhoods(id);
