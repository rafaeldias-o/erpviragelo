# Módulo Inteligência — Documentação técnica

Documento de referência do módulo de IA do ERP. Escrito pra você (ou qualquer pessoa, incluindo o Claude
numa sessão futura) conseguir entender a arquitetura sem precisar redescobrir tudo do zero.

Última atualização: 25/08/2026, ao final da implementação das 6 fases + rodada de UI/UX + Assistente
Adaptativo.

---

## 1. Visão geral da arquitetura

```
Navegador (index.html, vanilla JS)
   ↓ JWT do usuário logado (Supabase Auth)
Supabase Edge Function "ai-analyst" (Deno)
   ↓ valida JWT + role, NUNCA confia em nada vindo do frontend sobre "quem é o usuário"
   ↓ chama RPCs do Postgres (SECURITY DEFINER, respeitando RLS)
Supabase (Postgres) — RPCs determinísticas
   ↓
Gemini API (Function Calling) — só interpreta, nunca calcula
   ↓
Edge Function monta a resposta final, persiste no histórico
   ↓
Navegador renderiza
```

**Princípio inegociável do projeto inteiro**: números importantes (financeiro, vendas, estoque, score,
etc.) são sempre calculados de forma determinística no Postgres. O Gemini nunca inventa nem recalcula
esses números — só interpreta e explica o que a RPC já calculou. Isso foi validado manualmente, número
por número, contra as telas reais do ERP durante a implementação (ver histórico de commits da Fase 1).

O Gemini **nunca** tem acesso direto ao Supabase, nunca recebe a Service Role Key, e nunca executa
INSERT/UPDATE/DELETE — só SELECT, via RPCs read-only.

---

## 2. Edge Function — `supabase/functions/ai-analyst/index.ts`

Um único arquivo, ~460 linhas. Fluxo de uma requisição:

1. Valida `Authorization: Bearer <jwt>` — sem isso, 401.
2. Busca o profile do usuário (tabela `profiles`) — usado hoje só pra confirmar que existe, não há
   restrição por role ainda (qualquer usuário autenticado com perfil válido pode usar).
3. Checa a feature flag `company_settings.ai_module_enabled` — se `false`, recusa com 503.
4. Checa rate limit interno (ver seção 9).
5. Lê `question`, `mode` (`'company'` ou `'general'`), `conversation_id` (opcional) do body.
6. Se `conversation_id` foi passado: carrega a conversa (RLS garante que só carrega se for do próprio
   usuário) e as últimas `AI_CONTEXT_MESSAGE_LIMIT` mensagens como contexto.
7. Entra no **loop de ferramentas** (até `MAX_TOOL_ROUNDS` rodadas): chama o `aiProvider.generate(...)`,
   se ele pedir uma tool, executa e devolve o resultado, repete. Para quando ele responder só com texto.
8. Persiste a conversa (cria na 1ª mensagem, nunca antes) e as duas mensagens (user + model) em
   `ai_messages`.
9. Grava o log de consumo em `ai_usage_logs` (fire-and-forget — nunca derruba a resposta).

### Camada `AIProvider`

```
AIProvider (interface)
   └── GeminiProvider (implementação atual)
```

O loop de ferramentas fala só com `aiProvider.generate(contents, systemPrompt, tools)`, que devolve um
formato genérico (`{ functionCallPart, text, usage }`). Trocar de provedor no futuro = escrever uma nova
classe implementando essa interface e trocar a linha `const aiProvider: AIProvider = new GeminiProvider();`
— nada mais no arquivo precisa mudar.

---

## 3. Ferramentas (tools) disponíveis — modo Empresa

| Tool | RPC associada | O que faz | Aceita parâmetros? |
|---|---|---|---|
| `get_financial_summary` | `get_financial_summary(p_from, p_to)` | Receita, despesa, saldo em contas, contas a pagar/receber em aberto | `from`, `to` (YYYY-MM-DD) |
| `get_sales_summary` | `get_sales_summary(p_from, p_to)` | Pedidos entregues, faturamento, ticket médio, pacotes vendidos, clientes novos | `from`, `to` |
| `get_inventory_status` | `get_inventory_status()` | Estoque atual (kg), consumo médio diário, cobertura em dias, produtos abaixo do mínimo | nenhum — sempre reflete "agora" |
| `get_inactive_customers` | `get_inactive_customers(p_min_days, p_limit)` | Clientes ativos sem comprar há mais de N dias | `min_days` (padrão 30) |
| `get_production_summary` | `get_production_summary(p_from, p_to)` | Produção total, média diária, capacidade das máquinas, % de utilização | `from`, `to` |
| `get_company_health` | `get_company_health()` | Score de saúde (0-100), 5 dimensões, comparação com mês anterior | nenhum |

**Modo Geral não recebe nenhuma tool** — a lista simplesmente não é enviada ao Gemini nesse modo. Isso é
uma decisão arquitetural (no código, não uma instrução de prompt), então não depende do modelo "decidir
não usar" — ele fisicamente não tem acesso.

### Migrations (ordem de execução, `supabase/migrations/`)

| Arquivo | O que cria |
|---|---|
| `000_fix_profiles_privilege_escalation.sql` | Trigger de segurança (não é da IA — achado durante a auditoria da Fase 0) |
| `001` a `004`, `009` | As 5 RPCs de dados (financeiro, vendas, estoque, clientes, produção) |
| `005_ai_conversations.sql` | Tabelas `ai_conversations`/`ai_messages` + RLS + trigger de `updated_at` |
| `006_get_company_health.sql` | Score de saúde (depende das RPCs anteriores já existirem) |
| `007_ai_usage_logs.sql` | Log de consumo |
| `008_ai_feature_flag.sql` | Coluna `ai_module_enabled` em `company_settings` |
| `010_ai_saved_prompts_and_pinned.sql` | Atalhos + conversas fixadas |

---

## 4. Modelo Gemini e secrets

- **Modelo**: configurável via secret `GEMINI_MODEL` (Edge Functions → Secrets no Supabase). Valor atual:
  `gemini-3.5-flash` (GA, estável — não é preview). **Nunca hardcode o nome do modelo em outro lugar do
  código** — só existe essa uma constante (`GEMINI_MODEL`) lendo do secret.
- **Secrets necessários** (Supabase → Edge Functions → Secrets):
  - `GEMINI_API_KEY` — chave da API do Google AI Studio.
  - `GEMINI_MODEL` — nome do modelo (ex: `gemini-3.5-flash`).
  - `SUPABASE_URL`, `SUPABASE_ANON_KEY` — já vêm automáticos (reservados), não precisa configurar.
- **Secrets do GitHub** (Settings → Secrets → Actions, pro deploy automático):
  - `SUPABASE_ACCESS_TOKEN` — token de acesso pessoal do Supabase.
  - `SUPABASE_PROJECT_REF` — `iknqqrwhtfnenuynemve`.

⚠️ Modelos do Gemini são descontinuados com alguma frequência (já aconteceu uma vez nesta implementação —
`gemini-2.5-flash` foi bloqueado pra chaves novas). Se o chat começar a dar erro 404 do Gemini, o primeiro
lugar a checar é se o modelo configurado em `GEMINI_MODEL` ainda está disponível.

---

## 5. Tabelas da IA e RLS

| Tabela | Função | RLS |
|---|---|---|
| `ai_conversations` | Uma linha por conversa (`title`, `mode`, `pinned`, `updated_at`, `deleted_at`) | Só o dono (`user_id = auth.uid()`) lê/escreve |
| `ai_messages` | Uma linha por mensagem (`role`, `content`, `metadata`) | Só acessível se a conversa-mãe for do usuário |
| `ai_usage_logs` | Log de cada chamada (tokens, duração, status, tools usadas) | Dono lê os próprios; admin lê todos |
| `ai_saved_prompts` | Atalhos salvos pelo usuário (`title`, `prompt`, `mode`) | Só o dono |

**Diferença importante em relação ao resto do ERP**: as tabelas operacionais (pedidos, clientes,
financeiro, etc.) são compartilhadas entre toda a equipe (`auth.role() = 'authenticated'` já basta pra
ler). As tabelas de IA são **privadas por usuário**, de propósito — conversa de IA é dado pessoal, ninguém
deve ver o histórico de chat de outra pessoa, nem sendo admin (exceto `ai_usage_logs`, que admin pode ver
todo, pensando numa futura tela de consumo agregado).

---

## 6. Histórico e contexto

- **Criação da conversa**: só acontece depois da 1ª resposta bem-sucedida — nunca ao clicar "+ Nova
  conversa" sozinho (evita lixo no banco).
- **Título automático**: heurística simples por palavra-chave (`generateTitle()` na Edge Function) —
  **sem chamada extra ao Gemini**, pra ficar econômico.
- **Contexto enviado ao Gemini**: só as últimas `AI_CONTEXT_MESSAGE_LIMIT` (hoje: 10) mensagens da
  conversa — não a conversa inteira. Só o texto final de cada turno é reenviado, não as idas-e-vindas
  internas de chamada de ferramenta.
- **Regra de atualidade**: o histórico serve só como contexto conversacional. Se uma pergunta pede o
  estado ATUAL de algo, o Gemini é instruído a chamar a ferramenta de novo, nunca reaproveitar um valor
  antigo do histórico como se ainda fosse válido.
- **Modo travado por conversa**: o modo (Empresa/Geral) é decidido na criação da conversa e não pode
  mudar depois — evita uma conversa que começou sem acesso a dado nenhum ganhar acesso no meio do caminho.

---

## 7. Score de Saúde da Empresa

Calculado 100% em SQL (`get_company_health()`), reaproveitando as outras RPCs — nunca duplica a lógica.

**Pesos atuais**: Financeiro 30% | Vendas 25% | Produção 15% | Estoque 15% | Clientes 15%.

Cada dimensão tem sua própria fórmula (ver comentários no arquivo
`supabase/migrations/006_get_company_health.sql`). Resumo:
- **Financeiro**: resultado positivo/negativo + liquidez (saldo vs. contas a pagar).
- **Vendas**: volume de pedidos entregues no mês.
- **Produção**: utilização de capacidade — faixa saudável é 40-90% (nem ocioso, nem sobrecarregado).
- **Estoque**: cobertura em dias (mesmo limiar visual já usado no card do Início: <3 dias = crítico).
- **Clientes**: proporção de clientes inativos (>30 dias sem comprar) sobre o total ativo.

**Comparação com o mês anterior**: só Financeiro e Vendas são recalculados de verdade pro mês passado
(as RPCs aceitam período). Estoque, Clientes e Produção usam o valor **atual** nos dois lados da
comparação, porque não existe snapshot histórico salvo desses três ainda — isso está documentado no
próprio campo `data_coverage_note` que a função retorna, e explicado na interface (tooltip "sobre a
comparação"). Se um dia quiser um score histórico de verdade nesses 3, vai precisar de uma tabela de
snapshot diário/mensal — não existe hoje.

---

## 8. Logs de consumo (`ai_usage_logs`)

Gravado a cada chamada (sucesso ou falha), com: `tokens` (vem pronto do `usageMetadata` da própria
resposta do Gemini, nunca calculado por nós), `model`, `duration_ms`, `tools_used`, `status`
(`success` / `error` / `rate_limited_internal` / `rate_limited_gemini`), `error_message`.

Existe um resumo simples (sem gráfico) em **Configurações → Inteligência (Analista IA)**, só com os
números dos últimos 7 dias. Não existe dashboard elaborado — ficou deliberadamente pra depois, se algum
dia fizer falta.

---

## 9. Rate limit

Dois níveis, com mensagens **diferentes** pro usuário (importante pra diagnóstico — já causaram confusão
um com o outro antes de eu separar as mensagens):

1. **Interno** (`isRateLimited()`, em memória): 15 requisições/minuto por usuário. Simples `Map` dentro
   da própria Edge Function — **não é 100% preciso** se houver múltiplas instâncias da function rodando
   ao mesmo tempo (Deno/Supabase pode escalar horizontalmente). Avaliado e decidido **não migrar** pra
   algo persistente por enquanto — o volume de uso atual não justifica a complexidade extra. Revisitar se
   o uso crescer bastante (múltiplos usuários simultâneos regularmente).
2. **Do próprio Gemini** (free tier): a API do Google tem seu próprio limite por minuto. Detectado via
   HTTP 429 na chamada ao Gemini, propagado como `RateLimitError`.

---

## 10. Como adicionar uma nova tool

Exemplo hipotético: "análise de margem por produto".

1. **Investigue a lógica real primeiro.** Se já existe uma tela no ERP calculando algo parecido, ache a
   função JS exata e leia como ela calcula. Nunca invente uma fórmula nova sem checar se já existe uma
   "fonte da verdade" no frontend.
2. **Crie a RPC** em `supabase/migrations/0XX_get_algo.sql`, seguindo o padrão das existentes:
   - `SECURITY DEFINER`, `SET search_path = public`.
   - `IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;` no início.
   - Filtra `deleted_at IS NULL` em toda tabela que tiver essa coluna (esquecer isso já causou um bug
     real — ver histórico de commits da validação da Fase 1).
   - `REVOKE ALL ... FROM PUBLIC; GRANT EXECUTE ... TO authenticated;` no final.
3. **Valide a RPC contra a tela real** antes de conectar no Gemini — rode manualmente no SQL Editor
   (simulando um usuário autenticado, ver seção 12) e compare número por número com o que a tela do ERP
   mostra pro mesmo período. Só depois de bater 100%, prossiga.
4. **Adicione ao array `COMPANY_TOOLS`** na Edge Function, com uma `description` clara (é isso que o
   Gemini usa pra decidir quando chamar) e o schema de `parameters`.
5. **Conecte no `runTool()`** — um `if (name === "get_algo") { ... supabase.rpc("get_algo", {...}) ... }`.
6. **(Opcional) Adicione ao score de saúde** se fizer sentido como uma dimensão — mas isso exige
   redistribuir os pesos com justificativa documentada, não só reduzir tudo arbitrariamente.
7. **(Opcional) Adicione ao `generateTitle()`** uma palavra-chave pro título automático reconhecer o
   assunto.
8. **(Opcional) Adicione ao motor de sugestões** (`getAssistantSuggestions()` no frontend) se fizer
   sentido sugerir isso proativamente quando algum limiar for cruzado.
9. Faça deploy (ver seção 12) e teste de verdade no chat.

---

## 11. Como testar uma nova tool (ou qualquer mudança na Edge Function)

Como não há acesso direto ao ambiente de produção fora do próprio app, o jeito de testar uma RPC
isoladamente é simular um usuário autenticado no SQL Editor do Supabase:

```sql
SET LOCAL request.jwt.claims = '{"sub":"<uuid-do-usuario>","role":"authenticated"}';
SET LOCAL role authenticated;
SELECT get_algo('2026-08-01', '2026-08-31');
```

Compare o resultado com o que a tela correspondente do ERP mostra pro mesmo período, campo por campo.
Só depois disso teste a Edge Function de verdade, mandando uma pergunta no chat que deveria usar essa
tool, e conferindo:
1. Nos **Logs da Edge Function** (Supabase → Edge Functions → ai-analyst → Logs): qual tool foi escolhida
   e com quais argumentos.
2. Na **resposta do chat**: os números batem com a RPC testada isoladamente?
3. Em `ai_usage_logs`: o registro foi gravado com `status='success'`?

---

## 12. Como fazer deploy

O deploy é automático via GitHub Actions, mas em **duas partes separadas**:

1. **Frontend** (`index.html`): `git push` → workflow "Deploy GitHub Pages" já existente.
2. **Edge Function**: `git push` (se algo em `supabase/functions/**` mudou) → workflow
   "Deploy Supabase Edge Functions" (`.github/workflows/deploy-functions.yml`).

**Migrations SQL não são deployadas automaticamente** — isso é deliberado (rodar SQL em produção sem
revisão manual seria arriscado). Toda migration precisa ser copiada e rodada manualmente no SQL Editor do
Supabase, na ordem correta (ver tabela da seção 3). Depois de rodar, é boa prática confirmar que a função
foi salva de verdade com:

```sql
SELECT prosrc FROM pg_proc WHERE proname = 'nome_da_funcao';
```

(Já aconteceu de um `CREATE OR REPLACE` não "pegar" de verdade numa sessão do SQL Editor — vale sempre
confirmar antes de assumir que está atualizado.)

---

## 13. Onde estão as coisas no `index.html`

O módulo inteiro fica dentro de `<section class="view" id="view-inteligencia">`. Principais blocos de JS
(busque por esses nomes de função no arquivo):

- `renderCompanyHealth()` — Visão Geral (score + pontos de atenção).
- `getAssistantSuggestions()` / `buildFollowUps()` — motor de sugestões, 100% determinístico.
- `sendAIQuestion()` / `appendAIMessage()` / `updateAIMessage()` — o chat em si.
- `renderAIConversationsList()` / `openAIConversation()` — histórico.
- `loadAIModuleSettings()` / `renderAIUsageSummary()` — feature flag e consumo, em Configurações.

---

## 14. O que foi deliberadamente NÃO implementado (e por quê)

- **Structured Outputs**: o chat em texto livre já resolve bem; não adicionar complexidade só porque
  estava no roadmap original.
- **Resumo executivo automático ao abrir a tela**: sempre sob demanda (botão), pra não gastar Free Tier
  à toa.
- **Narrar alertas determinísticos pelo Gemini**: os Pontos de Atenção aparecem em texto direto, sem
  passar pelo Gemini — mais barato e mais confiável que gastar uma chamada só pra "traduzir" um número
  numa frase.
- **Feedback 👍👎**: sem destino útil pros dados ainda (nenhum lugar consome isso).
- **Cancelar geração em andamento**: o backend já persiste a conversa ao terminar a chamada; cancelar só
  a espera do frontend seria enganoso (a resposta apareceria depois mesmo assim, ao reabrir a conversa).
- **Renomear atalho**: só criar/excluir por ora.
- **Sumarização automática de conversas longas**: o limite de 10 mensagens de contexto já resolve bem no
  volume atual de uso.
- **Score histórico real de Estoque/Clientes/Produção**: precisaria de uma tabela de snapshot que não
  existe — hoje a comparação com o mês anterior desses 3 usa o valor atual nos dois lados (documentado).
