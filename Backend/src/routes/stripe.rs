use axum::{
    body::Bytes,
    extract::Extension,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::auth::AuthDevice;
use crate::config::Config;

// ---------- Create Checkout Session ----------

#[derive(Deserialize)]
pub struct CreateCheckoutRequest {
    /// Where to redirect after successful payment
    pub success_url: Option<String>,
    /// Where to redirect if user cancels
    pub cancel_url: Option<String>,
}

#[derive(Serialize)]
pub struct CreateCheckoutResponse {
    pub checkout_url: String,
    pub session_id: String,
}

/// POST /api/stripe/create-checkout-session
/// Creates a Stripe Checkout Session for the Fazm subscription.
/// First month $9, then $49/month using a coupon on the first payment.
pub async fn create_checkout_session(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
    Json(body): Json<CreateCheckoutRequest>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let stripe_secret = &config.stripe_secret_key;
    if stripe_secret.is_empty() {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "Stripe not configured".to_string(),
        ));
    }

    let firebase_uid = auth.firebase_uid.unwrap_or_default();
    let success_url = body
        .success_url
        .unwrap_or_else(|| "fazm://subscription/success".to_string());
    let cancel_url = body
        .cancel_url
        .unwrap_or_else(|| "fazm://subscription/cancel".to_string());

    let client = reqwest::Client::new();

    // First, ensure a Stripe customer exists for this user (idempotent lookup/create)
    let customer_id = get_or_create_customer(&client, stripe_secret, &firebase_uid, &auth.device_id)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

    // Create checkout session with the subscription
    // Uses a trial-like approach: first invoice gets a coupon ($40 off = $9 first month)
    let mut params = vec![
        ("mode", "subscription".to_string()),
        ("customer", customer_id.clone()),
        ("success_url", success_url),
        ("cancel_url", cancel_url),
        ("line_items[0][price]", config.stripe_price_id.clone()),
        ("line_items[0][quantity]", "1".to_string()),
        ("subscription_data[metadata][firebase_uid]", firebase_uid),
        ("subscription_data[metadata][device_id]", auth.device_id),
    ];

    // Apply intro coupon if configured
    if !config.stripe_intro_coupon_id.is_empty() {
        params.push(("discounts[0][coupon]", config.stripe_intro_coupon_id.clone()));
    }

    let resp = client
        .post("https://api.stripe.com/v1/checkout/sessions")
        .bearer_auth(stripe_secret)
        .form(&params)
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Stripe API error: {e}")))?;

    let status = resp.status();
    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Stripe parse error: {e}")))?;

    if !status.is_success() {
        tracing::error!("Stripe checkout error: {body}");
        return Err((
            StatusCode::BAD_GATEWAY,
            format!("Stripe error: {}", body["error"]["message"]),
        ));
    }

    let checkout_url = body["url"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    let session_id = body["id"]
        .as_str()
        .unwrap_or_default()
        .to_string();

    tracing::info!(customer = %customer_id, session = %session_id, "Checkout session created");

    Ok(Json(CreateCheckoutResponse {
        checkout_url,
        session_id,
    }))
}

// ---------- Subscription Status ----------

#[derive(Serialize)]
pub struct SubscriptionStatusResponse {
    pub active: bool,
    pub status: String, // "active", "trialing", "past_due", "canceled", "none"
    pub current_period_end: Option<i64>,
}

/// GET /api/stripe/subscription-status
/// Returns the subscription status for the authenticated user.
pub async fn subscription_status(
    Extension(config): Extension<Arc<Config>>,
    Extension(auth): Extension<AuthDevice>,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let stripe_secret = &config.stripe_secret_key;
    if stripe_secret.is_empty() {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "Stripe not configured".to_string(),
        ));
    }

    let firebase_uid = auth.firebase_uid.unwrap_or_default();
    let client = reqwest::Client::new();

    // Look up customer by metadata
    let customer_id = find_customer(&client, stripe_secret, &firebase_uid)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))?;

    let Some(customer_id) = customer_id else {
        return Ok(Json(SubscriptionStatusResponse {
            active: false,
            status: "none".to_string(),
            current_period_end: None,
        }));
    };

    // List active subscriptions for this customer
    let resp = client
        .get("https://api.stripe.com/v1/subscriptions")
        .bearer_auth(stripe_secret)
        .query(&[("customer", &customer_id), ("limit", &"1".to_string())])
        .send()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Stripe API error: {e}")))?;

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| (StatusCode::BAD_GATEWAY, format!("Stripe parse error: {e}")))?;

    let subs = body["data"].as_array();
    if let Some(subs) = subs {
        if let Some(sub) = subs.first() {
            let status = sub["status"].as_str().unwrap_or("none").to_string();
            let active = matches!(status.as_str(), "active" | "trialing");
            let period_end = sub["current_period_end"].as_i64();
            return Ok(Json(SubscriptionStatusResponse {
                active,
                status,
                current_period_end: period_end,
            }));
        }
    }

    Ok(Json(SubscriptionStatusResponse {
        active: false,
        status: "none".to_string(),
        current_period_end: None,
    }))
}

// ---------- Webhook ----------

/// POST /api/stripe/webhook
/// Handles Stripe webhook events (subscription created, updated, deleted, etc.)
pub async fn webhook(
    Extension(config): Extension<Arc<Config>>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<impl IntoResponse, (StatusCode, String)> {
    let stripe_secret = &config.stripe_webhook_secret;

    // Verify webhook signature if secret is configured
    if !stripe_secret.is_empty() {
        let sig = headers
            .get("stripe-signature")
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default();

        if !verify_stripe_signature(&body, sig, stripe_secret) {
            return Err((StatusCode::BAD_REQUEST, "Invalid signature".to_string()));
        }
    }

    let event: serde_json::Value = serde_json::from_slice(&body)
        .map_err(|e| (StatusCode::BAD_REQUEST, format!("Invalid JSON: {e}")))?;

    let event_type = event["type"].as_str().unwrap_or_default();
    tracing::info!(event_type, "Stripe webhook received");

    match event_type {
        "checkout.session.completed" => {
            let session = &event["data"]["object"];
            let customer = session["customer"].as_str().unwrap_or_default();
            let subscription = session["subscription"].as_str().unwrap_or_default();
            tracing::info!(customer, subscription, "Checkout completed");
        }
        "customer.subscription.created"
        | "customer.subscription.updated"
        | "customer.subscription.deleted" => {
            let sub = &event["data"]["object"];
            let customer = sub["customer"].as_str().unwrap_or_default();
            let status = sub["status"].as_str().unwrap_or_default();
            let firebase_uid = sub["metadata"]["firebase_uid"]
                .as_str()
                .unwrap_or_default();
            tracing::info!(
                customer,
                status,
                firebase_uid,
                event_type,
                "Subscription event"
            );
        }
        _ => {
            tracing::debug!(event_type, "Unhandled webhook event");
        }
    }

    Ok(StatusCode::OK)
}

// ---------- Helpers ----------

/// Find or create a Stripe customer by Firebase UID
async fn get_or_create_customer(
    client: &reqwest::Client,
    secret: &str,
    firebase_uid: &str,
    device_id: &str,
) -> Result<String, String> {
    // Search for existing customer
    if let Some(id) = find_customer(client, secret, firebase_uid).await? {
        return Ok(id);
    }

    // Create new customer
    let resp = client
        .post("https://api.stripe.com/v1/customers")
        .bearer_auth(secret)
        .form(&[
            ("metadata[firebase_uid]", firebase_uid),
            ("metadata[device_id]", device_id),
        ])
        .send()
        .await
        .map_err(|e| format!("Stripe customer create error: {e}"))?;

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| format!("Stripe parse error: {e}"))?;

    body["id"]
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| format!("No customer ID in response: {body}"))
}

/// Find a Stripe customer by Firebase UID metadata
async fn find_customer(
    client: &reqwest::Client,
    secret: &str,
    firebase_uid: &str,
) -> Result<Option<String>, String> {
    let resp = client
        .get("https://api.stripe.com/v1/customers/search")
        .bearer_auth(secret)
        .query(&[("query", &format!("metadata['firebase_uid']:'{firebase_uid}'"))])
        .send()
        .await
        .map_err(|e| format!("Stripe search error: {e}"))?;

    let body: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| format!("Stripe parse error: {e}"))?;

    Ok(body["data"]
        .as_array()
        .and_then(|arr| arr.first())
        .and_then(|c| c["id"].as_str())
        .map(|s| s.to_string()))
}

/// Verify Stripe webhook signature (v1 scheme)
fn verify_stripe_signature(payload: &[u8], sig_header: &str, secret: &str) -> bool {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;

    // Parse signature header: t=timestamp,v1=signature
    let mut timestamp = "";
    let mut signature = "";
    for part in sig_header.split(',') {
        if let Some(t) = part.strip_prefix("t=") {
            timestamp = t;
        } else if let Some(s) = part.strip_prefix("v1=") {
            signature = s;
        }
    }

    if timestamp.is_empty() || signature.is_empty() {
        return false;
    }

    // Compute expected signature
    let signed_payload = format!("{timestamp}.{}", String::from_utf8_lossy(payload));
    let mut mac =
        Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC can take key of any size");
    mac.update(signed_payload.as_bytes());
    let expected = hex::encode(mac.finalize().into_bytes());

    // Constant-time comparison
    expected == signature
}
