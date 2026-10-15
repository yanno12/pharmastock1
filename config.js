// PharmaStock configuration. Fill in the two Supabase values, then reload the page.
// Find them in Supabase: Project Settings > API.
// Use the PUBLIC "anon" (or "publishable") key. NEVER put the "service_role" key here:
// everything in this file is visible to every visitor.
window.PHARMASTOCK = {
  SUPABASE_URL: "",        // e.g. "https://abcdxyz.supabase.co" (or http://127.0.0.1:54321 locally)
  SUPABASE_ANON_KEY: "",

  // Legal texts are required before real pharmacies register. Host them yourself.
  TERMS_URL: "",           // link to the conditions d'utilisation
  PRIVACY_URL: "",         // link to the politique de confidentialité
  TERMS_VERSION: ""        // e.g. "2026-11-01", stored with each registration
};
