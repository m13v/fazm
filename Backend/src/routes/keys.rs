use axum::{extract::Extension, http::StatusCode, response::IntoResponse, Json};
use serde::Serialize;
use std::sync::Arc;

use crate::auth::AuthDevice;
use crate::config::Config;

#[derive(Serialize)]
pub struct KeysResponse {
    pub anthropic_api_key: String,
    pub deepgram_api_key: String,
    pub gemini_api_key: String,
}

/// POST /v1/keys
/// Returns API keys to authenticated clients.
/// If the user is on the builtin key blocklist, the anthropic_api_key is returned empty,
/// which triggers the client to prompt for a personal Claude account.
pub async fn get_keys(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
) -> Result<impl IntoResponse, StatusCode> {
    if config.anthropic_api_key.is_empty() && config.deepgram_api_key.is_empty() {
        tracing::warn!("Both ANTHROPIC_API_KEY and DEEPGRAM_API_KEY are unset");
    }

    let blocked = if config.builtin_key_blocklist.iter().any(|s| s == "*") {
        tracing::info!(device_id = %auth.device_id, uid = ?auth.firebase_uid, "Global builtin key kill switch active");
        true
    } else {
        let uid_blocked = auth
            .firebase_uid
            .as_ref()
            .map(|uid| config.builtin_key_blocklist.contains(uid))
            .unwrap_or(false);
        let device_blocked = config.builtin_key_blocklist.contains(&auth.device_id);
        if uid_blocked || device_blocked {
            tracing::info!(device_id = %auth.device_id, uid = ?auth.firebase_uid, "User blocked from builtin API key");
        }
        uid_blocked || device_blocked
    };

    Ok(Json(KeysResponse {
        anthropic_api_key: if blocked {
            String::new()
        } else {
            config.anthropic_api_key.clone()
        },
        deepgram_api_key: config.deepgram_api_key.clone(),
        gemini_api_key: config.gemini_api_key.clone(),
    }))
}
