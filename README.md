# PD Tracker

A mobile-first web app (installable PWA) for RTOs to capture staff professional
development in real time: trainers talk (or type) an entry, optionally attach a
photo, and it lands instantly on their RTO's dashboard. Covers three record
types: **VET PD**, **Vocational PD**, and **Industry Engagement**.

This first build is the core product only: capture flow + live dashboard.
No subscription billing yet.

## How it's built

- Plain HTML/CSS/JS — no build step, works as static files (same as the rest
  of this repo).
- [Supabase](https://supabase.com) for auth, the Postgres database, and photo
  storage. The browser talks to Supabase directly; access control is enforced
  by Row Level Security (RLS) policies, not by a custom backend server.
- Voice-to-text uses the browser's built-in Web Speech API (Chrome/Edge/Safari
  on Android and iOS). No transcription cost, no API key.

## One-time setup

1. **Create a free Supabase project** at [supabase.com](https://supabase.com).
2. **Run the schema**: open your project's SQL Editor and run the contents of
   [`schema.sql`](./schema.sql). This creates the tables, security policies,
   and the `pd-photos` storage bucket.
3. **Turn off email confirmation** (recommended for now): Authentication →
   Sign In / Providers → Email → turn off "Confirm email". Without this,
   sign-up won't finish because the app creates your profile row right after
   sign-up, which needs an active session. You can turn confirmation back on
   later once you add a proper post-confirmation flow.
4. **Fill in `config.js`** with your project's URL and anon public key
   (Project Settings → API). The anon key is meant to be public — RLS is what
   actually protects the data.
5. **Serve the folder** over HTTP(S) — opening the HTML files directly with
   `file://` will not work (service worker + camera access need a real
   origin). Locally: `npx serve pd-tracker`. In production: GitHub Pages,
   Netlify, Vercel, etc. HTTPS is required for the microphone and camera to
   work on a phone.

## Using it

- **First user (you)**: go to the site, Sign up → "I'm an RTO admin", enter
  your organisation's name. This creates your organisation and gives you an
  **invite code** shown on your dashboard.
- **Trainers**: Sign up → "I'm a trainer", enter the invite code your admin
  shared with them.
- **Trainers** land on the capture screen: pick VET PD / Vocational PD /
  Industry Engagement, tap the mic and talk, optionally attach a photo, hit
  submit. It's instantly queryable on the admin dashboard.
- **Admins** land on the dashboard: filter by staff/type/date, watch entries
  arrive live, download everything as CSV.
- **Forgot password?** On the login screen, trainers and admins can request a
  reset link by email (uses Supabase Auth's built-in recovery email — no
  extra email service needed) and set a new password on the linked page.

## Known simplifications (MVP)

- No subscription/billing yet — anyone can sign up and create an organisation.
  Add Stripe (or similar) in front of the admin sign-up flow when you're
  ready to charge.
- Entries are append-only (no edit/delete) — intentional for evidence
  integrity, but you may want an admin "flag/dismiss" action later.
- The `organizations` table is readable (name + invite code) by any signed-in
  user, so trainer sign-up can validate invite codes. Fine for now; tighten
  later if org names need to stay private between RTOs.
- Voice-to-text quality depends on the trainer's browser/device — Chrome on
  Android and Safari on iOS both support it, but accuracy varies. The
  transcript is always editable before submitting.
- No push notifications — the dashboard updates live only while it's open;
  refresh to pick up entries submitted while it was closed (it also
  re-subscribes and reloads on every new insert automatically).

## Natural next steps

- Stripe subscription billing gated in front of the "RTO admin" sign-up.
- Native app wrapper (Capacitor) if the PWA experience isn't native-feeling
  enough.
- Per-entry admin comments / approval status for audit trail.
- Export to a specific compliance format (ASQA-friendly PDF/Excel) instead
  of raw CSV.
