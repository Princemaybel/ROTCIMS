// ==========================================================================
// FILE: config.js
// PURPOSE: Initializes and exports the global Supabase client used by every
//          page in ROTCIMS. This file must be the FIRST script loaded on
//          any page — before auth.js, nav.js, or any page-specific script —
//          because all other scripts depend on window.supabaseClient.
//
// USED BY: Every HTML page in the project (loaded via <script> in <head>).
//
// HOW IT WORKS:
//   1. A plain object (SUPABASE_CONFIG) holds the project credentials.
//   2. The Supabase JS library is expected to be loaded from a CDN <script>
//      tag BEFORE this file runs. The CDN exposes a global `window.supabase`
//      object with a `createClient` factory function.
//   3. We call createClient() with our credentials and preferred auth options,
//      then store the resulting client on `window.supabaseClient` so every
//      other script in the project can reach it as a true global.
//
// IMPORTANT NOTES:
//   • The anonKey is intentionally PUBLIC — Supabase is designed this way.
//     Row-Level Security (RLS) policies on the database tables are what
//     actually protect sensitive data, NOT hiding this key.
//   • Never put the service_role (admin) key here — that key bypasses RLS
//     and must only be used in a secure server-side environment.
// ==========================================================================
  
// --------------------------------------------------------------------------
// SECTION 1 — Project Credentials
// --------------------------------------------------------------------------

// SUPABASE_CONFIG holds the two values that identify our Supabase project.
// Using a named object (rather than bare variables) groups them logically
// and makes it obvious they belong together.
const SUPABASE_CONFIG = {
  // The unique REST/Realtime endpoint for this Supabase project.
  // Found in: Supabase Dashboard → Project Settings → API → Project URL
  url: "https://cntisxkugmvwsommzjom.supabase.co",

  // The "anon" (anonymous) public API key.
  // This key identifies our project to Supabase but grants only the
  // permissions defined by our Row-Level Security (RLS) policies.
  // Found in: Supabase Dashboard → Project Settings → API → anon / public
  anonKey: "sb_publishable_crUK3jaModJMUqnZjnma_w_-9i-CEns",
};

// --------------------------------------------------------------------------
// SECTION 2 — Client Initialization (Safety-Guarded)
// --------------------------------------------------------------------------

// Before calling createClient() we verify the CDN library actually loaded.
// If a browser blocks the CDN script (ad-blocker, network error, wrong URL),
// `window.supabase` will be undefined and calling it would throw a crash.
// The guard here converts that silent crash into a clear console error.
if (typeof window.supabase !== "undefined") {

  // createClient() is the Supabase factory function — it returns a fully
  // configured client instance ready to make authenticated API calls.
  // We store it as window.supabaseClient so auth.js and all page scripts
  // can access it without needing to import or require anything (we are
  // using vanilla JS without a bundler, so globals are our module system).
  window.supabaseClient = window.supabase.createClient(
    SUPABASE_CONFIG.url,      // Tells the client WHERE to connect
    SUPABASE_CONFIG.anonKey,  // Tells the client WHO we are (project identity)
    {
      auth: {
        // persistSession: true → Saves the user's login session to
        // localStorage so they stay logged in across page refreshes and
        // new browser tabs. Without this, the user would be logged out
        // every time they navigate to a different page.
        persistSession: true,

        // autoRefreshToken: true → Supabase sessions expire after a set
        // time (default: 1 hour). This option tells the client to silently
        // request a new token in the background before the current one
        // expires, keeping the user seamlessly logged in.
        autoRefreshToken: true,

        // detectSessionInUrl: true → After an email confirmation or OAuth
        // redirect, Supabase appends the session tokens to the URL as a
        // hash fragment (e.g., #access_token=...). This option tells the
        // client to detect those tokens, store the session, and clean the
        // URL automatically. Required for email-confirmation flows to work.
        detectSessionInUrl: true,
      },
    }
  );
} else {
  // If the CDN block above fails, log a clear human-readable error to the
  // browser console. This saves developers from hunting for a cryptic
  // "cannot read property of undefined" error elsewhere.
  console.error("Supabase CDN library not detected. Ensure script is loaded in <head>.");
}
