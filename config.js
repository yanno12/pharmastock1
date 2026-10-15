// PharmaStock configuration. Fill in the two Supabase values, then reload the page.
// Find them in Supabase: Project Settings > API.
// Use the PUBLIC "anon" (or "publishable") key. NEVER put the "service_role" key here:
// everything in this file is visible to every visitor.
window.PHARMASTOCK = {
  SUPABASE_URL: "https://ifmfobaxwtnlothztffl.supabase.co/rest/v1/",        // e.g. "https://abcdxyz.supabase.co" (or http://127.0.0.1:54321 locally)
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImlmbWZvYmF4d3RubG90aHp0ZmZsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIwMjE2MjcsImV4cCI6MjEwNzU5NzYyN30.OjKXvLbcLc7VxN8tU8yBTEAHrOw9zgP-6ycgobRMq58",

  // Legal texts are required before real pharmacies register. Host them yourself.
  TERMS_URL: "",           // link to the conditions d'utilisation
  PRIVACY_URL: "",         // link to the politique de confidentialité
  TERMS_VERSION: ""        // e.g. "2026-11-01", stored with each registration
};
