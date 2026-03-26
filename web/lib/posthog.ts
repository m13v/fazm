"use client";

import posthog from "posthog-js";

const POSTHOG_KEY = "phc_TWwTa7D5GcjE4PprY55tJVfPKBC7kmLGiFUDZxBbYRQ";
const POSTHOG_HOST = "https://us.i.posthog.com";

let initialized = false;

export function initPostHog() {
  if (initialized || typeof window === "undefined") return;
  posthog.init(POSTHOG_KEY, {
    api_host: POSTHOG_HOST,
    capture_pageview: true,
    capture_pageleave: true,
    persistence: "localStorage",
  });
  initialized = true;
}

export function identifyUser(userId: string, email: string) {
  initPostHog();
  posthog.identify(userId, { email });
}

export function resetUser() {
  posthog.reset();
}

export function trackEvent(event: string, properties?: Record<string, unknown>) {
  initPostHog();
  posthog.capture(event, { source: "web", ...properties });
}
