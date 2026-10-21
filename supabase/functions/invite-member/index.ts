// Deploy as a Supabase Edge Function named "invite-member".
// Required Edge Function secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
// The caller must be an authenticated active Sama Nafa administrator.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Set ALLOWED_ORIGIN to the exact deployed app origin, e.g. https://your-app.vercel.app.
const allowedOrigin = Deno.env.get("ALLOWED_ORIGIN") ?? "";
const corsHeaders = {
  "Access-Control-Allow-Origin": allowedOrigin,
  "Vary": "Origin",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  if (origin && (!allowedOrigin || origin !== allowedOrigin)) {
    return new Response("Origin not allowed.", { status: 403 });
  }
  if (req.method === "OPTIONS") {
    if (!allowedOrigin) return new Response("Server CORS configuration is incomplete.", { status: 500 });
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return reply({ error: "Method not allowed." }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return reply({ error: "Sign-in required." }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) return reply({ error: "Server configuration is incomplete." }, 500);

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const token = authorization.slice("Bearer ".length);
  const { data: userData, error: userError } = await adminClient.auth.getUser(token);
  if (userError || !userData.user) return reply({ error: "Your session is invalid. Please sign in again." }, 401);

  const { data: caller, error: callerError } = await adminClient
    .from("profiles")
    .select("role,status")
    .eq("id", userData.user.id)
    .maybeSingle();
  if (callerError || caller?.role !== "admin" || caller?.status !== "active") {
    return reply({ error: "Only an active administrator can invite members." }, 403);
  }

  let body: { email?: string; display_name?: string };
  try {
    body = await req.json();
  } catch {
    return reply({ error: "Please send valid JSON." }, 400);
  }

  const email = String(body.email ?? "").trim().toLowerCase();
  const displayName = String(body.display_name ?? "").trim();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) {
    return reply({ error: "Enter a valid email address." }, 400);
  }
  if (displayName.length < 2 || displayName.length > 80) {
    return reply({ error: "Member name must contain 2–80 characters." }, 400);
  }

  const { count, error: countError } = await adminClient
    .from("profiles")
    .select("id", { count: "exact", head: true })
    .eq("status", "active");
  if (countError) return reply({ error: "Could not verify member capacity." }, 500);
  if ((count ?? 0) >= 25) return reply({ error: "Sama Nafa has reached its 25-member limit. Suspend or deactivate a member before inviting another." }, 409);

  const { data: invited, error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(email, {
    data: { display_name: displayName },
  });
  if (inviteError) return reply({ error: inviteError.message }, 400);

  // The database trigger creates a member-only profile; never set role from client input.
  return reply({
    ok: true,
    message: "Invitation sent. The member must use the email invitation to activate their account.",
    member: { id: invited.user.id, email: invited.user.email, display_name: displayName },
  }, 201);
});
