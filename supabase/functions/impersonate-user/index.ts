// supabase/functions/impersonate-user/index.ts
//
// "Entrar como outro usuário" — SÓ pro proprietário (e-mail fixo, checado aqui no servidor, nunca
// confiando em nada vindo do frontend). Usa a Service Role Key do Supabase (auth.admin), que NUNCA
// pode existir no navegador — é exatamente por isso que essa função precisa existir: pra encapsular o
// uso dessa chave num lugar seguro, com uma trava de autorização rígida na frente dela.
//
// Fluxo: valida quem está chamando (JWT normal) -> confirma que é o e-mail exato do proprietário ->
// usa a Service Role Key pra gerar um magic link de login pro usuário-alvo -> registra no log de
// auditoria -> devolve o link pro frontend navegar até ele (isso efetivamente loga como o outro usuário).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") || "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const OWNER_EMAIL = "rafaeldiasdeoliveira29@gmail.com";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });

  try {
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
    if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
      console.error("impersonate-user: secrets faltando");
      return json({ error: "Função não configurada." }, 500);
    }

    // 1) Valida quem está chamando (JWT normal do usuário, sem privilégio nenhum ainda)
    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.replace("Bearer ", "");
    if (!jwt) return json({ error: "Não autenticado." }, 401);

    const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: callerData, error: callerErr } = await callerClient.auth.getUser(jwt);
    if (callerErr || !callerData?.user) return json({ error: "Sessão inválida." }, 401);

    // 2) TRAVA CRÍTICA — só o e-mail exato do proprietário passa daqui. Isso é verificado no servidor,
    // não é uma instrução de UI que dá pra contornar escondendo um botão.
    if ((callerData.user.email || "").trim().toLowerCase() !== OWNER_EMAIL) {
      console.error("impersonate-user: tentativa de uso por usuário não autorizado:", callerData.user.email);
      return json({ error: "Você não tem permissão para usar esse recurso." }, 403);
    }

    const body = await req.json().catch(() => ({}));
    const targetUserId = body?.target_user_id;
    if (!targetUserId || typeof targetUserId !== "string") {
      return json({ error: "Usuário alvo não informado." }, 400);
    }
    if (targetUserId === callerData.user.id) {
      return json({ error: "Você já está logado como você mesmo." }, 400);
    }

    // 3) Só a partir daqui usamos a Service Role Key — o mínimo de código possível trabalhando com ela.
    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data: targetUser, error: targetErr } = await adminClient.auth.admin.getUserById(targetUserId);
    if (targetErr || !targetUser?.user?.email) {
      console.error("impersonate-user: usuário alvo não encontrado", targetErr?.message);
      return json({ error: "Usuário não encontrado." }, 404);
    }

    const { data: linkData, error: linkErr } = await adminClient.auth.admin.generateLink({
      type: "magiclink",
      email: targetUser.user.email,
    });
    if (linkErr || !linkData?.properties?.action_link) {
      console.error("impersonate-user: erro ao gerar link", linkErr?.message);
      return json({ error: "Erro ao gerar acesso." }, 500);
    }

    // 4) Log de auditoria — nunca pular isso numa funcionalidade dessas.
    await adminClient.from("impersonation_logs").insert({
      owner_id: callerData.user.id,
      target_user_id: targetUserId,
      target_email: targetUser.user.email,
    });
    console.log("impersonate-user: acesso concedido pra", targetUser.user.email, "por", callerData.user.email);

    return json({ action_link: linkData.properties.action_link });
  } catch (e) {
    console.error("impersonate-user: erro não tratado", e instanceof Error ? e.message : String(e));
    return json({ error: "Não foi possível concluir a operação." }, 500);
  }
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}
