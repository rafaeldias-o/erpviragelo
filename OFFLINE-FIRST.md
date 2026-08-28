# Offline-First — Documentação técnica

Referência de arquitetura do modo offline do ERP. Escrito pra você (ou uma sessão futura do Claude)
entender o que existe, o que falta, e como testar antes de estender mais.

Última atualização: 28/08/2026.

---

## 1. Estado atual — o que funciona offline hoje

| Recurso | Status |
|---|---|
| Abrir o app sem internet, ver dados da última sincronização | ✅ |
| Indicador de conectividade (Online/Offline/Sincronizando) no cabeçalho | ✅ |
| Criar/editar **Clientes** offline | ✅ |
| Criar/editar **Contas Financeiras** offline | ✅ |
| Mudar **status de Pedido** offline (exceto marcar como "Entregue") | ✅ |
| Marcar pedido como "Entregue" (baixa estoque + gera receita) | ❌ Continua exigindo internet — de propósito |
| Estoque, Produção, Financeiro (lançamentos) | ❌ Ainda não conectados |
| Analista IA, cálculo de rota/frete, geocodificação | ❌ Nunca vão funcionar offline (dependem de API externa) — comportamento esperado |

**Nenhum teste real de dispositivo foi feito ainda.** Tudo abaixo foi validado com testes de lógica isolada (Node.js, simulando os cenários), não com o navegador de verdade desconectado da internet. Ver seção 6 antes de confiar nisso em produção.

---

## 2. Arquitetura

```
Navegador
  ├── IndexedDB (viragelo-cache-<uuid-do-usuário>)
  │     ├── clients, orders, stock_items, ... (cópia local de cada tabela do loadAll())
  │     ├── _meta (timestamp da última sincronização)
  │     ├── _outbox (fila de operações pendentes)
  │     └── _conflicts (reservado, não usado ainda)
  │
  ├── loadAll() — decide ler do Supabase ou do IndexedDB
  ├── syncOutboxOp() — envia operações pendentes quando volta a internet
  └── updateSyncBadge() — mostra o estado no cabeçalho
```

### Banco isolado por usuário
Nome do IndexedDB inclui o UUID do usuário logado. Trocar de conta no mesmo navegador nunca lê o cache
de outra pessoa — são bancos fisicamente diferentes. Apagado no logout (por segurança).

### Conectividade real, não só `navigator.onLine`
`checkRealConnectivity()` faz uma consulta leve de verdade ao Supabase (com timeout de 4s) antes de
decidir se está online — cobre o caso de wifi conectado numa rede sem internet de fato.

---

## 3. Fila de sincronização (`_outbox`)

Cada operação pendente:
```js
{
  id,              // também é a chave de idempotência
  entity,          // 'clients' | 'financial_accounts' | 'orders'
  op,              // 'insert' | 'update'
  recordId,        // id do registro afetado
  payload,         // dados a enviar
  baseUpdatedAt,   // updated_at conhecido no momento da edição (usado na checagem de conflito)
  createdAt, attempts, status, errorMessage, lastAttemptAt, nextRetryAt
}
```

Status possíveis: `pending`, `syncing`, `synced`, `conflict`, `rejected`, `error`.

### Idempotência
Todas as tabelas usam UUID. IDs de registro **novo** são gerados no navegador
(`crypto.randomUUID()`), então reenviar a mesma operação (conexão caiu antes da confirmação chegar) usa
`upsert` por id — nunca cria um segundo registro.

### Concorrência otimista
Antes de aplicar uma edição, compara o `updated_at` capturado no momento da edição offline com o que
está no servidor agora. Se mudou (outro dispositivo/usuário mexeu nesse meio tempo), marca como
`conflict` em vez de sobrescrever.

**Exceção documentada — pedidos**: `orders.updated_at` não é atualizado explicitamente pelo trigger
`fulfill_order()` ao marcar como entregue, então a checagem genérica de `updated_at` sozinha não seria
confiável aqui. Por isso, pedidos têm uma checagem extra: sempre confere o `status` atual no servidor
antes de aplicar qualquer mudança offline, bloqueando se o pedido já foi marcado como "entregue" nesse
meio tempo.

### Backoff
Erros temporários (não conflito, não rejeição) tentam de novo com backoff exponencial + jitter, teto de
5 minutos. Erros de permissão (RLS, código `42501`) são marcados como `rejected` direto — não adianta
tentar de novo sozinho.

### Gatilhos de sincronização
Evento `online` do navegador, a cada 30s enquanto online, manualmente (clicando no badge), e sempre que
qualquer `loadAll()` confirma que está online (o que já acontece o tempo todo no uso normal do app).

---

## 4. Como adicionar uma entidade nova à escrita offline

Exemplo: "categorias financeiras".

1. **Confirme que é seguro**: cadastro mestre puro, sem efeito colateral em outra tabela (estoque,
   financeiro, trigger). Se tiver, pare e pense — é provavelmente uma entidade pra uma fase mais tardia,
   como aconteceu com fornecedores (acoplado a estoque) e "marcar pedido como entregue" (trigger de
   negócio).
2. **Confirme que a tabela tem `updated_at`** (necessário pra concorrência otimista funcionar de
   verdade).
3. Adicione 1 linha em `OFFLINE_ENTITY_CONFIG`:
   ```js
   financial_categories: { table:'financial_categories', label:'categoria financeira', notFoundMsg:'...', conflictMsg:'...' },
   ```
4. Na função de salvar existente (ex: `saveFinCategory`), adicione o branch `if(!appIsOnline){ ... }` no
   mesmo padrão de `saveClientDetail`/`saveFinAccount`: gera UUID se novo, lê o registro atual do
   IndexedDB (se edição), grava localmente com `putRecordToLocalDB`, atualiza `state.*` em memória,
   enfileira com `enqueueOutboxOp`.
5. Se existir uma função de mapeamento `db → state` reutilizável (tipo `mapClientRow`), use ela nos dois
   fluxos. Se não existir ainda, extraia uma antes de duplicar a lógica.
6. Teste a lógica isoladamente (Node, sem IndexedDB de verdade) antes de testar no navegador — mesmo
   padrão usado nas 3 entidades já conectadas.

---

## 5. O que foi deliberadamente deixado de fora (e por quê)

- **Fornecedores**: não têm tela própria — são criados embutidos no formulário de item de estoque, que
  mexe com quantidade (categoria de risco mais alta). Precisa de um formulário próprio antes de conectar
  à escrita offline com segurança.
- **Produtos/Estoque**: mesmo problema — o formulário de item de estoque mistura metadado (nome,
  categoria, preço) com quantidade numa gravação só. Separar isso é trabalho de UI antes de ser trabalho
  de sincronização.
- **Marcar pedido como "Entregue"**: baixa estoque e gera receita via trigger no banco — efeito
  impossível de simular localmente sem arriscar os números ficarem errados até sincronizar. Continua
  exigindo internet, com mensagem clara pro usuário.
- **Pedidos, produção, financeiro (lançamentos) em geral**: correspondem à Fase 4 do plano original —
  alto risco, ainda não iniciada.
- **Resolução de conflito com merge automático**: hoje é binário (manter local / usar servidor). Merge
  campo-a-campo (só quando campos diferentes mudaram) não foi implementado.
- **Testes end-to-end reais**: tudo foi validado com lógica isolada, nunca com o navegador de verdade
  desconectado da internet. Ver seção 6.

---

## 6. Roteiro de teste — faça isso antes de eu continuar

Isso ainda não foi confirmado por ninguém, incluindo eu. São passos concretos, na ordem:

1. Abre o ERP **online**, deixa carregar normal, confirma que o badge mostra "🟢 Online — tudo
   sincronizado".
2. **Desliga a internet.** Recarrega a página (F5). O app deve continuar abrindo, com dados. Badge deve
   virar "🔴 Offline — dados de HH:MM".
3. Ainda offline, edita um cliente existente (muda o telefone, por exemplo) e salva. Deve salvar na hora,
   sem travar. Confere se aparece "🕓 pendente" do lado do nome na lista.
4. Ainda offline, cria um cliente novo. Mesma checagem.
5. Ainda offline, muda o status de um pedido de "Confirmado" pra "Separando". Deve funcionar.
6. Ainda offline, tenta marcar um pedido como "Entregue" — deve **recusar** com uma mensagem clara
   pedindo internet (esse é o comportamento esperado, não um bug).
7. **Religa a internet.** Em até 30 segundos (ou clicando no badge), deve sincronizar sozinho. Badge
   volta pra "🟢 Online — tudo sincronizado".
8. Confere no Supabase (SQL Editor) que:
   - O cliente editado tem o telefone novo.
   - Existe **só um** cliente novo (não dois) — o teste mais importante de idempotência.
   - O pedido está com status "Separando".
9. Fecha a aba, reabre. Os dados devem continuar lá, sem duplicar nada.

Se algum desses passos falhar, me manda o que aconteceu (print, ou o que apareceu na tela) — corrijo
antes de continuarmos adicionando mais escopo em cima de uma base que ainda não foi comprovada na
prática.
