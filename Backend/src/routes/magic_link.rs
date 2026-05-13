//! Magic-link (email OTP) sign-in.
//!
//! Two endpoints, both public (no auth middleware):
//!
//! - `POST /api/auth/magic-link/request` — body `{"email": "..."}`. Generates a
//!   6-digit OTP, stores its SHA-256 hash in Firestore at
//!   `magic_link_otps/{email}` with a 10-minute expiry, sends the code to the
//!   user via Resend, and returns `{"sent": true}` regardless of whether the
//!   address corresponds to an existing user (so we don't leak user existence).
//!
//! - `POST /api/auth/magic-link/verify` — body `{"email": "...", "code": "..."}`.
//!   Validates the OTP against Firestore, looks up (or creates) the Firebase
//!   user by email via the Identity Toolkit Admin API, mints a Firebase
//!   **custom token** signed by the backend service account, and returns it.
//!   The desktop app then exchanges that custom token for a real Firebase ID
//!   token via `accounts:signInWithCustomToken`.

use axum::{extract::Extension, http::StatusCode, response::IntoResponse, Json};
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::Arc;

use crate::config::Config;
use crate::firestore;

const OTP_COLLECTION: &str = "magic_link_otps";
const OTP_TTL_SECONDS: i64 = 600; // 10 minutes
const RESEND_COOLDOWN_SECONDS: i64 = 30; // can't re-request within 30s
const MAX_ATTEMPTS: i64 = 5;
const IDENTITY_TOOLKIT_AUDIENCE: &str =
    "https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit";

// ---------- Request ----------

#[derive(Deserialize)]
pub struct RequestBody {
    pub email: String,
}

#[derive(Serialize)]
pub struct RequestResponse {
    pub sent: bool,
}

/// POST /api/auth/magic-link/request
pub async fn request(
    Extension(config): Extension<Arc<Config>>,
    Json(body): Json<RequestBody>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let email = normalize_email(&body.email)
        .ok_or((StatusCode::BAD_REQUEST, "Invalid email address".to_string()))?;

    if config.resend_api_key.is_empty() {
        tracing::error!("Magic link request: RESEND_API_KEY not configured");
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "Email service not configured".to_string(),
        ));
    }

    let token = firestore::get_access_token(&config)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("Token error: {e}")))?;

    let now = chrono::Utc::now().timestamp();

    // Rate-limit: don't allow re-sending within RESEND_COOLDOWN_SECONDS.
    if let Some(existing) = get_otp_doc(&config, &token, &email).await? {
        if let Some(last_sent) = existing.last_sent_at {
            if now - last_sent < RESEND_COOLDOWN_SECONDS {
                let wait = RESEND_COOLDOWN_SECONDS - (now - last_sent);
                return Err((
                    StatusCode::TOO_MANY_REQUESTS,
                    format!("Please wait {wait}s before requesting another code"),
                ));
            }
        }
    }

    // Generate a fresh 6-digit OTP.
    let code = generate_otp();
    let code_hash = sha256_hex(&code);
    let expires_at = now + OTP_TTL_SECONDS;

    // Store hashed OTP in Firestore (idempotent upsert per email).
    upsert_otp_doc(
        &config,
        &token,
        &email,
        &OtpDoc {
            code_hash: code_hash.clone(),
            expires_at,
            attempts: 0,
            last_sent_at: Some(now),
        },
    )
    .await?;

    // Send the email via Resend.
    send_otp_email(&config, &email, &code).await?;

    tracing::info!(email = %redact_email(&email), "Magic link OTP sent");

    Ok(Json(RequestResponse { sent: true }))
}

// ---------- Verify ----------

#[derive(Deserialize)]
pub struct VerifyBody {
    pub email: String,
    pub code: String,
}

#[derive(Serialize)]
pub struct VerifyResponse {
    pub custom_token: String,
    pub email: String,
    pub uid: String,
}

/// POST /api/auth/magic-link/verify
pub async fn verify(
    Extension(config): Extension<Arc<Config>>,
    Json(body): Json<VerifyBody>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let email = normalize_email(&body.email)
        .ok_or((StatusCode::BAD_REQUEST, "Invalid email address".to_string()))?;
    let code = body.code.trim().to_string();
    if code.len() != 6 || !code.chars().all(|c| c.is_ascii_digit()) {
        return Err((StatusCode::BAD_REQUEST, "Invalid code format".to_string()));
    }

    let firestore_token = firestore::get_access_token(&config)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("Token error: {e}")))?;

    let doc = get_otp_doc(&config, &firestore_token, &email)
        .await?
        .ok_or((
            StatusCode::UNAUTHORIZED,
            "No active code for this email. Request a new one.".to_string(),
        ))?;

    let now = chrono::Utc::now().timestamp();
    if now > doc.expires_at {
        // Best-effort cleanup
        let _ = delete_otp_doc(&config, &firestore_token, &email).await;
        return Err((StatusCode::UNAUTHORIZED, "Code expired".to_string()));
    }

    if doc.attempts >= MAX_ATTEMPTS {
        let _ = delete_otp_doc(&config, &firestore_token, &email).await;
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "Too many attempts. Request a new code.".to_string(),
        ));
    }

    let provided_hash = sha256_hex(&code);
    if !constant_time_eq(&provided_hash, &doc.code_hash) {
        // Increment attempt counter.
        let _ = upsert_otp_doc(
            &config,
            &firestore_token,
            &email,
            &OtpDoc {
                attempts: doc.attempts + 1,
                ..doc
            },
        )
        .await;
        return Err((StatusCode::UNAUTHORIZED, "Invalid code".to_string()));
    }

    // OTP is valid — consume it.
    let _ = delete_otp_doc(&config, &firestore_token, &email).await;

    // Look up or create the Firebase user.
    let firebase_token = firestore::get_access_token_with_scope(&config, firestore::FIREBASE_SCOPE)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Firebase token error: {e}"),
            )
        })?;

    let uid = lookup_or_create_user(&config, &firebase_token, &email).await?;

    // Mint a Firebase custom token signed by the service account.
    let custom_token = mint_custom_token(&config, &uid, &email).map_err(|e| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("Custom token mint error: {e}"),
        )
    })?;

    tracing::info!(uid = %uid, email = %redact_email(&email), "Magic link verified");

    Ok(Json(VerifyResponse {
        custom_token,
        email,
        uid,
    }))
}

// ---------- Firestore helpers ----------

#[derive(Clone)]
struct OtpDoc {
    code_hash: String,
    expires_at: i64,
    attempts: i64,
    last_sent_at: Option<i64>,
}

fn otp_doc_url(config: &Arc<Config>, email: &str) -> String {
    format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents/{}/{}",
        config.firebase_project_id,
        OTP_COLLECTION,
        urlencoding::encode(email)
    )
}

async fn get_otp_doc(
    config: &Arc<Config>,
    token: &str,
    email: &str,
) -> Result<Option<OtpDoc>, (StatusCode, String)> {
    let url = otp_doc_url(config, email);
    let resp = reqwest::Client::new()
        .get(&url)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Firestore error: {e}")))?;

    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(None);
    }
    if !resp.status().is_success() {
        let err = resp.text().await.unwrap_or_default();
        return Err((StatusCode::BAD_GATEWAY, format!("Firestore: {err}")));
    }

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Firestore parse: {e}")))?;

    let fields = match body.get("fields") {
        Some(f) => f,
        None => return Ok(None),
    };

    let code_hash = fields["code_hash"]["stringValue"]
        .as_str()
        .unwrap_or("")
        .to_string();
    let expires_at = fields["expires_at"]["integerValue"]
        .as_str()
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(0);
    let attempts = fields["attempts"]["integerValue"]
        .as_str()
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(0);
    let last_sent_at = fields["last_sent_at"]["integerValue"]
        .as_str()
        .and_then(|s| s.parse::<i64>().ok());

    if code_hash.is_empty() {
        return Ok(None);
    }

    Ok(Some(OtpDoc {
        code_hash,
        expires_at,
        attempts,
        last_sent_at,
    }))
}

async fn upsert_otp_doc(
    config: &Arc<Config>,
    token: &str,
    email: &str,
    doc: &OtpDoc,
) -> Result<(), (StatusCode, String)> {
    let url = otp_doc_url(config, email);
    let mut fields = serde_json::json!({
        "code_hash":  { "stringValue":  doc.code_hash },
        "expires_at": { "integerValue": doc.expires_at.to_string() },
        "attempts":   { "integerValue": doc.attempts.to_string() },
    });
    if let Some(last_sent) = doc.last_sent_at {
        fields["last_sent_at"] = serde_json::json!({ "integerValue": last_sent.to_string() });
    }

    let body = serde_json::json!({ "fields": fields });

    let resp = reqwest::Client::new()
        .patch(&url)
        .bearer_auth(token)
        .json(&body)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Firestore error: {e}")))?;

    if !resp.status().is_success() {
        let err = resp.text().await.unwrap_or_default();
        return Err((StatusCode::BAD_GATEWAY, format!("Firestore write: {err}")));
    }
    Ok(())
}

async fn delete_otp_doc(
    config: &Arc<Config>,
    token: &str,
    email: &str,
) -> Result<(), (StatusCode, String)> {
    let url = otp_doc_url(config, email);
    let _ = reqwest::Client::new()
        .delete(&url)
        .bearer_auth(token)
        .send()
        .await;
    Ok(())
}

// ---------- Identity Toolkit Admin: lookup or create user ----------

/// Resolve the Firebase UID for `email`. Creates a new account if none exists.
async fn lookup_or_create_user(
    config: &Arc<Config>,
    token: &str,
    email: &str,
) -> Result<String, (StatusCode, String)> {
    // 1. Try lookup.
    let lookup_url = format!(
        "https://identitytoolkit.googleapis.com/v1/projects/{}/accounts:lookup",
        config.firebase_project_id
    );
    let lookup_resp: serde_json::Value = reqwest::Client::new()
        .post(&lookup_url)
        .bearer_auth(token)
        .json(&serde_json::json!({ "email": [email] }))
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Identity lookup: {e}")))?
        .json()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Identity parse: {e}")))?;

    if let Some(users) = lookup_resp["users"].as_array() {
        if let Some(first) = users.first() {
            if let Some(uid) = first["localId"].as_str() {
                return Ok(uid.to_string());
            }
        }
    }

    // 2. Create a new user (email-verified — they just clicked a code we sent).
    let create_url = format!(
        "https://identitytoolkit.googleapis.com/v1/projects/{}/accounts",
        config.firebase_project_id
    );
    let create_resp = reqwest::Client::new()
        .post(&create_url)
        .bearer_auth(token)
        .json(&serde_json::json!({
            "email": email,
            "emailVerified": true,
        }))
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Identity create: {e}")))?;

    if !create_resp.status().is_success() {
        let err = create_resp.text().await.unwrap_or_default();
        tracing::error!(error = %err, "Identity Toolkit create failed");
        return Err((
            StatusCode::BAD_GATEWAY,
            format!("Identity create failed: {err}"),
        ));
    }

    let json: serde_json::Value = create_resp
        .json()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Identity parse: {e}")))?;

    json["localId"]
        .as_str()
        .map(|s| s.to_string())
        .ok_or((
            StatusCode::INTERNAL_SERVER_ERROR,
            "Identity create returned no localId".to_string(),
        ))
}

// ---------- Custom token mint ----------

#[derive(Serialize)]
struct CustomTokenClaims<'a> {
    iss: &'a str,
    sub: &'a str,
    aud: &'a str,
    iat: i64,
    exp: i64,
    uid: &'a str,
    claims: serde_json::Value,
}

fn mint_custom_token(
    config: &Arc<Config>,
    uid: &str,
    email: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let sa_email = &config.gcp_service_account;
    if sa_email.is_empty() {
        return Err("GCP_SERVICE_ACCOUNT not set".into());
    }

    let now = chrono::Utc::now().timestamp();
    let claims = CustomTokenClaims {
        iss: sa_email,
        sub: sa_email,
        aud: IDENTITY_TOOLKIT_AUDIENCE,
        iat: now,
        exp: now + 3600,
        uid,
        claims: serde_json::json!({
            "email": email,
            "auth_provider": "magic_link",
        }),
    };

    let key = EncodingKey::from_rsa_pem(config.vertex_sa_private_key_pem.as_bytes())?;
    let mut header = Header::new(Algorithm::RS256);
    header.typ = Some("JWT".to_string());

    Ok(encode(&header, &claims, &key)?)
}

// ---------- Resend email ----------

async fn send_otp_email(
    config: &Arc<Config>,
    email: &str,
    code: &str,
) -> Result<(), (StatusCode, String)> {
    let html = format!(
        r#"<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
<body style="margin:0;padding:0;background-color:#0a0a0f;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background-color:#0a0a0f;padding:40px 20px;">
    <tr><td align="center">
      <table width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;">
        <tr><td style="padding-bottom:32px;">
          <span style="font-size:24px;font-weight:bold;color:#ffffff;">fazm</span><span style="font-size:24px;font-weight:bold;color:#8B5CF6;">.</span>
        </td></tr>
        <tr><td style="padding-bottom:16px;">
          <h1 style="margin:0;font-size:28px;font-weight:bold;color:#ffffff;line-height:1.3;">Your sign-in code</h1>
        </td></tr>
        <tr><td style="padding-bottom:24px;color:#94a3b8;font-size:16px;line-height:1.6;">
          Enter this code in the Fazm app to sign in. It expires in 10 minutes.
        </td></tr>
        <tr><td style="padding-bottom:32px;">
          <div style="display:inline-block;padding:18px 28px;background:#1e1b2e;border:1px solid #2d2640;border-radius:12px;">
            <span style="font-size:32px;font-weight:700;letter-spacing:8px;color:#ffffff;font-family:'SF Mono','Menlo','Monaco',monospace;">{code}</span>
          </div>
        </td></tr>
        <tr><td style="padding-bottom:24px;color:#64748b;font-size:14px;line-height:1.5;">
          If you didn't request this, you can safely ignore this email; someone may have typed your address by mistake.
        </td></tr>
        <tr><td style="border-top:1px solid #1e293b;padding-top:24px;color:#475569;font-size:13px;line-height:1.5;">
          <a href="https://fazm.ai" style="color:#8B5CF6;text-decoration:none;">fazm.ai</a> — AI computer agent for macOS.
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>"#
    );

    let resp = reqwest::Client::new()
        .post("https://api.resend.com/emails")
        .header("Authorization", format!("Bearer {}", config.resend_api_key))
        .json(&serde_json::json!({
            "from": "Fazm <matt@fazm.ai>",
            "to": email,
            "subject": format!("Your Fazm sign-in code: {code}"),
            "html": html,
        }))
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Resend send error: {e}")))?;

    if !resp.status().is_success() {
        let err = resp.text().await.unwrap_or_default();
        tracing::error!(error = %err, "Resend email failed");
        return Err((
            StatusCode::BAD_GATEWAY,
            "Failed to send email".to_string(),
        ));
    }

    Ok(())
}

// ---------- Helpers ----------

fn normalize_email(input: &str) -> Option<String> {
    let trimmed = input.trim().to_lowercase();
    if trimmed.is_empty() || !trimmed.contains('@') || trimmed.len() > 320 {
        return None;
    }
    // Reject characters that would break Firestore document IDs or be obviously invalid.
    if trimmed
        .chars()
        .any(|c| c.is_whitespace() || c == '/' || c == '\\' || c == '#' || c == '?')
    {
        return None;
    }
    Some(trimmed)
}

fn redact_email(email: &str) -> String {
    if let Some((local, domain)) = email.split_once('@') {
        let head: String = local.chars().take(2).collect();
        format!("{head}***@{domain}")
    } else {
        "***".to_string()
    }
}

/// Generates a 6-digit OTP using SystemTime nanoseconds mixed via a small PRNG.
/// 1e6 keyspace + 10-min TTL + 5-attempt cap makes brute force impractical.
fn generate_otp() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let mut n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    // SplitMix64
    n = n.wrapping_add(0x9E3779B97F4A7C15);
    n = (n ^ (n >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
    n = (n ^ (n >> 27)).wrapping_mul(0x94D049BB133111EB);
    n = n ^ (n >> 31);
    let six = (n % 1_000_000) as u32;
    format!("{six:06}")
}

fn sha256_hex(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    hex::encode(hasher.finalize())
}

fn constant_time_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for (x, y) in a.bytes().zip(b.bytes()) {
        diff |= x ^ y;
    }
    diff == 0
}
