from pathlib import Path

html = Path("index.html").read_text(encoding="utf-8")
ui = Path("portal-passkey-lock.js").read_text(encoding="utf-8")
edge = Path("supabase/functions/portal-passkeys/index.ts").read_text(encoding="utf-8")
migration = Path("supabase/migrations/20261027000200_admin_student_portal_passkeys.sql").read_text(encoding="utf-8").lower()
native = Path("mobile/native-bridge.js").read_text(encoding="utf-8")
package = Path("package.json").read_text(encoding="utf-8")
supabase_config = Path("supabase/config.toml").read_text(encoding="utf-8")

checks = {
    "Admin login uses Supabase Auth passkey": "auth.signInWithPasskey()" in html,
    "Passkey code reuses the shared Supabase client": "__ashianaGetMainSupabaseClient" in ui and "SUPABASE_KEY" not in ui,
    "Supabase client opts into Auth passkeys": "experimental: { passkey: true }" in html and "[auth.passkey]\nenabled = true" in supabase_config,
    "Admin passkey is checked by server authorization RPC": "authorize_admin_login" in html,
    "Admin unlock requires an exact account match": "!expectedEmail || email !== expectedEmail" in ui,
    "Student passkey login requires Admission No.": 'getElementById("student-login-admission")' in ui and "extra.admission_no = admission" in ui,
    "Student dashboard session is minted only after assertion": '"authentication-verify"' in ui and "student_session_tokens" in edge,
    "Student session is revalidated server-side": "student_session_student_id" in edge,
    "Android uses native Credential Manager plugin": '"@capgo/capacitor-passkey"' in package and "CapacitorPasskey.autoShimWebAuthn()" in native,
    "Local biometric-only portal unlock was removed": "verifyPortalBiometric" not in ui and "NativeBiometric.verifyIdentity" not in ui,
    "Passkey requires user verification": "requireUserVerification: true" in edge,
    "Native origins use an exact certificate-hash allowlist": 'android:apk-key-hash:[A-Za-z0-9_-]{43}' in edge and "EXPECTED_ORIGINS" in edge,
    "Android WebView CORS origin is explicit": '"https://localhost"' in edge,
    "Credential/challenge tables have RLS": "enable row level security" in migration,
    "Clients cannot access credential or challenge tables": "revoke all on public.portal_webauthn_credentials from public, anon, authenticated" in migration and "revoke all on public.portal_webauthn_challenges from public, anon, authenticated" in migration,
    "Only public keys are stored": "public_key text not null" in migration,
}

for name, passed in checks.items():
    print(("PASS" if passed else "FAIL") + ": " + name)
if not all(checks.values()):
    raise SystemExit(1)
