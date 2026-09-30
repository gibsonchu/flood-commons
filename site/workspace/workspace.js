/**
 * Flood Commons Workspace.
 *
 * Staff sign in with their own Flood Commons (Supabase Auth) account. Every
 * read and write goes through the database's own access rules with the
 * signer's token: members see records in their scope, contributors can save
 * drafts, editors publish, admins also manage people. The page holds no
 * privileges of its own; it uses only the publishable key.
 *
 * Services (FSS) and answers & resources (FRS) are edited as flat rows defined
 * in fc.js, the same columns as the CSV template and column guide.
 */
import {
  TERMS, STATUSES, AUDIENCES, columnsFor, labelOf, fromRow, applyRow, toRow, validate, sameRecord, normChoice, today, sixMonths,
} from "./fc.js";

const $ = (s, el = document) => el.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const NAMES = {
  FSS: { one: "service", many: "Services", add: "Add a service" },
  FRS: { one: "answer or resource", many: "Answers & resources", add: "Add an answer or resource" },
  FMS: { one: "clip", many: "Clips" },
};
const GROUPS = { visibility: "Visibility", basics: "Basics", where: "Where", who: "Who it's for & topics", contact: "Contact", details: "Details", source: "Source & review" };
const STATUS_LABEL = { published: "Published", draft: "Draft", hidden: "Hidden" };
const AUDIENCE_LABEL = { public: "Public", internal: "AI-only" };
const SORTS = { new: "Last updated (newest)", old: "Last updated (oldest)", az: "Name (A–Z)", za: "Name (Z–A)" };
const DEPTHS = { ankle: "Ankle-deep", knee: "Knee-deep", waist: "Waist-deep", above_waist: "Above the waist", unknown: "Not sure" };
const WHERE = { street: "Street", highway: "Highway", subway: "Subway", other: "Somewhere else (neighborhood only)" };
const CLIPS_URL = "https://flood-clips.vercel.app/";

const cfg = await (await fetch("/config.json", { cache: "no-cache" })).json();
let session = JSON.parse(sessionStorage.getItem("fc_workspace_session") || "null");
let me = null;
let data = { items: [], inbox: [], removals: [] };
let view = "FSS";
const lists = Object.fromEntries(["FSS", "FRS", "FMS"].map((s) => [s, { q: "", status: "", type: "", audience: "", sort: "new" }]));
const ui = { importStd: "FSS", importFile: null, importRows: null, importResult: null, ignored: [], showHistory: false };
const canPublish = () => me && ["editor", "admin"].includes(me.role);
const isAdmin = () => me?.role === "admin";

// ---------- auth ----------
function saveSession(s) {
  session = s && {
    access_token: s.access_token,
    refresh_token: s.refresh_token,
    expires_at: Number(s.expires_at) || Math.floor(Date.now() / 1000) + Number(s.expires_in || 3600),
    email: s.user?.email ?? session?.email ?? null,
  };
  session ? sessionStorage.setItem("fc_workspace_session", JSON.stringify(session)) : sessionStorage.removeItem("fc_workspace_session");
}
async function gotrue(path, body, { method = "POST", auth = false } = {}) {
  const headers = { apikey: cfg.key, "Content-Type": "application/json" };
  if (auth) headers.Authorization = `Bearer ${session.access_token}`;
  const r = await fetch(`${cfg.url}/auth/v1${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const j = r.status === 204 ? {} : await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.msg || j.error_description || j.message || "Sign-in could not be completed.");
  return j;
}
async function accessToken() {
  if (!session) throw Object.assign(new Error("Please sign in."), { auth: true });
  if (session.expires_at * 1000 - Date.now() < 60_000) {
    try {
      saveSession(await gotrue("/token?grant_type=refresh_token", { refresh_token: session.refresh_token }));
    } catch {
      saveSession(null);
      throw Object.assign(new Error("Your session ended. Sign in again."), { auth: true });
    }
  }
  return session.access_token;
}
const redirectTo = () => location.origin + location.pathname;

$("#password-form").onsubmit = async (e) => {
  e.preventDefault();
  const f = e.target;
  const msg = $("#login-msg");
  msg.className = "form-msg";
  msg.textContent = "Signing in…";
  try {
    saveSession(await gotrue("/token?grant_type=password", { email: f.email.value.trim(), password: f.password.value }));
    f.reset();
    msg.textContent = "";
    await start();
  } catch (err) {
    msg.className = "form-msg bad";
    msg.textContent = /invalid/i.test(err.message) ? "That email and password don't match." : err.message;
  }
};
$("#link-form").onsubmit = async (e) => {
  e.preventDefault();
  const kind = e.submitter?.value || "magic";
  const email = e.target.email.value.trim();
  const msg = $("#login-msg");
  msg.className = "form-msg";
  try {
    const q = `?redirect_to=${encodeURIComponent(redirectTo())}`;
    if (kind === "reset") await gotrue(`/recover${q}`, { email });
    else await gotrue(`/otp${q}`, { email, create_user: true });
    msg.className = "form-msg ok";
    msg.textContent = kind === "reset" ? "If that email has an account, we've sent a link to choose a new password." : "Check your email for a sign-in link. It opens this page.";
  } catch (err) {
    msg.className = "form-msg bad";
    msg.textContent = err.message;
  }
};
$("#new-password-form").onsubmit = async (e) => {
  e.preventDefault();
  const msg = $(".form-msg", e.target);
  try {
    await accessToken();
    await gotrue("/user", { password: e.target.password.value }, { method: "PUT", auth: true });
    e.target.reset();
    await start();
    flash("Password saved.");
  } catch (err) {
    msg.className = "form-msg bad";
    msg.textContent = err.message;
  }
};
async function signOut() {
  if (session) await gotrue("/logout", null, { auth: true }).catch(() => {});
  saveSession(null);
  me = null;
  show("login");
}
$("#sign-out").onclick = signOut;
$("#nm-out").onclick = signOut;

function show(which) {
  for (const id of ["login", "set-password", "not-member", "app"]) $("#" + id).hidden = id !== which;
  $("#who").hidden = which !== "app";
}

// Links from sign-in and password emails return here with tokens in the hash.
function takeHashSession() {
  if (!location.hash.includes("access_token=") && !location.hash.includes("error")) return null;
  const p = new URLSearchParams(location.hash.slice(1));
  history.replaceState(null, "", location.pathname);
  if (p.get("error")) {
    $("#login-msg").className = "form-msg bad";
    $("#login-msg").textContent = p.get("error_description") || "That link didn't work. It may have expired; request a new one.";
    return null;
  }
  saveSession({ access_token: p.get("access_token"), refresh_token: p.get("refresh_token"), expires_at: p.get("expires_at"), expires_in: p.get("expires_in") });
  return p.get("type");
}

// ---------- API ----------
async function rest(path, { method = "GET", body } = {}) {
  let r;
  try {
    r = await fetch(`${cfg.url}/rest/v1/${path}`, {
      method,
      headers: { apikey: cfg.key, Authorization: `Bearer ${await accessToken()}`, "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch (err) {
    if (err.auth) show("login");
    throw err;
  }
  const j = r.status === 204 ? null : await r.json().catch(() => null);
  if (r.status === 401) {
    saveSession(null);
    show("login");
    $("#login-msg").textContent = "Your session ended. Sign in again.";
  }
  if (!r.ok) throw new Error(j?.message || `Something went wrong (${r.status}).`);
  return j;
}
const rpc = (fn, args = {}) => rest(`rpc/${fn}`, { method: "POST", body: args });

async function refresh() {
  const [recs, inbox, removals] = await Promise.all([
    rest("fc_workspace_records?select=id,status,audience,latest_revision,has_unpublished_changes,document,updated_at&limit=10000"),
    rest("fc_clip_inbox?select=*&order=created_at.desc&limit=500"),
    rest("fc_removal_inbox?select=*&order=created_at.desc&limit=500"),
  ]);
  data.items = recs
    .filter((r) => r.document?.standard)
    .map((r) => ({
      id: r.id,
      standard: r.document.standard,
      record: r.document,
      status: r.status,
      audience: r.audience,
      rev: r.latest_revision,
      pendingChanges: r.has_unpublished_changes,
      updated_at: r.updated_at,
      row: r.document.standard === "FMS" ? null : toRow(r.document, { status: r.status === "excluded" ? "draft" : r.status, audience: r.audience }),
    }));
  data.inbox = inbox;
  data.removals = removals;
  const live = (s) => data.items.filter((i) => i.standard === s && i.status !== "excluded").length;
  for (const s of ["FSS", "FRS", "FMS"]) $("#c-" + s).textContent = live(s);
  $("#c-trash").textContent = data.items.filter((i) => i.status === "excluded").length || "";
  $("#c-inbox").textContent = data.inbox.filter((s) => s.status === "pending").length || "";
  $("#c-removals").textContent = data.removals.filter((q) => q.status === "open").length || "";
}
function flash(msg, bad = false) {
  const f = $("#flash");
  f.textContent = msg;
  f.className = "flash" + (bad ? " bad" : "");
  f.hidden = false;
  clearTimeout(flash.t);
  flash.t = setTimeout(() => (f.hidden = true), 7000);
}
async function act(fn, ok) {
  try {
    await fn();
    await refresh();
    render();
    if (ok) flash(ok);
  } catch (err) {
    flash(err.message, true);
    await refresh().catch(() => {});
    render();
  }
}

// ---------- start ----------
async function start() {
  me = await rpc("fc_my_membership").catch(() => null);
  if (!me?.active) {
    $("#nm-email").textContent = session?.email || "your email";
    return show("not-member");
  }
  $("#me").textContent = session?.email || "";
  $("#myRole").textContent = me.role;
  for (const el of document.querySelectorAll("[data-admin]")) el.hidden = !isAdmin();
  show("app");
  await refresh();
  go(new URLSearchParams(location.hash.slice(1)).get("v") || "FSS", true);
}

// ---------- navigation ----------
function saveHash() {
  const p = new URLSearchParams({ v: view });
  const l = lists[view];
  if (l) for (const [k, val] of Object.entries(l)) if (val && !(k === "sort" && val === "new")) p.set(k, val);
  history.replaceState(null, "", "#" + p);
}
function go(v, fromHash = false) {
  view = v;
  if (fromHash && lists[v]) {
    const p = new URLSearchParams(location.hash.slice(1));
    for (const k of Object.keys(lists[v])) if (p.has(k)) lists[v][k] = p.get(k);
    if (!SORTS[lists[v].sort]) lists[v].sort = "new";
  }
  saveHash();
  for (const b of document.querySelectorAll("[data-view]")) b.dataset.view === v ? b.setAttribute("aria-current", "page") : b.removeAttribute("aria-current");
  render();
}
$(".tabs").onclick = (e) => {
  const b = e.target.closest("[data-view]");
  if (b) go(b.dataset.view);
};
function render() {
  const el = $("#view");
  const views = { FSS: () => listView("FSS"), FRS: () => listView("FRS"), FMS: clipsView, inbox: inboxView, removals: removalsView, import: importView, trash: trashView, people: () => '<p class="sub">Loading…</p>', log: () => '<p class="sub">Loading…</p>' };
  el.innerHTML = (views[view] || views.FSS)();
  if (view === "import") wireImport();
  if (view === "people") peopleView();
  if (view === "log") logView();
}

// ---------- shared bits ----------
const fmtDate = (s) => (s ? new Date(s.length === 10 ? `${s}T12:00:00` : s).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }) : "");
const byName = (a, b) => a.record.title.localeCompare(b.record.title, "en", { sensitivity: "base", numeric: true });
const byUpdated = (a, b) => (a.updated_at ?? "").localeCompare(b.updated_at ?? "");
const SORTERS = { az: byName, za: (a, b) => byName(b, a), old: (a, b) => byUpdated(a, b) || byName(a, b), new: (a, b) => byUpdated(b, a) || byName(a, b) };
function stateControls(i) {
  const status = canPublish()
    ? `<select class="state ${i.status}" data-status-of="${i.id}" aria-label="Status of ${esc(i.record.title)}">${STATUSES.map((k) => `<option value="${k}" ${i.status === k ? "selected" : ""}>${STATUS_LABEL[k]}</option>`).join("")}</select>`
    : `<span class="pill state ${i.status}">${STATUS_LABEL[i.status]}</span>`;
  const audience = canPublish()
    ? `<select class="state ${i.audience}" data-audience-of="${i.id}" aria-label="Who can see ${esc(i.record.title)}">${AUDIENCES.map((k) => `<option value="${k}" ${i.audience === k ? "selected" : ""}>${AUDIENCE_LABEL[k]}</option>`).join("")}</select>`
    : `<span class="pill state ${i.audience}">${AUDIENCE_LABEL[i.audience]}</span>`;
  const pending = i.pendingChanges ? `<span class="pill info" title="The public version is older. Publish to update it.">Unpublished changes</span>` : "";
  return `<div class="state-stack">${status}${audience}${pending}</div>`;
}
function publicNote(i) {
  const s = i.record.service;
  if (!s) return "";
  if (["closed", "historical", "temporarily_unavailable"].includes(s.availability)) return "Not on Local Help: " + s.availability.replaceAll("_", " ");
  if (s.deadline && s.deadline < today()) return "Not on Local Help: deadline passed";
  if (s.review_due && s.review_due < today()) return "Review overdue";
  return "";
}

// ---------- lists (services, answers) ----------
const topicLabel = (k) => TERMS.topic.find((t) => t.key === k)?.label ?? k;
const typesOf = (i) => (i.standard === "FSS" ? [i.record.service.type].filter(Boolean) : i.record.categories);
const typeLabel = (std, k) => (std === "FSS" ? k.replaceAll("_", " ").replace(/^./, (c) => c.toUpperCase()) : topicLabel(k));

function listView(std) {
  const l = lists[std];
  const q = l.q.toLowerCase();
  const all = data.items.filter((i) => i.standard === std && i.status !== "excluded");
  const searched = all.filter((i) => !q || Object.values(i.row).join(" ").toLowerCase().includes(q));
  const keep = (i, skip) => (skip === "status" || !l.status || i.status === l.status) && (skip === "type" || !l.type || typesOf(i).includes(l.type)) && (skip === "audience" || !l.audience || i.audience === l.audience);
  const counts = { status: {}, type: {}, audience: {} };
  for (const i of searched) {
    if (keep(i, "status")) counts.status[i.status] = (counts.status[i.status] ?? 0) + 1;
    if (keep(i, "audience")) counts.audience[i.audience] = (counts.audience[i.audience] ?? 0) + 1;
    if (keep(i, "type")) for (const t of typesOf(i)) counts.type[t] = (counts.type[t] ?? 0) + 1;
  }
  if (l.type && !counts.type[l.type]) counts.type[l.type] = 0;
  const items = searched.filter((i) => keep(i)).sort(SORTERS[l.sort]);
  const filtered = Boolean(l.q || l.status || l.type || l.audience);
  const typeName = std === "FSS" ? "Type" : "Topic";
  const rows = items
    .map((i) => {
      const r = i.row;
      const note = publicNote(i);
      const sub = std === "FSS" ? [r.service_area, r.phone].filter(Boolean).join(" · ") : [r.resource_type === "faq_answer" ? "Quick answer" : r.resource_type.replaceAll("_", " "), r.audiences.replaceAll(" | ", ", ")].filter(Boolean).join(" · ");
      return `<tr>
        <td><div class="name">${esc(r.title)}</div><div class="sub">${esc(sub)}</div>${note ? `<span class="pill warn">${esc(note)}</span>` : ""}</td>
        <td>${esc(typesOf(i).map((t) => typeLabel(std, t)).join(", "))}</td>
        <td>${stateControls(i)}</td>
        <td class="sub">${esc(fmtDate(i.updated_at))}</td>
        <td><div class="row-actions"><button class="btn" data-edit="${i.id}">Edit</button>${canPublish() ? `<button class="btn danger" data-trash="${i.id}" aria-label="Move ${esc(r.title)} to trash">Trash</button>` : ""}</div></td></tr>`;
    })
    .join("");
  const nameSort = l.sort === "az" ? "ascending" : l.sort === "za" ? "descending" : "none";
  const dateSort = l.sort === "old" ? "ascending" : l.sort === "new" ? "descending" : "none";
  const arrow = (dir) => (dir === "ascending" ? " ↑" : dir === "descending" ? " ↓" : "");
  const typeOptions = Object.keys(counts.type).sort((a, b) => typeLabel(std, a).localeCompare(typeLabel(std, b)));
  const opt = (map, k, label) => `<option value="${k}" ${l[map] === k ? "selected" : ""}>${label} (${counts[map][k] ?? 0})</option>`;
  return `<div class="bar">
      <input type="search" id="list-q" placeholder="Search ${NAMES[std].many.toLowerCase()}…" value="${esc(l.q)}" aria-label="Search">
      <span class="spacer"></span>
      <button class="btn" data-go="import">Upload CSV</button>
      <button class="btn primary" data-new="${std}">+ ${NAMES[std].add}</button>
    </div>
    <div class="bar filters-bar">
      <label class="inline">Sort<select id="list-sort">${Object.entries(SORTS).map(([k, v]) => `<option value="${k}" ${l.sort === k ? "selected" : ""}>${v}</option>`).join("")}</select></label>
      <label class="inline">${typeName}<select id="list-type"><option value="">All</option>${typeOptions.map((t) => `<option value="${esc(t)}" ${l.type === t ? "selected" : ""}>${esc(typeLabel(std, t))} (${counts.type[t]})</option>`).join("")}</select></label>
      <label class="inline">Status<select id="list-status"><option value="">All</option>${STATUSES.map((k) => opt("status", k, STATUS_LABEL[k])).join("")}</select></label>
      <label class="inline">Seen by<select id="list-audience"><option value="">Everyone</option>${AUDIENCES.map((k) => opt("audience", k, AUDIENCE_LABEL[k])).join("")}</select></label>
      <span class="spacer"></span>
      <span class="sub" aria-live="polite">Showing ${items.length} of ${all.length}</span>
      ${filtered ? `<button class="link-btn" data-clear-filters>Clear filters</button>` : ""}
    </div>
    ${items.length ? `<table class="table"><thead><tr>
      <th aria-sort="${nameSort}"><button class="th-sort" data-sort="${l.sort === "az" ? "za" : "az"}">${std === "FSS" ? "Service" : "Title"}${arrow(nameSort)}</button></th>
      <th>${typeName}</th><th>Status &amp; visibility</th>
      <th aria-sort="${dateSort}"><button class="th-sort" data-sort="${l.sort === "new" ? "old" : "new"}">Updated${arrow(dateSort)}</button></th>
      <th></th></tr></thead><tbody>${rows}</tbody></table>`
      : `<div class="empty"><h2>No ${NAMES[std].many.toLowerCase()} match.</h2><p>${filtered ? "Try clearing the filters." : "Add one to get started."}</p>${filtered ? `<button class="btn primary" data-clear-filters>Clear filters</button>` : ""}</div>`}`;
}

// ---------- published clips ----------
function clipsView() {
  const l = lists.FMS;
  const q = l.q.toLowerCase();
  const all = data.items.filter((i) => i.standard === "FMS" && i.status !== "excluded");
  const items = all.filter((i) => (!q || JSON.stringify([i.record.title, i.record.places, i.record.event]).toLowerCase().includes(q)) && (!l.status || i.status === l.status)).sort(SORTERS[l.sort]);
  const pending = data.inbox.filter((s) => s.status === "pending").length;
  return `<div class="bar">
      <input type="search" id="list-q" placeholder="Search clips…" value="${esc(l.q)}" aria-label="Search clips">
      <label class="inline">Status<select id="list-status"><option value="">All</option>${STATUSES.map((k) => `<option value="${k}" ${l.status === k ? "selected" : ""}>${STATUS_LABEL[k]}</option>`).join("")}</select></label>
      <span class="spacer"></span>
      ${pending ? `<button class="btn primary" data-go="inbox">Review ${pending} new submission${pending === 1 ? "" : "s"}</button>` : ""}
      <a class="btn" href="${CLIPS_URL}" target="_blank" rel="noreferrer">Open Flood Clips ↗</a>
    </div>
    ${items.length ? `<table class="table"><thead><tr><th>Clip</th><th>Where</th><th>Status &amp; visibility</th><th>Filmed</th><th></th></tr></thead><tbody>${items
      .map((i) => {
        const d = i.record;
        const loc = (d.tags.find((t) => t.startsWith("location:")) || "location:other").slice(9);
        const depth = (d.tags.find((t) => t.startsWith("depth:")) || "depth:unknown").slice(6);
        return `<tr><td><div class="name">${esc(d.title)}</div><div class="sub">${esc(DEPTHS[depth] || "")}${d.media?.creator ? ` · ${esc(d.media.creator)}` : ""}</div></td>
          <td>${esc(d.places?.[0]?.name || "")}<div class="sub">${esc((WHERE[loc] || "").split(" (")[0])}</div></td>
          <td>${stateControls(i)}</td><td class="sub">${esc(fmtDate(d.media?.capture_date))}</td>
          <td><div class="row-actions"><a class="btn" href="${CLIPS_URL}?clip=${i.id}" target="_blank" rel="noreferrer">View ↗</a><a class="btn" href="${esc(d.source.url)}" target="_blank" rel="noreferrer">Original ↗</a>${canPublish() ? `<button class="btn danger" data-trash="${i.id}">Trash</button>` : ""}</div></td></tr>`;
      })
      .join("")}</tbody></table>`
      : `<div class="empty"><h2>No clips yet.</h2><p>Approved submissions from Flood Clips appear here.</p>${pending ? `<button class="btn primary" data-go="inbox">Review submissions</button>` : ""}</div>`}`;
}

// ---------- clip inbox ----------
function embedFor(url) {
  let u;
  try { u = new URL(url); } catch { return null; }
  const host = u.hostname.replace(/^www\.|^m\./, "");
  if (host === "youtu.be") return `https://www.youtube-nocookie.com/embed/${u.pathname.slice(1)}`;
  if (host.endsWith("youtube.com")) { const id = u.searchParams.get("v") || u.pathname.match(/\/(shorts|embed|live)\/([\w-]+)/)?.[2]; return id ? `https://www.youtube-nocookie.com/embed/${id}` : null; }
  if (host.endsWith("instagram.com")) { const m = u.pathname.match(/\/(p|reel|tv)\/([\w-]+)/); return m ? `https://www.instagram.com/${m[1]}/${m[2]}/embed` : null; }
  if (host.endsWith("tiktok.com")) { const id = u.pathname.match(/\/video\/(\d+)/)?.[1]; return id ? `https://www.tiktok.com/embed/v2/${id}` : null; }
  return null;
}
function inboxView() {
  const pending = data.inbox.filter((s) => s.status === "pending");
  const done = data.inbox.filter((s) => s.status !== "pending").slice(0, 30);
  const cards = pending
    .map((s) => {
      const src = embedFor(s.url);
      const opt = (map, cur, disabled = () => false) => Object.entries(map).map(([k, v]) => `<option value="${k}" ${cur === k ? "selected" : ""} ${disabled(k) ? "disabled" : ""}>${esc(v)}</option>`).join("");
      return `<section class="panel"><div class="clip-card">
        <div class="clip-preview">${src ? `<iframe src="${esc(src)}" title="Preview" loading="lazy" allow="encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>` : `<div class="placeholder">No preview for this site.<br><a href="${esc(s.url)}" target="_blank" rel="noreferrer">Open the post ↗</a></div>`}</div>
        <form class="clip-form" data-clip="${s.id}">
          <div class="clip-meta"><span>Submitted ${esc(fmtDate(s.created_at))}</span><a href="${esc(s.url)}" target="_blank" rel="noreferrer">${esc(s.platform)} post ↗</a>${s.creator ? `<span>Posted by <strong>${esc(s.creator)}</strong></span>` : ""}${s.contact_email ? `<span>Submitter: ${esc(s.contact_email)}</span>` : ""}${s.lon != null ? `<span>Pin: ${s.lat}, ${s.lon} (rounded)</span>` : ""}</div>
          <label class="wide">Title<input name="title" placeholder="Leave blank for “${esc((s.storm ? s.storm + " — " : "Flooding — ") + s.place_name)}”"></label>
          <label class="wide">Description<textarea name="summary" rows="2">${esc(s.caption)}</textarea></label>
          <label>Place<input name="place_name" value="${esc(s.place_name)}" required></label>
          <label>Where<select name="location_type">${opt(WHERE, s.location_type, (k) => k !== "other" && s.lon == null)}</select></label>
          <label>Depth<select name="depth">${opt(DEPTHS, s.depth)}</select></label>
          <label>Date filmed<input name="observed_on" type="date" value="${esc(s.observed_on || "")}"></label>
          <label>Storm<input name="storm" value="${esc(s.storm || "")}" placeholder="e.g. Hurricane Ida"></label>
          <label>Alt text<input name="alt_text" placeholder="What the clip shows, for screen readers"></label>
          <div class="clip-actions">${canPublish() ? `<button class="btn good" type="submit" name="do" value="approve">Approve &amp; publish</button><button class="btn danger" type="submit" name="do" value="reject">Reject</button>` : `<span class="sub">An editor needs to approve this.</span>`}</div>
        </form></div></section>`;
    })
    .join("");
  const history = done.length
    ? `<details ${ui.showHistory ? "open" : ""} id="inbox-history"><summary class="sub">Recently reviewed (${done.length})</summary><table class="table"><tbody>${done
        .map((s) => `<tr><td><div class="name">${esc(s.place_name)}</div><div class="sub"><a href="${esc(s.url)}" target="_blank" rel="noreferrer">${esc(s.platform)} post ↗</a></div></td><td><span class="pill ${s.status === "approved" ? "add" : "unchanged"}">${s.status === "approved" ? "Approved" : "Rejected"}</span></td><td class="sub">${esc(fmtDate(s.reviewed_at))}${s.review_note ? ` · ${esc(s.review_note)}` : ""}</td></tr>`)
        .join("")}</tbody></table></details>`
    : "";
  return `<p class="sub">Links residents shared on Flood Clips. Check the original post: that it shows flooding in NYC, and that the place and depth look right. Approving publishes it to the map with credit to the original post.</p>
    ${cards || `<div class="empty"><h2>No new submissions.</h2><p>New clips from <a href="${CLIPS_URL}" target="_blank" rel="noreferrer">Flood Clips</a> show up here.</p></div>`}${history}`;
}

// ---------- removal requests ----------
function removalsView() {
  const open = data.removals.filter((q) => q.status === "open");
  const done = data.removals.filter((q) => q.status !== "open").slice(0, 30);
  const row = (q, actions) => `<tr><td><div class="name">${esc(q.record_title || "(record already removed)")}</div><div class="sub"><a href="${CLIPS_URL}?clip=${q.record_id}" target="_blank" rel="noreferrer">View ↗</a></div></td><td>${esc(q.reason)}${q.contact ? `<div class="sub">From ${esc(q.contact)}</div>` : ""}</td><td class="sub">${esc(fmtDate(q.created_at))}</td><td>${actions}</td></tr>`;
  return `<p class="sub">Requests to take something down, sent from the clip viewer. When a creator asks for their own footage to be removed, take it down.</p>
    ${open.length ? `<table class="table"><thead><tr><th>Record</th><th>Reason</th><th>Received</th><th></th></tr></thead><tbody>${open
      .map((q) => row(q, canPublish() ? `<div class="row-actions"><button class="btn danger" data-removal="${q.id}" data-act="remove">Take it down</button><button class="btn" data-removal="${q.id}" data-act="dismiss">Keep it</button></div>` : `<span class="sub">Editors decide.</span>`))
      .join("")}</tbody></table>` : `<div class="empty"><h2>No open requests.</h2></div>`}
    ${done.length ? `<h3>Resolved</h3><table class="table"><tbody>${done.map((q) => row(q, `<span class="pill ${q.status === "removed" ? "error" : "unchanged"}">${q.status === "removed" ? "Taken down" : "Kept"}</span>${q.note ? `<div class="sub">${esc(q.note)}</div>` : ""}`)).join("")}</tbody></table>` : ""}`;
}

// ---------- trash ----------
function trashView() {
  const items = data.items.filter((i) => i.status === "excluded").sort(SORTERS.new);
  if (!items.length) return `<div class="empty"><h2>Trash is empty.</h2><p>Trashed records land here so they can be restored.</p></div>`;
  return `<table class="table"><thead><tr><th>Record</th><th>Kind</th><th>Updated</th><th></th></tr></thead><tbody>${items
    .map((i) => `<tr><td class="name">${esc(i.record.title)}</td><td>${esc(NAMES[i.standard].one)}</td><td class="sub">${esc(fmtDate(i.updated_at))}</td><td><div class="row-actions">${canPublish() ? `<button class="btn" data-restore="${i.id}">Restore</button>` : ""}</div></td></tr>`)
    .join("")}</tbody></table>`;
}

// ---------- events ----------
$("#view").addEventListener("input", (e) => {
  if (e.target.id === "list-q") {
    lists[view].q = e.target.value;
    saveHash();
    const pos = e.target.selectionStart;
    render();
    const box = $("#list-q");
    box.focus();
    box.setSelectionRange(pos, pos);
  }
});
$("#view").addEventListener("change", (e) => {
  const key = { "list-status": "status", "list-type": "type", "list-sort": "sort", "list-audience": "audience" }[e.target.id];
  if (key) {
    lists[view][key] = e.target.value;
    saveHash();
    render();
    $("#" + e.target.id)?.focus();
  }
  const t = e.target;
  if (t.dataset.statusOf) {
    const to = t.value;
    t.disabled = true;
    act(() => rpc("fc_set_record_status", { record: t.dataset.statusOf, target: to }), { published: "Published. It's live on the next page load.", draft: "Moved to draft. It's no longer public.", hidden: "Hidden. It's no longer public." }[to]);
  }
  if (t.dataset.audienceOf) {
    const to = t.value;
    t.disabled = true;
    act(() => rpc("fc_set_audience", { record: t.dataset.audienceOf, new_audience: to }), to === "public" ? "Now public: shown on Local Help and to the AI when published." : "Now AI-only: hidden from public pages.");
  }
});
$("#view").addEventListener("click", async (e) => {
  const t = e.target.closest("button");
  if (!t) return;
  if (t.dataset.go) return go(t.dataset.go);
  if (t.dataset.new) return openEditor(t.dataset.new);
  if (t.dataset.sort) { lists[view].sort = t.dataset.sort; saveHash(); render(); return $("[data-sort]")?.focus(); }
  if ("clearFilters" in t.dataset) { Object.assign(lists[view], { q: "", status: "", type: "", audience: "" }); saveHash(); return render(); }
  if (t.dataset.edit) return openEditor(view, data.items.find((i) => i.id === t.dataset.edit));
  if (t.dataset.trash) {
    const item = data.items.find((i) => i.id === t.dataset.trash);
    if (!confirm(`Move “${item.record.title}” to the trash? It stops being public. You can restore it from Trash.`)) return;
    return act(() => rpc("fc_set_record_status", { record: item.id, target: "trash", reason: "Trashed in the Workspace" }), "Moved to trash.");
  }
  if (t.dataset.restore) return act(() => rpc("fc_set_record_status", { record: t.dataset.restore, target: "restore" }), "Restored as a draft. Publish it when it's ready.");
  if (t.dataset.removal) {
    const remove = t.dataset.act === "remove";
    const note = prompt(remove ? "Note for the record (optional):" : "Why keep it? (optional)", "");
    if (note === null) return;
    return act(() => rpc("fc_resolve_removal", { request: t.dataset.removal, action: remove ? "remove" : "dismiss", note: note || (remove ? "Removal requested" : "Kept after review") }), remove ? "Taken down." : "Kept. The request is closed.");
  }
});
$("#view").addEventListener("toggle", (e) => { if (e.target.id === "inbox-history") ui.showHistory = e.target.open; }, true);
$("#view").addEventListener("submit", (e) => {
  const f = e.target.closest("form[data-clip]");
  if (!f) return;
  e.preventDefault();
  const id = f.dataset.clip;
  const s = data.inbox.find((x) => x.id === id);
  if (e.submitter?.value === "reject") {
    const note = prompt("Why reject it? (kept for your records)", "Not flooding in NYC");
    if (note === null) return;
    return act(() => rpc("fc_reject_clip", { submission: id, note: note || "Rejected" }), "Rejected.");
  }
  const edits = {};
  for (const k of ["title", "summary", "place_name", "location_type", "depth", "observed_on", "storm", "alt_text"]) {
    const v = f.elements[k].value.trim();
    const orig = { summary: s.caption, place_name: s.place_name, location_type: s.location_type, depth: s.depth, observed_on: s.observed_on, storm: s.storm }[k] ?? "";
    if (v && v !== (orig ?? "")) edits[k] = v;
  }
  for (const b of f.querySelectorAll("button")) b.disabled = true;
  act(() => rpc("fc_approve_clip", { submission: id, edits }), "Approved. It's on the Flood Clips map now.");
});

// ---------- editor ----------
let editing = null;
function fieldHtml(c, std, value, isNew) {
  const id = "f-" + c.key;
  const req = c.required ? ' <span class="req" aria-hidden="true">*</span>' : "";
  const hint = c.help ? `<span class="hint">${esc(c.help)}</span>` : "";
  const wide = c.long || (c.terms && c.list) || ["title", "service_area", "places", "contact_url", "source_url", "document_url", "tags"].includes(c.key);
  if (c.terms && c.list) {
    const chosen = new Set(String(value ?? "").split(/\s*[|;,]\s*/).filter(Boolean));
    const input = `<div class="checks" id="${id}" role="group" aria-label="${esc(labelOf(c, std))}">${TERMS[c.terms].map((t) => `<label><input type="checkbox" name="${c.key}" value="${esc(t.key)}" ${chosen.has(t.key) ? "checked" : ""}>${esc(t.label)}</label>`).join("")}</div>`;
    return `<div class="field wide" data-field="${c.key}"><span>${esc(labelOf(c, std))}${req}</span>${input}<span class="err"></span></div>`;
  }
  let input;
  if (c.terms) {
    const locked = c.key === "status" && !canPublish();
    const options = TERMS[c.terms].filter((t) => !locked || t.key === "draft");
    input = `<select id="${id}" name="${c.key}" ${locked ? "disabled" : ""}>${options.map((t) => `<option value="${esc(t.key)}" ${(value || c.def) === t.key ? "selected" : ""}>${esc(t.label)}</option>`).join("")}</select>`;
    if (locked) input += `<input type="hidden" name="${c.key}" value="draft">`;
  } else if (c.long) {
    input = `<textarea id="${id}" name="${c.key}">${esc(value)}</textarea>`;
  } else {
    const type = c.date ? "date" : c.key === "email" ? "email" : c.key === "phone" ? "tel" : /url/.test(c.key) ? "url" : "text";
    const dl = c.suggest ? ` list="dl-${c.key}"` : "";
    input = `<input id="${id}" name="${c.key}" type="${type}" value="${esc(value)}"${dl}>${c.suggest ? `<datalist id="dl-${c.key}">${c.suggest.map((s) => `<option value="${esc(s)}">`).join("")}</datalist>` : ""}`;
  }
  return `<label class="field ${wide ? "wide" : ""}" data-field="${c.key}" for="${id}"><span>${esc(labelOf(c, std))}${req}</span>${input}${hint}<span class="err"></span></label>`;
}
function openEditor(std, item = null) {
  editing = { std, item, allowDuplicate: false };
  const row = item?.row ?? { status: canPublish() ? "published" : "draft", review_due: std === "FSS" ? sixMonths() : "" };
  $("#editor-title").textContent = item ? `Edit ${NAMES[std].one}` : NAMES[std].add;
  const cols = columnsFor(std);
  let html = Object.keys(GROUPS)
    .map((g) => [g, cols.filter((c) => c.group === g)])
    .filter(([, cs]) => cs.length)
    .map(([g, cs]) => `<fieldset class="fgroup"><legend>${GROUPS[g]}</legend>${cs.map((c) => fieldHtml(c, std, row[c.key], !item)).join("")}</fieldset>`)
    .join("");
  if (item) html += `<p class="sub" style="margin-top:18px">Flood Commons id <code>${esc(row.id)}</code> · local id <code>${esc(row.local_id)}</code> · version ${item.record.metadata.record_version}</p>`;
  if (!canPublish()) html = `<p class="notice">As a contributor you can save drafts. An editor publishes them.</p>` + html;
  $("#editor-body").innerHTML = html;
  $("#editor-error").textContent = "";
  $("#editor-save").textContent = item ? "Save changes" : `Add ${NAMES[std].one}`;
  $("#editor").showModal();
  $("#editor-body [data-field=title] input")?.focus();
}
function readForm() {
  const form = $("#editor-form");
  const row = {};
  for (const c of columnsFor(editing.std)) {
    if (c.group === "system") continue;
    if (c.terms && c.list) row[c.key] = [...form.querySelectorAll(`input[name="${c.key}"]:checked`)].map((i) => i.value).join(" | ");
    else {
      const els = form.querySelectorAll(`[name="${c.key}"]`);
      const el = [...els].find((x) => !x.disabled);
      if (el) row[c.key] = el.value;
    }
  }
  return row;
}
function showErrors(errors = {}) {
  for (const f of document.querySelectorAll("#editor-body [data-field]")) {
    const msg = errors[f.dataset.field];
    f.classList.toggle("invalid", Boolean(msg));
    f.querySelector(".err").textContent = msg || "";
  }
  const first = Object.keys(errors).find((k) => $(`#editor-body [data-field="${k}"]`));
  if (first) $(`#editor-body [data-field="${first}"]`).scrollIntoView({ block: "center", behavior: "smooth" });
  return Object.entries(errors).filter(([k]) => !$(`#editor-body [data-field="${k}"]`)).map(([k, m]) => `${k} ${m}`).join("; ");
}
$("#editor-form").onsubmit = async (e) => {
  e.preventDefault();
  const { std, item } = editing;
  const row = readForm();
  const status = row.status || "draft";
  const audience = row.audience || "public";
  const record = fromRow(std, row, item?.record ?? null);
  const errors = validate(record, status);
  const extra = showErrors(errors);
  if (Object.keys(errors).length) return ($("#editor-error").textContent = "Fix the highlighted fields." + (extra ? ` (${extra})` : ""));
  if (!item && !editing.allowDuplicate) {
    const dup = data.items.find((i) => i.standard === std && i.status !== "excluded" && i.record.title.toLowerCase() === record.title.toLowerCase());
    if (dup) {
      editing.allowDuplicate = true;
      return ($("#editor-error").textContent = `“${dup.record.title}” already exists. Press ${$("#editor-save").textContent} again to add it anyway, or Cancel and edit the existing one.`);
    }
  }
  if (item && sameRecord(item.record, record) && item.status === status && item.audience === audience) {
    $("#editor").close();
    return flash("No changes to save.");
  }
  const btn = $("#editor-save");
  btn.disabled = true;
  $("#editor-error").textContent = "";
  try {
    const res = await rpc("fc_save_record", { doc: record, target: status, record_audience: audience, expected_revision: item?.rev ?? null });
    $("#editor").close();
    await refresh();
    render();
    flash(res.status === "published" ? (audience === "public" ? "Saved and published. It's on Local Help on the next page load." : "Saved and published for the AI (not on public pages).") : `Saved as ${res.status === "draft" ? "a draft" : "hidden"}. It isn't public.`);
  } catch (err) {
    $("#editor-error").textContent = err.message;
  } finally {
    btn.disabled = false;
  }
};
for (const b of document.querySelectorAll("#editor [data-close]")) b.onclick = () => $("#editor").close();

// ---------- CSV ----------
const csvCell = (v) => { const s = String(v ?? ""); return /[",\n\r]/.test(s) ? `"${s.replaceAll('"', '""')}"` : s; };
const toCsv = (keys, rows) => "﻿" + [keys.join(","), ...rows.map((r) => keys.map((k) => csvCell(r[k])).join(","))].join("\r\n") + "\r\n";
function download(name, text) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([text], { type: "text/csv;charset=utf-8" }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}
const EXAMPLE = {
  FSS: { status: "draft", audience: "public", title: "Example Tenant Flood Clinic (delete this row)", summary: "Free walk-in help for renters after a flood: repair requests, rent questions, and referrals.", provider_name: "Example Neighborhood Association", service_type: "tenant_support", service_area: "Red Hook, Brooklyn", categories: "housing | legal_assistance", audiences: "renters", action_stages: "recover", phone: "718-555-0100", email: "help@example.org", contact_url: "https://example.org/flood-clinic", availability: "listed_contact_provider", cost: "Free", hours: "Tue & Thu 5–8pm", service_languages: "English | Spanish", source_url: "https://example.org/flood-clinic", evidence_status: "website_documented", review_due: sixMonths(), verification_status: "unreviewed", languages: "en" },
  FRS: { status: "draft", audience: "public", title: "Example: Who do I call when my basement floods? (delete this row)", summary: "If water is rising or anyone is in danger, call 911. For sewer backup or street flooding, call 311.", resource_type: "faq_answer", categories: "reporting | preparedness", audiences: "residents", action_stages: "respond", source_url: "https://portal.311.nyc.gov/", source_organization: "NYC 311", verification_status: "unreviewed", languages: "en" },
};
const importKeys = (std) => columnsFor(std).map((c) => c.key);
const stdName = (std) => (std === "FSS" ? "services" : "answers-resources");

function importView() {
  const std = ui.importStd;
  const res = ui.importResult;
  const existing = data.items.filter((i) => i.standard === std && i.status !== "excluded");
  return `<div class="steps">
    <section class="panel">
      <h2>What are you uploading?</h2>
      <div class="seg" role="radiogroup" aria-label="Record type">
        <label><input type="radio" name="std" value="FSS" ${std === "FSS" ? "checked" : ""}><span>Services</span></label>
        <label><input type="radio" name="std" value="FRS" ${std === "FRS" ? "checked" : ""}><span>Answers &amp; resources</span></label>
      </div>
      <p>Columns follow the Flood Commons ${std === "FSS" ? "Flood Services Standard (FSS 0.1)" : "Flood Resource Standard (FRS 0.1)"}. Start from the template, or download what's already there, edit it in Excel or Google Sheets, and upload it back.</p>
      <div class="bar"><button class="btn" data-template>Download blank template</button><button class="btn" data-export>Download current ${NAMES[std].many.toLowerCase()} (${existing.length})</button></div>
    </section>
    <section class="panel">
      <h2>Upload your CSV</h2>
      <p>Rows with an <code>id</code> or <code>local_id</code> that matches a record update it: blank cells and missing columns keep their current values, and <code>CLEAR</code> in a cell erases that field. Rows without one are added. Nothing changes until you confirm, and the import is all-or-nothing.</p>
      <label class="drop" id="drop" tabindex="0"><strong>${ui.importFile ? esc(ui.importFile) : "Choose a CSV file"}</strong><span>${ui.importFile ? "Choose a different file" : "or drag it here"}</span><input type="file" id="file" accept=".csv,text/csv" hidden></label>
      ${ui.ignored.length ? `<p class="notice">Ignored columns that aren't part of the format: ${esc(ui.ignored.join(", "))}</p>` : ""}
    </section>
    ${res ? resultPanel(res) : ""}
    <section class="panel">
      <h2>Column guide</h2>
      <p>Required columns are marked *. Separate multiple values with <code>|</code>. Dates are <code>YYYY-MM-DD</code>. Column names can also be the labels shown in the form.</p>
      <div class="scroll"><table class="table guide"><thead><tr><th>Column</th><th>Meaning</th><th>Flood Commons field</th><th>Allowed values</th></tr></thead><tbody>${columnsFor(std)
        .map((c) => `<tr><td>${esc(c.key)}${c.required ? ' <span class="req">*</span>' : ""}</td><td><strong>${esc(labelOf(c, std))}</strong><div class="sub">${esc(c.help)}</div></td><td><code>${esc(c.fc)}</code></td><td class="sub">${c.terms ? TERMS[c.terms].map((t) => `<code>${esc(t.key)}</code>`).join(" ") : c.suggest ? "Suggested: " + c.suggest.map((s) => `<code>${esc(s)}</code>`).join(" ") : c.def ? `Default <code>${esc(c.def)}</code>` : ""}</td></tr>`)
        .join("")}</tbody></table></div>
    </section></div>`;
}
function resultPanel(res) {
  const n = res.counts;
  const changes = n.add + n.update;
  const rows = res.results
    .filter((r) => r.action !== "unchanged" || res.results.length <= 50)
    .map((r) => `<tr><td class="sub">${r.line}</td><td class="name">${esc(r.title || "(no title)")}</td><td><span class="pill ${r.action}">${{ add: "Add", update: "Update", unchanged: "No change", error: "Problem" }[r.action]}</span></td><td>${r.errors ? `<ul class="problems">${Object.entries(r.errors).map(([k, m]) => `<li><strong>${esc(k)}</strong> ${esc(m)}</li>`).join("")}</ul>` : ""}</td></tr>`)
    .join("");
  return `<section class="panel" id="result">
    <h2>${res.committed ? "Imported" : "Check before importing"}</h2>
    <div class="counts"><span class="pill add">${n.add} to add</span><span class="pill update">${n.update} to update</span><span class="pill unchanged">${n.unchanged} unchanged</span><span class="pill error">${n.error} with problems</span></div>
    ${res.committed ? `<p>Saved.</p>` : changes ? `<p>${n.error ? "Rows with problems will be skipped. Fix them in your file and upload again, or import the rest now." : "Everything looks good."}</p><div class="bar"><button class="btn primary" data-commit>Import ${changes} row${changes === 1 ? "" : "s"}</button><button class="btn" data-clear-import>Cancel</button></div>` : `<p>Nothing to import.</p>`}
    <div class="scroll"><table class="table"><thead><tr><th>Line</th><th>Title</th><th>Result</th><th>Problems</th></tr></thead><tbody>${rows}</tbody></table></div>
  </section>`;
}
function headerToKey(h, std) {
  const norm = (s) => String(s).trim().toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
  const n = norm(h);
  return columnsFor(std).find((c) => c.key === n || norm(labelOf(c, std)) === n)?.key ?? null;
}
const clean = (v) => String(v ?? "").trim();
function plan(std, rows) {
  const seen = new Map();
  const items = data.items.filter((i) => i.standard !== "FMS");
  return rows.map((row, index) => {
    const out = { line: index + 2, title: clean(row.title) };
    const id = clean(row.id);
    const localId = clean(row.local_id);
    const key = id || localId || `title:${out.title.toLowerCase()}`;
    if (seen.has(key)) return { ...out, action: "error", errors: { row: `repeats line ${seen.get(key)}` } };
    seen.set(key, out.line);
    const existing = items.find((i) => (id && i.record.id === id) || (localId && i.record.local_id === localId));
    if (existing?.status === "excluded") return { ...out, action: "error", errors: { row: "matches a record in the trash. Restore it first." } };
    if (existing && existing.standard !== std) return { ...out, action: "error", errors: { row: `id belongs to ${existing.standard === "FSS" ? "a service" : "an answer or resource"}` } };
    if (!existing && out.title) {
      const dup = items.find((i) => i.standard === std && i.status !== "excluded" && i.record.title.toLowerCase() === out.title.toLowerCase());
      if (dup) return { ...out, action: "error", errors: { title: `already exists (local_id ${dup.record.local_id}). Put that local_id in the row to update it.` } };
    }
    const status = normChoice(row.status, "status") || existing?.status || "published";
    if (!STATUSES.includes(status)) return { ...out, action: "error", errors: { status: "must be published, draft, or hidden" } };
    if (status !== "draft" && !canPublish() && status !== existing?.status) return { ...out, action: "error", errors: { status: "only editors can publish or hide; use draft" } };
    const audience = normChoice(row.audience, "visibility") || existing?.audience || "public";
    if (!AUDIENCES.includes(audience)) return { ...out, action: "error", errors: { audience: "must be public or internal" } };
    let record;
    try {
      record = applyRow(std, row, existing?.record ?? null, existing ? { status: existing.status, audience: existing.audience } : {});
    } catch (e) {
      return { ...out, action: "error", errors: { row: e.message } };
    }
    const errors = validate(record, status);
    if (Object.keys(errors).length) return { ...out, action: "error", errors };
    out.title = record.title;
    if (existing && sameRecord(existing.record, record) && existing.status === status && existing.audience === audience) return { ...out, action: "unchanged" };
    return { ...out, action: existing ? "update" : "add", status, audience, record, existing };
  });
}
const tally = (results) => results.reduce((n, r) => ({ ...n, [r.action]: (n[r.action] ?? 0) + 1 }), { add: 0, update: 0, unchanged: 0, error: 0 });
function parseFile(file) {
  ui.importFile = file.name;
  ui.importResult = null;
  Papa.parse(file, {
    header: true,
    skipEmptyLines: "greedy",
    complete: ({ data: rows, meta, errors }) => {
      if (errors.length && !rows.length) return flash("Couldn't read that file as CSV.", true);
      const std = ui.importStd;
      const map = Object.fromEntries(meta.fields.map((h) => [h, headerToKey(h, std)]));
      ui.ignored = meta.fields.filter((h) => !map[h] && h.trim());
      if (!Object.values(map).some((k) => ["title", "id", "local_id"].includes(k))) {
        render();
        return flash("This file needs a title column (or id / local_id to update existing records). Download the template to see the format.", true);
      }
      if (rows.length > 2000) return flash("Up to 2,000 rows per upload. Split the file.", true);
      ui.importRows = rows.map((r) => Object.fromEntries(Object.entries(r).filter(([h]) => map[h]).map(([h, v]) => [map[h], v])));
      const results = plan(std, ui.importRows);
      ui.importResult = { committed: false, counts: tally(results), results };
      render();
      $("#result")?.scrollIntoView({ behavior: "smooth", block: "start" });
    },
  });
}
async function commitImport() {
  // Re-plan against fresh data so nothing that changed meanwhile is overwritten.
  await refresh();
  const results = plan(ui.importStd, ui.importRows);
  const changes = results.filter((r) => r.action === "add" || r.action === "update");
  try {
    if (!changes.length) throw new Error("Nothing to import: every row is unchanged or has a problem.");
    await rpc("fc_import_records", {
      items: changes.map((r) => ({ line: r.line, doc: r.record, status: r.status, audience: r.audience, expected_revision: r.existing?.rev ?? null })),
      filename: ui.importFile,
    });
    const counts = tally(results);
    ui.importResult = { committed: true, counts, results };
    await refresh();
    flash(`Imported: ${counts.add} added, ${counts.update} updated${counts.error ? `, ${counts.error} skipped` : ""}.`);
  } catch (err) {
    ui.importResult = { committed: false, counts: tally(results), results };
    flash(`Nothing was imported. ${err.message}`, true);
  }
  render();
  $("#result")?.scrollIntoView({ behavior: "smooth", block: "start" });
}
function wireImport() {
  const drop = $("#drop");
  const file = $("#file");
  drop.onkeydown = (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); file.click(); } };
  file.onchange = () => file.files[0] && parseFile(file.files[0]);
  drop.ondragover = (e) => { e.preventDefault(); drop.classList.add("over"); };
  drop.ondragleave = () => drop.classList.remove("over");
  drop.ondrop = (e) => { e.preventDefault(); drop.classList.remove("over"); if (e.dataTransfer.files[0]) parseFile(e.dataTransfer.files[0]); };
  for (const r of document.querySelectorAll('input[name="std"]')) r.onchange = () => { ui.importStd = r.value; ui.importResult = null; ui.importFile = null; ui.ignored = []; render(); };
  const std = ui.importStd;
  $("[data-template]").onclick = () => download(`flood-commons-${stdName(std)}-template.csv`, toCsv(importKeys(std), [EXAMPLE[std]]));
  $("[data-export]").onclick = () => download(`flood-commons-${stdName(std)}-${today()}.csv`, toCsv(importKeys(std), data.items.filter((i) => i.standard === std && i.status !== "excluded").map((i) => i.row)));
  const commit = $("[data-commit]");
  if (commit) commit.onclick = () => { commit.disabled = true; commitImport(); };
  const clear = $("[data-clear-import]");
  if (clear) clear.onclick = () => { Object.assign(ui, { importResult: null, importFile: null, importRows: null, ignored: [] }); render(); };
}

// ---------- people ----------
const ROLE_HELP = { contributor: "saves drafts", editor: "publishes, reviews clips", admin: "also manages people" };
async function peopleView() {
  const el = $("#view");
  let members;
  try {
    members = await rpc("fc_members");
  } catch (err) {
    el.innerHTML = `<div class="empty"><h2>People</h2><p>${esc(err.message)}</p></div>`;
    return;
  }
  const roleSel = (m) => `<select class="state" data-member="${m.user_id}" ${m.email === session.email ? "disabled" : ""} aria-label="Role for ${esc(m.email)}">${Object.keys(ROLE_HELP).map((r) => `<option value="${r}" ${m.role === r ? "selected" : ""}>${r[0].toUpperCase() + r.slice(1)}</option>`).join("")}</select>`;
  el.innerHTML = `<section class="panel">
      <h2>Add a colleague</h2>
      <p>They sign in on this page with their own email. If they don't have an account yet, they're added the first time they sign in with that address.</p>
      <form id="add-member" class="bar">
        <input name="email" type="email" required placeholder="name@organization.org" aria-label="Email" style="flex:1 1 260px;width:auto">
        <select name="role" aria-label="Role" style="width:auto">${Object.entries(ROLE_HELP).map(([r, h]) => `<option value="${r}" ${r === "editor" ? "selected" : ""}>${r[0].toUpperCase() + r.slice(1)}: ${h}</option>`).join("")}</select>
        <button class="btn primary" type="submit">Add</button>
      </form>
    </section>
    <table class="table"><thead><tr><th>Person</th><th>Role</th><th>Status</th><th></th></tr></thead><tbody>${members
      .map((m) => `<tr><td class="name">${esc(m.email)}${m.email === session.email ? ' <span class="sub">(you)</span>' : ""}</td>
        <td>${m.pending ? `<span class="pill unchanged">${esc(m.role)}</span>` : roleSel(m)}</td>
        <td>${m.pending ? `<span class="pill warn">Hasn't signed in yet</span>` : m.active ? `<span class="pill add">Active</span>` : `<span class="pill unchanged">Turned off</span>`}</td>
        <td><div class="row-actions">${m.pending ? `<button class="btn danger" data-unpend="${esc(m.email)}">Remove</button>` : m.email === session.email ? "" : `<button class="btn ${m.active ? "danger" : ""}" data-toggle="${m.user_id}" data-role="${m.role}" data-on="${m.active}">${m.active ? "Turn off access" : "Turn access back on"}</button>`}</div></td></tr>`)
      .join("")}</tbody></table>`;
  $("#add-member").onsubmit = (e) => {
    e.preventDefault();
    const f = e.target;
    act(async () => {
      const state = await rpc("fc_add_member", { email_address: f.email.value, member_role: f.role.value });
      flash(state === "active" ? `${f.email.value} can sign in now.` : `${f.email.value} is added. They join when they first sign in.`);
    });
  };
  el.querySelectorAll("[data-member]").forEach((s) => (s.onchange = () => act(() => rpc("fc_update_member", { member: s.dataset.member, member_role: s.value, enabled: true }), "Role updated.")));
  el.querySelectorAll("[data-toggle]").forEach((b) => (b.onclick = () => act(() => rpc("fc_update_member", { member: b.dataset.toggle, member_role: b.dataset.role, enabled: b.dataset.on !== "true" }), b.dataset.on === "true" ? "Access turned off." : "Access turned back on.")));
  el.querySelectorAll("[data-unpend]").forEach((b) => (b.onclick = () => act(() => rpc("fc_remove_pending_member", { email_address: b.dataset.unpend }), "Removed.")));
}

// ---------- activity ----------
const ACTIONS = {
  propose: "saved", publish: "published", archive: "took offline", exclude: "moved to trash", revise: "sent back", "status:draft": "set to draft", "status:hidden": "hid",
  "audience:public": "made public", "audience:internal": "made AI-only", approve_clip: "approved a clip", reject_clip: "rejected a clip", "removal:remove": "took down after a removal request",
  "removal:dismiss": "kept after a removal request", add_member: "added", set_member: "changed a member's access", remove_pending_member: "removed invite for", import_csv: "imported a CSV", load_local_help: "moved Local Help's listings in",
  invite: "invited someone", accept_invite: "joined",
};
async function logView() {
  const el = $("#view");
  try {
    const rows = await rpc("fc_activity", { max_rows: 300 });
    el.innerHTML = rows.length
      ? `<ul class="log-list">${rows.map((l) => {
          const what = ACTIONS[l.action] ?? l.action;
          const obj = l.title ? `“${esc(l.title)}”` : ["add_member", "remove_pending_member", "import_csv"].includes(l.action) ? esc(l.target) : l.action === "load_local_help" ? `(${esc(l.target)} records)` : "";
          return `<li><time datetime="${esc(l.at)}">${esc(new Date(l.at).toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" }))}</time><strong>${esc(l.who)}</strong> ${esc(what)} ${obj}</li>`;
        }).join("")}</ul>`
      : `<div class="empty"><h2>No activity yet.</h2></div>`;
  } catch (err) {
    el.innerHTML = `<div class="empty"><h2>Activity</h2><p>${esc(err.message)}</p></div>`;
  }
}

// ---------- boot ----------
if (!cfg.url || !cfg.key) {
  show("login");
  $("#login-msg").textContent = "This site isn't connected to a Flood Commons database yet (site/config.json).";
} else {
  const type = takeHashSession();
  if (type === "recovery") show("set-password");
  else if (session) start().catch((err) => { show("login"); $("#login-msg").textContent = err.message; });
  else show("login");
}
