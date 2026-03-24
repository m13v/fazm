"use client";

import { useState, useEffect, useCallback } from "react";
import { getFirebaseAuth, googleProvider, signInWithRedirect, getRedirectResult, onAuthStateChanged, type User } from "./firebase";

export function useAuth() {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [token, setToken] = useState<string | null>(null);

  useEffect(() => {
    const auth = getFirebaseAuth();
    // Handle redirect result (from mobile sign-in flow)
    getRedirectResult(auth).catch(() => {});
    const unsubscribe = onAuthStateChanged(auth, async (user) => {
      setUser(user);
      if (user) {
        const t = await user.getIdToken();
        setToken(t);
      } else {
        setToken(null);
      }
      setLoading(false);
    });
    return unsubscribe;
  }, []);

  // Refresh token periodically (Firebase tokens expire after 1 hour)
  useEffect(() => {
    if (!user) return;
    const interval = setInterval(async () => {
      const t = await user.getIdToken(true);
      setToken(t);
    }, 50 * 60 * 1000); // refresh every 50 minutes
    return () => clearInterval(interval);
  }, [user]);

  const signIn = useCallback(async () => {
    const auth = getFirebaseAuth();
    await signInWithRedirect(auth, googleProvider);
  }, []);

  const signOut = useCallback(async () => {
    const auth = getFirebaseAuth();
    await auth.signOut();
  }, []);

  return { user, loading, token, signIn, signOut };
}
