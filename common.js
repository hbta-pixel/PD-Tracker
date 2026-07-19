// Shared helpers used by every page. Requires config.js and the Supabase UMD
// script to be loaded first.

const ENTRY_TYPES = {
  vet_pd: { label: "VET Professional Development", short: "VET PD" },
  vocational_pd: { label: "Vocational PD", short: "Vocational PD" },
  industry_engagement: { label: "Industry Engagement", short: "Industry Engagement" },
};

function configLooksUnset() {
  return (
    !SUPABASE_URL ||
    !SUPABASE_ANON_KEY ||
    SUPABASE_URL.includes("YOUR_SUPABASE") ||
    SUPABASE_ANON_KEY.includes("YOUR_SUPABASE")
  );
}

function showConfigWarningIfNeeded() {
  if (!configLooksUnset()) return;
  const bar = document.createElement("div");
  bar.className = "config-warning";
  bar.textContent =
    "Supabase is not configured yet. Edit pd-tracker/config.js with your project URL and anon key.";
  document.body.prepend(bar);
}

// Guard against a placeholder/invalid config throwing before the warning
// banner above ever gets a chance to render.
const db = configLooksUnset()
  ? null
  : supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

async function getSessionProfile() {
  if (!db) return null;
  const {
    data: { session },
  } = await db.auth.getSession();
  if (!session) return null;

  const { data: profile, error } = await db
    .from("profiles")
    .select("*, organizations(name, invite_code)")
    .eq("id", session.user.id)
    .single();

  if (error || !profile) return null;
  return { session, profile };
}

// Redirects to index.html if not logged in, or if logged in with the wrong role.
// Pass requiredRole = null to allow either role.
async function requireAuth(requiredRole) {
  const result = await getSessionProfile();
  if (!result) {
    window.location.href = "index.html";
    return null;
  }
  if (requiredRole && result.profile.role !== requiredRole) {
    window.location.href =
      result.profile.role === "admin" ? "dashboard.html" : "capture.html";
    return null;
  }
  return result;
}

async function signOut() {
  if (db) await db.auth.signOut();
  window.location.href = "index.html";
}

function formatDateTime(iso) {
  return new Date(iso).toLocaleString(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  });
}

function toCSV(rows) {
  const header = [
    "Staff name",
    "Type",
    "Date",
    "Title",
    "Details",
    "Contact",
    "Photo URL",
    "Submitted",
  ];
  const lines = [header.join(",")];
  for (const r of rows) {
    const cells = [
      r.staff_name,
      ENTRY_TYPES[r.entry_type]?.short ?? r.entry_type,
      r.entry_date,
      r.title ?? "",
      r.transcript ?? "",
      r.contact_name ?? "",
      r.photo_url ?? "",
      r.created_at,
    ].map((c) => `"${String(c).replace(/"/g, '""')}"`);
    lines.push(cells.join(","));
  }
  return lines.join("\n");
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str ?? "";
  return div.innerHTML;
}

function downloadText(filename, text) {
  const blob = new Blob([text], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

document.addEventListener("DOMContentLoaded", showConfigWarningIfNeeded);

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("sw.js").catch(() => {});
  });
}
