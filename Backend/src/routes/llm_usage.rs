use axum::{extract::Extension, http::StatusCode, response::IntoResponse, Json};
use serde::{Deserialize, Serialize};
use std::{sync::Arc, time::Duration};

use crate::auth::AuthDevice;
use crate::config::Config;

#[derive(Debug, Deserialize)]
pub struct ForwardLlmUsageRequest {
    pub model: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub total_tokens: i64,
    pub source: String,
}

#[derive(Debug, Serialize)]
struct MediarUsageForwardRequest {
    firebase_uid: String,
    email: Option<String>,
    model: String,
    input_tokens: i64,
    output_tokens: i64,
    total_tokens: i64,
    source: String,
}

/// POST /v1/llm-usage/mediar-forward
/// Forwards authenticated Fazm LLM usage into Mediar's dashboard ingestion endpoint.
pub async fn forward_to_mediar(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
    Json(payload): Json<ForwardLlmUsageRequest>,
) -> Result<impl IntoResponse, StatusCode> {
    if payload.model.trim().is_empty() || payload.source.trim().is_empty() {
        return Err(StatusCode::BAD_REQUEST);
    }

    if payload.input_tokens < 0 || payload.output_tokens < 0 || payload.total_tokens < 0 {
        return Err(StatusCode::BAD_REQUEST);
    }

    let firebase_uid = auth.firebase_uid.clone().ok_or(StatusCode::UNAUTHORIZED)?;

    if config.mediar_usage_ingest_url.is_empty() || config.mediar_usage_ingest_secret.is_empty() {
        tracing::warn!("Mediar usage forwarding is not configured");
        return Err(StatusCode::SERVICE_UNAVAILABLE);
    }

    let request_body = MediarUsageForwardRequest {
        firebase_uid: firebase_uid.clone(),
        email: auth.firebase_email.clone(),
        model: payload.model,
        input_tokens: payload.input_tokens,
        output_tokens: payload.output_tokens,
        total_tokens: payload.total_tokens,
        source: payload.source,
    };

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|error| {
            tracing::error!("Failed to build Mediar forwarding client: {}", error);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let response = client
        .post(&config.mediar_usage_ingest_url)
        .header("content-type", "application/json")
        .header("x-fazm-shared-secret", &config.mediar_usage_ingest_secret)
        .json(&request_body)
        .send()
        .await
        .map_err(|error| {
            tracing::error!(uid = %firebase_uid, "Failed to forward usage to Mediar: {}", error);
            StatusCode::BAD_GATEWAY
        })?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        tracing::error!(
            uid = %firebase_uid,
            status = %status,
            body = %body,
            "Mediar usage forward failed"
        );
        return Err(StatusCode::BAD_GATEWAY);
    }

    Ok(StatusCode::ACCEPTED)
}
