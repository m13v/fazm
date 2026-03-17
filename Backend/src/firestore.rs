/// Minimal Firestore REST API client using service account JWT auth.
///
/// Uses the same private key as the Vertex AI integration (VERTEX_SA_PRIVATE_KEY_PEM)
/// to obtain a Google API access token via the OAuth2 JWT bearer grant, then reads
/// and writes documents via the Firestore REST API.
use crate::config::Config;
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const FIRESTORE_SCOPE: &str = "https://www.googleapis.com/auth/datastore";
const COLLECTION: &str = "desktop_releases";

// ─── Token exchange ───────────────────────────────────────────────────────────

#[derive(Serialize)]
struct GoogleJwtClaims {
    iss: String,
    scope: String,
    aud: String,
    iat: i64,
    exp: i64,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
}

pub async fn get_access_token(
    config: &Arc<Config>,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let now = chrono::Utc::now().timestamp();

    let claims = GoogleJwtClaims {
        iss: config.gcp_service_account.clone(),
        scope: FIRESTORE_SCOPE.to_string(),
        aud: TOKEN_URL.to_string(),
        iat: now,
        exp: now + 3600,
    };

    let key = EncodingKey::from_rsa_pem(config.vertex_sa_private_key_pem.as_bytes())?;
    let mut header = Header::new(Algorithm::RS256);
    header.typ = Some("JWT".to_string());

    let jwt = encode(&header, &claims, &key)?;

    let client = reqwest::Client::new();
    let resp: TokenResponse = client
        .post(TOKEN_URL)
        .form(&[
            ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
            ("assertion", &jwt),
        ])
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    Ok(resp.access_token)
}

// ─── Firestore document model ─────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReleaseDoc {
    pub tag: String,
    pub version: String,
    pub build: String,
    pub channel: String, // "staging" | "beta" | "stable"
    pub is_live: bool,
}

// ─── Firestore REST helpers ───────────────────────────────────────────────────

fn firestore_base(project_id: &str) -> String {
    format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents/{}",
        project_id, COLLECTION
    )
}

/// Convert a ReleaseDoc to Firestore REST document fields.
fn to_firestore_fields(doc: &ReleaseDoc) -> serde_json::Value {
    serde_json::json!({
        "fields": {
            "tag":     { "stringValue": doc.tag },
            "version": { "stringValue": doc.version },
            "build":   { "stringValue": doc.build },
            "channel": { "stringValue": doc.channel },
            "is_live": { "booleanValue": doc.is_live },
        }
    })
}

/// Extract a string field from a Firestore document.
fn str_field(fields: &serde_json::Value, key: &str) -> String {
    fields[key]["stringValue"]
        .as_str()
        .unwrap_or("")
        .to_string()
}

/// Parse a Firestore REST document into a ReleaseDoc.
fn from_firestore_doc(doc: &serde_json::Value) -> Option<ReleaseDoc> {
    let fields = doc.get("fields")?;
    Some(ReleaseDoc {
        tag: str_field(fields, "tag"),
        version: str_field(fields, "version"),
        build: str_field(fields, "build"),
        channel: str_field(fields, "channel"),
        is_live: fields["is_live"]["booleanValue"]
            .as_bool()
            .unwrap_or(false),
    })
}

// ─── Public CRUD operations ───────────────────────────────────────────────────

/// Create or overwrite a release document (doc ID = tag).
pub async fn upsert_release(
    config: &Arc<Config>,
    token: &str,
    doc: &ReleaseDoc,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let url = format!(
        "{}/{}",
        firestore_base(&config.firebase_project_id),
        urlencoding::encode(&doc.tag)
    );

    let body = to_firestore_fields(doc);

    reqwest::Client::new()
        .patch(&url)
        .bearer_auth(token)
        .json(&body)
        .send()
        .await?
        .error_for_status()?;

    Ok(())
}

/// Fetch a single release document by tag.
pub async fn get_release(
    config: &Arc<Config>,
    token: &str,
    tag: &str,
) -> Result<Option<ReleaseDoc>, Box<dyn std::error::Error + Send + Sync>> {
    let url = format!(
        "{}/{}",
        firestore_base(&config.firebase_project_id),
        urlencoding::encode(tag)
    );

    let resp = reqwest::Client::new()
        .get(&url)
        .bearer_auth(token)
        .send()
        .await?;

    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(None);
    }

    let doc: serde_json::Value = resp.error_for_status()?.json().await?;
    Ok(from_firestore_doc(&doc))
}

/// List all live release documents, ordered by descending build number.
pub async fn list_live_releases(
    config: &Arc<Config>,
    token: &str,
) -> Result<Vec<ReleaseDoc>, Box<dyn std::error::Error + Send + Sync>> {
    // Firestore REST: structured query to filter is_live == true
    let url = format!(
        "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents:runQuery",
        config.firebase_project_id
    );

    let query = serde_json::json!({
        "structuredQuery": {
            "from": [{ "collectionId": COLLECTION }],
            "where": {
                "fieldFilter": {
                    "field": { "fieldPath": "is_live" },
                    "op": "EQUAL",
                    "value": { "booleanValue": true }
                }
            },
            "limit": 20
        }
    });

    let resp: serde_json::Value = reqwest::Client::new()
        .post(&url)
        .bearer_auth(token)
        .json(&query)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    let mut docs: Vec<ReleaseDoc> = resp
        .as_array()
        .unwrap_or(&vec![])
        .iter()
        .filter_map(|r| r.get("document").and_then(|d| from_firestore_doc(d)))
        .collect();

    // Sort by build number descending
    docs.sort_by(|a, b| {
        let ba: u64 = a.build.parse().unwrap_or(0);
        let bb: u64 = b.build.parse().unwrap_or(0);
        bb.cmp(&ba)
    });

    Ok(docs)
}
