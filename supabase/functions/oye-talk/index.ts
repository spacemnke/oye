// A pass into the voice room two linked people share, for hold to talk.
// Send { to: "<their id>" } when you start talking: it tells their Oye (a row in oye_talks) and
// returns your pass. Their Oye sends { to: "<your id>", answer: true } to get a pass to listen.
//
// Secrets (shared with Talkie): LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET.
// The caller is checked against Supabase Auth here, so the gateway's JWT check is off.
import { createClient } from "npm:@supabase/supabase-js@2";

const LIVEKIT_URL = (Deno.env.get("LIVEKIT_URL") ?? "").trim();
const LIVEKIT_API_KEY = (Deno.env.get("LIVEKIT_API_KEY") ?? "").trim();
const LIVEKIT_API_SECRET = (Deno.env.get("LIVEKIT_API_SECRET") ?? "").trim();

/** How long a pass is good for. */
const PASS_SECONDS = 10 * 60;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A LiveKit access token: an HS256 JWT signed with the API secret. */
async function liveKitToken(claims: Record<string, unknown>): Promise<string> {
  const enc = new TextEncoder();
  const header = base64url(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const payload = base64url(enc.encode(JSON.stringify(claims)));
  const key = await crypto.subtle.importKey("raw", enc.encode(LIVEKIT_API_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`${header}.${payload}`)));
  return `${header}.${payload}.${base64url(signature)}`;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (!LIVEKIT_URL || !LIVEKIT_API_KEY || !LIVEKIT_API_SECRET) return json({ error: "LiveKit isn't set up" }, 503);

  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "Not signed in" }, 401);

  // Act as the person asking, so row-level security decides what they can see and write.
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await supabase.auth.getUser(jwt);
  const user = userData?.user;
  if (userError || !user) return json({ error: "Not signed in" }, 401);

  let to = "";
  let answer = false;
  try {
    const body = await req.json();
    to = String(body?.to ?? "").toLowerCase();
    answer = body?.answer === true;
  } catch {
    return json({ error: "Send { to }" }, 400);
  }
  if (!/^[0-9a-f-]{36}$/.test(to) || to === user.id) return json({ error: "Send { to }" }, 400);

  // Only someone you're linked to. Your own links are all you can read.
  const { data: link, error: linkError } = await supabase
    .from("oye_links").select("friend").eq("owner", user.id).eq("friend", to).maybeSingle();
  if (linkError) return json({ error: linkError.message }, 500);
  if (!link) return json({ error: "Not one of your people" }, 403);

  if (answer) {
    // Listening: they must have started talking to you in the last minute.
    const since = new Date(Date.now() - 60_000).toISOString();
    const { data: talk } = await supabase
      .from("oye_talks").select("id").eq("caller", to).eq("callee", user.id).gt("created_at", since).limit(1).maybeSingle();
    if (!talk) return json({ error: "Nobody is talking to you" }, 403);
  } else {
    const { error: talkError } = await supabase.from("oye_talks").insert({ caller: user.id, callee: to });
    if (talkError) return json({ error: talkError.message }, 500);
  }

  const { data: me } = await supabase.from("oye_people").select("name").eq("id", user.id).maybeSingle();
  const room = "oye-" + [user.id.toLowerCase(), to].sort().join("_");
  const now = Math.floor(Date.now() / 1000);
  const token = await liveKitToken({
    iss: LIVEKIT_API_KEY,
    sub: user.id,
    name: me?.name ?? "Oye",
    nbf: now - 10,
    exp: now + PASS_SECONDS,
    video: { room, roomJoin: true, canPublish: true, canSubscribe: true, canPublishData: false },
  });
  return json({ url: LIVEKIT_URL, token, room });
});
