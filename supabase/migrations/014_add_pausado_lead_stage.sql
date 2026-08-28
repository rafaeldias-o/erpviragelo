-- Adiciona "pausado" à lista de etapas válidas do funil de vendas (leads.stage). O frontend já foi
-- atualizado com a nova coluna do kanban, mas o banco tinha uma restrição (CHECK constraint) travando
-- só os 6 valores antigos — sem essa migration, tentar mover um lead pra "Pausado" falha com erro 400
-- (violação de constraint), que foi exatamente o bug reportado.
--
-- Postgres não permite "adicionar um valor" a um CHECK existente — precisa remover e recriar com a
-- lista atualizada. Não afeta nenhum dado existente, só a regra de validação.
ALTER TABLE leads DROP CONSTRAINT leads_stage_check;
ALTER TABLE leads ADD CONSTRAINT leads_stage_check
  CHECK (stage = ANY (ARRAY['lead'::text, 'contato'::text, 'respondeu'::text, 'negociando'::text, 'fechado'::text, 'pausado'::text, 'perdido'::text]));
