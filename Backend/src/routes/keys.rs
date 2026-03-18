use axum::{extract::Extension, http::StatusCode, response::IntoResponse, Json};
use serde::Serialize;
use std::sync::Arc;

use crate::config::Config;

#[derive(Serialize)]
pub struct KeysResponse {
    pub anthropic_api_key: String,
    pub deepgram_api_key: String,
    pub gemini_api_key: String,
}

/// POST /v1/keys
/// Returns API keys to authenticated clients.
pub async fn get_keys(
    Extension(config): Extension<Arc<Config>>,
) -> Result<impl IntoResponse, StatusCode> {
    if config.anthropic_api_key.is_empty() && config.deepgram_api_key.is_empty() {
        tracing::warn!("Both ANTHROPIC_API_KEY and DEEPGRAM_API_KEY are unset");
    }

    Ok(Json(KeysResponse {
        anthropic_api_key: config.anthropic_api_key.clone(),
        deepgram_api_key: config.deepgram_api_key.clone(),
        gemini_api_key: config.gemini_api_key.clone(),
    }))
}
