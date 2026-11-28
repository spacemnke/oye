// Oye's files, on Cloudflare: a Worker in front of an R2 bucket.
//
// What it does:
//   - Takes files from the app in parts (so a 1 GB file never has to fit in memory or survive one
//     long request), for a friend ("p/<sender>/<recipient>/<id>") or for anyone with a link
//     ("s/<sender>/<random>").
//   - Hands a friend's file only to the two people it's between.
//   - Serves the page behind a file link, and the page behind an invite link, to people who don't
//     have Oye yet.
//
// Who someone is, and who they're linked to, is asked of Supabase with the person's own sign-in,
// so the rules there (row-level security) stay the only rules. Nothing here is secret: the
// Supabase key is the public one the app already ships with.
//
// Bindings: FILES (R2 bucket), SUPABASE_URL, SUPABASE_KEY, INSTALLER (where the app downloads from).
// The bucket deletes everything under p/ and s/ after three days; this also refuses anything older.

const KEEP_MS = 3 * 24 * 60 * 60 * 1000;
const LARGEST = 1024 * 1024 * 1024; // 1 GB a file
const PART = 8 * 1024 * 1024; // every part but the last
const ALLOWANCE = 5 * LARGEST; // what one person can have waiting at once
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (error) {
      return json({ error: "Something went wrong" }, 500);
    }
  },
};

async function route(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;

  if (path === "/api/upload/start" && method === "POST") return startUpload(request, env, url);
  if (path === "/api/upload/part" && method === "PUT") return uploadPart(request, env, url);
  if (path === "/api/upload/finish" && method === "POST") return finishUpload(request, env);
  if (path === "/api/file" && method === "GET") return privateFile(request, env, url);

  const share = path.match(/^\/f\/([A-Za-z0-9_-]{20,64})(\/download|\/report)?$/);
  if (share) {
    if (!share[2] && method === "GET") return sharePage(request, env, share[1]);
    if (share[2] === "/download" && method === "GET") return shareDownload(request, env, share[1]);
    if (share[2] === "/report" && method === "POST") return shareReport(env, share[1]);
  }

  const join = path.match(/^\/join\/([A-Za-z0-9]{8})$/);
  if (join && method === "GET") return joinPage(request, env, join[1].toUpperCase(), url.searchParams.get("from"));

  if (path === "/" && method === "GET") return homePage(env);
  return page("Not here", `<h1>Nothing here</h1><p class="muted">This link doesn't go anywhere.</p>`, 404);
}

// MARK: Who's asking

/** The signed-in person, as Supabase sees them, or null. */
async function whoIs(request, env) {
  const auth = request.headers.get("Authorization") || "";
  if (!/^Bearer\s+\S+/i.test(auth)) return null;
  const response = await fetch(env.SUPABASE_URL + "/auth/v1/user", {
    headers: { apikey: env.SUPABASE_KEY, Authorization: auth },
  });
  if (!response.ok) return null;
  const user = await response.json();
  const id = String(user?.id || "").toLowerCase();
  return UUID.test(id) ? { id, auth } : null;
}

/** A read from Oye's tables as that person, so they see only what they're allowed to. */
async function rows(env, who, query) {
  const response = await fetch(env.SUPABASE_URL + "/rest/v1/" + query, {
    headers: { apikey: env.SUPABASE_KEY, Authorization: who.auth },
  });
  if (!response.ok) return [];
  const body = await response.json();
  return Array.isArray(body) ? body : [];
}

/** How much this person has waiting on the server right now. */
async function waiting(env, id) {
  let total = 0;
  for (const prefix of ["p/" + id + "/", "s/" + id + "/"]) {
    let cursor;
    for (let pages = 0; pages < 5; pages++) {
      const list = await env.FILES.list({ prefix, cursor, limit: 1000 });
      for (const object of list.objects) total += object.size;
      if (!list.truncated) break;
      cursor = list.cursor;
    }
  }
  return total;
}

// MARK: Uploading

async function startUpload(request, env, url) {
  const who = await whoIs(request, env);
  if (!who) return json({ error: "Not signed in" }, 401);
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Send what you're uploading" }, 400);
  }
  const size = Number(body?.size);
  if (!Number.isFinite(size) || size <= 0) return json({ error: "Send the size" }, 400);
  if (size > LARGEST) return json({ error: "too big" }, 413);
  if ((await waiting(env, who.id)) + size > ALLOWANCE) return json({ error: "too much waiting" }, 429);

  const name = clean(body?.name, 200) || "File";
  const type = /^[\w.+-]+\/[\w.+-]+$/.test(String(body?.type || "")) ? String(body.type) : "application/octet-stream";
  const extension = String(body?.extension || "").toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 12);
  const to = String(body?.to || "").toLowerCase();

  let key;
  let link = null;
  const about = { name, size: String(size) };
  if (to) {
    // For a friend: only someone you're linked to.
    if (!UUID.test(to) || to === who.id) return json({ error: "Send who it's for" }, 400);
    const linked = await rows(env, who, "oye_links?select=friend&owner=eq." + who.id + "&friend=eq." + to);
    if (linked.length === 0) return json({ error: "Not one of your people" }, 403);
    key = "p/" + who.id + "/" + to + "/" + crypto.randomUUID() + (extension ? "." + extension : "");
  } else {
    // For anyone with the link.
    const me = await rows(env, who, "oye_people?select=name&id=eq." + who.id);
    about.from = clean(me[0]?.name, 32) || "Someone";
    const invite = String(body?.invite || "").toUpperCase();
    if (/^[A-Z0-9]{8}$/.test(invite)) about.invite = invite;
    const random = crypto.getRandomValues(new Uint8Array(12));
    key = "s/" + who.id + "/" + hex(random);
    link = url.origin + "/f/" + shareToken(who.id, random);
  }

  const upload = await env.FILES.createMultipartUpload(key, {
    httpMetadata: { contentType: type },
    customMetadata: about,
  });
  return json({ key, upload: upload.uploadId, part: PART, link });
}

// The upload's id is long, random and only ever given to the person who started it, so holding it
// is the proof for the parts and the finish.
async function uploadPart(request, env, url) {
  const key = url.searchParams.get("key") || "";
  const uploadId = url.searchParams.get("upload") || "";
  const number = Number(url.searchParams.get("n"));
  const length = Number(request.headers.get("Content-Length"));
  if (!ourKey(key) || !uploadId || !Number.isInteger(number) || number < 1 || number > 200) return json({ error: "Bad part" }, 400);
  if (!request.body || !Number.isFinite(length) || length <= 0 || length > PART) return json({ error: "Bad part size" }, 400);
  try {
    const part = await env.FILES.resumeMultipartUpload(key, uploadId).uploadPart(number, request.body);
    return json({ partNumber: part.partNumber, etag: part.etag });
  } catch {
    return json({ error: "That upload isn't open" }, 404);
  }
}

async function finishUpload(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Send the parts" }, 400);
  }
  const key = String(body?.key || "");
  const uploadId = String(body?.upload || "");
  const parts = Array.isArray(body?.parts) ? body.parts : [];
  if (!ourKey(key) || !uploadId || parts.length === 0 || parts.length > 200) return json({ error: "Bad finish" }, 400);
  let object;
  try {
    object = await env.FILES.resumeMultipartUpload(key, uploadId).complete(
      parts.map((part) => ({ partNumber: Number(part.partNumber), etag: String(part.etag) })),
    );
  } catch {
    return json({ error: "That upload isn't open" }, 404);
  }
  if (object.size > LARGEST) {
    await env.FILES.delete(key);
    return json({ error: "too big" }, 413);
  }
  return json({ key, size: object.size });
}

// MARK: A friend's file

async function privateFile(request, env, url) {
  const who = await whoIs(request, env);
  if (!who) return json({ error: "Not signed in" }, 401);
  const key = url.searchParams.get("key") || "";
  const parts = key.split("/");
  // p/<sender>/<recipient>/<file>: only those two.
  if (parts.length !== 4 || parts[0] !== "p" || !UUID.test(parts[1]) || !UUID.test(parts[2]) || !/^[\w.-]+$/.test(parts[3])) {
    return json({ error: "Bad file" }, 400);
  }
  if (who.id !== parts[1] && who.id !== parts[2]) return json({ error: "Not yours" }, 403);
  const object = await fresh(env, key);
  if (!object) return json({ error: "expired" }, 410);
  return new Response(object.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Length": String(object.size),
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

/** The object, unless it's gone or past its three days (then it's deleted here and now). */
async function fresh(env, key, headOnly = false) {
  const object = headOnly ? await env.FILES.head(key) : await env.FILES.get(key);
  if (!object) return null;
  if (Date.now() - object.uploaded.getTime() > KEEP_MS) {
    await env.FILES.delete(key);
    return null;
  }
  return object;
}

// MARK: A link for anyone

function shareToken(id, random) {
  const bytes = new Uint8Array(28);
  bytes.set(unhex(id.replaceAll("-", "")), 0);
  bytes.set(random, 16);
  let text = "";
  for (const byte of bytes) text += String.fromCharCode(byte);
  return btoa(text).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function shareKey(token) {
  try {
    const text = atob(token.replaceAll("-", "+").replaceAll("_", "/"));
    if (text.length !== 28) return null;
    const bytes = Uint8Array.from(text, (c) => c.charCodeAt(0));
    const id = hex(bytes.slice(0, 16));
    const uuid = [id.slice(0, 8), id.slice(8, 12), id.slice(12, 16), id.slice(16, 20), id.slice(20)].join("-");
    return "s/" + uuid + "/" + hex(bytes.slice(16));
  } catch {
    return null;
  }
}

async function sharePage(request, env, token) {
  const key = shareKey(token);
  const object = key ? await fresh(env, key, true) : null;
  if (!object) return gonePage(env);
  const about = object.customMetadata || {};
  const from = about.from || "Someone";
  const name = about.name || "File";
  const left = KEEP_MS - (Date.now() - object.uploaded.getTime());
  const hours = Math.max(1, Math.round(left / 3600000));
  const until = hours >= 36 ? Math.round(hours / 24) + " days" : hours === 1 ? "an hour" : hours + " hours";
  const mac = onMac(request);
  const body = `
    <h1>${esc(from)} sent you a file</h1>
    <div class="file">
      <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4"/></svg>
      <div><div class="name">${esc(name)}</div><div class="muted small">${esc(sizeLabel(object.size))}</div></div>
    </div>
    <a class="button" href="/f/${token}/download">Download</a>
    <p class="muted small">This link stops working in ${esc(until)}.</p>
    <hr>
    ${pitch(env, mac, about.invite ? { code: about.invite, from } : null)}
    <form method="post" action="/f/${token}/report" class="report">
      <button type="submit">Report this file</button>
    </form>`;
  return page(from + " sent you a file", body);
}

async function shareDownload(request, env, token) {
  const key = shareKey(token);
  const object = key ? await fresh(env, key) : null;
  if (!object) return gonePage(env);
  const name = (object.customMetadata || {}).name || "File";
  return new Response(object.body, {
    headers: {
      // Always a download, never shown in the browser, whatever the file claims to be.
      "Content-Type": "application/octet-stream",
      "Content-Length": String(object.size),
      "Content-Disposition": "attachment; filename*=UTF-8''" + encodeURIComponent(name).replace(/['()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase()),
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
      "X-Robots-Tag": "noindex",
    },
  });
}

/** Anyone holding the link can take the file down. A note of what it was stays for the owner of Oye. */
async function shareReport(env, token) {
  const key = shareKey(token);
  const object = key ? await env.FILES.head(key) : null;
  if (object) {
    const note = { key, at: new Date().toISOString(), size: object.size, about: object.customMetadata || {} };
    await env.FILES.put("reports/" + Date.now() + "-" + key.split("/")[2], JSON.stringify(note), {
      httpMetadata: { contentType: "application/json" },
    });
    await env.FILES.delete(key);
  }
  return page("Reported", `<h1>Thanks, it's gone</h1><p class="muted">That file has been taken down and the link no longer works.</p>`);
}

function gonePage(env) {
  const body = `
    <h1>This link has expired</h1>
    <p class="muted">Files sent with Oye are kept for three days. Ask whoever sent it to send it again.</p>
    <hr>
    ${pitch(env, true, null)}`;
  return page("This link has expired", body, 410);
}

// MARK: An invite

function joinPage(request, env, code, fromParam) {
  const from = clean(fromParam, 32);
  const mac = onMac(request);
  const title = from ? from + " invited you to Oye" : "You're invited to Oye";
  const body = `
    <h1>${esc(title)}</h1>
    <p class="muted">Oye puts your people in your Mac's menu bar. Text them, hold a button to talk, or drop them a file.</p>
    <hr>
    ${pitch(env, mac, { code, from: from || "them" }, true)}`;
  return page(title, body);
}

function homePage(env) {
  const body = `
    <h1>Oye</h1>
    <p class="muted">Your people, in your Mac's menu bar. Text them, hold a button to talk, or drop them a file.</p>
    <hr>
    ${pitch(env, true, null, true)}`;
  return page("Oye", body);
}

/** Getting Oye, and (with an invite) linking up with whoever sent this. */
function pitch(env, mac, invite, plain = false) {
  const intro = plain ? "" : `<p class="muted">Sent with Oye, which puts your people in your Mac's menu bar. Text them, hold a button to talk, or drop them a file.</p>`;
  if (!mac) {
    return `${intro}
      <p><strong>Oye is a Mac app.</strong> Open this page on your Mac to get it.</p>`;
  }
  const add = invite
    ? `<li>Come back to this page and click <a href="oye://join/${invite.code}">Add ${esc(invite.from)}</a>, or paste this code into Oye: <code>${invite.code}</code></li>`
    : "";
  return `${intro}
    <ol>
      <li><a class="button light" href="${esc(env.INSTALLER)}">Get Oye for Mac</a></li>
      <li>Open Oye from your menu bar and tell it your name.</li>
      ${add}
    </ol>
    <p class="muted small">Oye is in early testing and needs macOS 14 or later. macOS will block the installer the first time: open System Settings, Privacy &amp; Security, and choose Open Anyway.</p>`;
}

// MARK: Pages

function page(title, body, status = 200) {
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${esc(title)}</title>
<style>
  :root { --ink: #171513; --muted: #6B655D; --line: #E7E3DD; --soft: #F3F1EE; --accent: #4B45F0; }
  * { box-sizing: border-box; }
  body { margin: 0; background: #fff; color: var(--ink); font: 16px/1.5 Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; -webkit-font-smoothing: antialiased; }
  main { max-width: 440px; margin: 0 auto; padding: 56px 24px 72px; }
  .mark { display: flex; align-items: center; gap: 8px; font-weight: 700; margin-bottom: 40px; }
  h1 { font-size: 30px; line-height: 1.15; letter-spacing: -0.02em; margin: 0 0 16px; }
  p { margin: 0 0 16px; }
  .muted { color: var(--muted); }
  .small { font-size: 14px; }
  hr { border: 0; border-top: 1px solid var(--line); margin: 32px 0; }
  .file { display: flex; align-items: center; gap: 12px; padding: 14px 16px; border: 1px solid var(--line); border-radius: 16px; background: var(--soft); margin: 0 0 16px; }
  .file .name { font-weight: 600; word-break: break-word; }
  .button { display: inline-block; background: var(--ink); color: #fff; text-decoration: none; font-weight: 600; padding: 12px 22px; border-radius: 999px; margin: 0 0 12px; }
  .button.light { background: #fff; color: var(--ink); border: 1px solid var(--line); margin: 0; }
  a { color: var(--accent); }
  ol { padding-left: 20px; margin: 0 0 16px; }
  li { margin: 0 0 14px; padding-left: 4px; }
  code { font: 600 15px ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--soft); padding: 2px 6px; border-radius: 6px; }
  .report { margin-top: 40px; }
  .report button { background: none; border: 0; padding: 0; color: var(--muted); font: inherit; font-size: 13px; text-decoration: underline; cursor: pointer; }
</style>
</head>
<body>
<main>
  <div class="mark">
    <svg viewBox="0 0 20 18" width="22" height="20" aria-hidden="true"><circle cx="8" cy="10" r="5.5" fill="none" stroke="#171513" stroke-width="2.4"/><circle cx="16" cy="4.5" r="2.5" fill="#4B45F0"/></svg>
    Oye
  </div>
  ${body}
</main>
</body>
</html>`;
  return new Response(html, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
      "X-Robots-Tag": "noindex",
    },
  });
}

// MARK: Small things

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function ourKey(key) {
  return /^(p\/[0-9a-f-]{36}\/[0-9a-f-]{36}\/[\w.-]{1,64}|s\/[0-9a-f-]{36}\/[0-9a-f]{24})$/.test(key);
}

function onMac(request) {
  const agent = request.headers.get("User-Agent") || "";
  return /Macintosh/.test(agent) && !/iPhone|iPad|Android/.test(agent);
}

function clean(text, most) {
  return String(text ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, most);
}

function esc(text) {
  return String(text ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function hex(bytes) {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function unhex(text) {
  const bytes = new Uint8Array(text.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(text.slice(i * 2, i * 2 + 2), 16);
  return bytes;
}

function sizeLabel(bytes) {
  if (bytes < 1000) return bytes + " bytes";
  if (bytes < 1000 * 1000) return Math.round(bytes / 1000) + " KB";
  if (bytes < 1000 * 1000 * 1000) return (bytes / 1e6).toFixed(bytes < 1e7 ? 1 : 0) + " MB";
  return (bytes / 1e9).toFixed(2) + " GB";
}
