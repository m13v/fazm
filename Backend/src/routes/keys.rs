use axum::{extract::Extension, http::StatusCode, response::IntoResponse, Json};
use serde::Serialize;
use std::sync::Arc;

use crate::auth::AuthDevice;
use crate::config::Config;
use crate::routes::stripe::lookup_subscription_status;

#[derive(Serialize)]
pub struct KeysResponse {
    pub anthropic_api_key: String,
    pub deepgram_api_key: String,
    pub gemini_api_key: String,
    pub elevenlabs_api_key: String,
}

/// POST /v1/keys
/// Returns API keys to authenticated clients.
///
/// The bundled `anthropic_api_key` is gated on an active Stripe subscription
/// (status `active` or `trialing`). Non-subscribers, blocklisted users, or
/// clients we can't verify against Stripe receive an empty `anthropic_api_key`,
/// which the desktop client treats as a signal to prompt for a personal Claude
/// account. Deepgram/Gemini/ElevenLabs keys are unaffected.
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

    // Subscription gate. Blocked users short-circuit to false (no Stripe call needed).
    // Stripe lookup errors fail closed so a transient outage can't unlock the bundled
    // key for non-subscribers. Paying users will still see their subscription_status
    // route succeed independently and the desktop UI handles the empty-key case the
    // same way it handles the blocklist.
    let subscription_active = if blocked {
        false
    } else {
        match lookup_subscription_status(&config, &auth).await {
            Ok(s) => s.active,
            Err((status, msg)) => {
                tracing::error!(
                    device_id = %auth.device_id,
                    uid = ?auth.firebase_uid,
                    error = %msg,
                    stripe_status = %status,
                    "Subscription lookup failed; failing closed (empty Anthropic key)"
                );
                false
            }
        }
    };

    let serve_anthropic = !blocked && subscription_active;
    if !serve_anthropic && !blocked {
        tracing::info!(
            device_id = %auth.device_id,
            uid = ?auth.firebase_uid,
            "Withholding builtin Anthropic key — no active Stripe subscription"
        );
    }

    Ok(Json(KeysResponse {
        anthropic_api_key: if serve_anthropic {
            config.anthropic_api_key.clone()
        } else {
            String::new()
        },
        deepgram_api_key: config.deepgram_api_key.clone(),
        gemini_api_key: config.gemini_api_key.clone(),
        elevenlabs_api_key: config.elevenlabs_api_key.clone(),
    }))
}
