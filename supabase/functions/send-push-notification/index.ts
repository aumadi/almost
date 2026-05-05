// =============================================================================
// Almost App — send-push-notification Edge Function
// =============================================================================
// Triggered by a Supabase Database Webhook on INSERT into public.notifications.
// Looks up the recipient's active devices, mints an OAuth access token from
// the Firebase service account, and pushes via FCM HTTP v1.
//
// Required environment / secrets:
//   FIREBASE_SERVICE_ACCOUNT_JSON  — full JSON content of the Firebase
//                                     service account key (one-line string)
//   SUPABASE_URL                   — provided automatically by Supabase
//   SUPABASE_SERVICE_ROLE_KEY      — provided automatically by Supabase
//
// Set FIREBASE_SERVICE_ACCOUNT_JSON via:
//   npx supabase secrets set FIREBASE_SERVICE_ACCOUNT_JSON="$(cat path/to/key.json)"
//
// Deploy:
//   npx supabase functions deploy send-push-notification
//
// Webhook setup (Supabase Dashboard):
//   Database → Webhooks → Create
//     Table: notifications
//     Events: Insert
//     Type: Supabase Edge Function
//     Function: send-push-notification
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// ----------------------------- Types ----------------------------------------

interface NotificationRecord {
  id: string;
  user_id: string;
  type:
    | "connection_request_received"
    | "connection_accepted"
    | "new_message"
    | "trip_starts_tomorrow";
  related_user_id: string | null;
  related_trip_id: string | null;
  related_chat_id: string | null;
  is_read: boolean;
  created_at: string;
  deleted_at: string | null;
}

interface WebhookPayload {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  schema: string;
  record: NotificationRecord;
  old_record: NotificationRecord | null;
}

interface ServiceAccount {
  type: string;
  project_id: string;
  private_key_id: string;
  private_key: string;
  client_email: string;
  client_id: string;
  auth_uri: string;
  token_uri: string;
}

interface PushPayload {
  title: string;
  body: string;
}

// --------------------------- JWT / OAuth ------------------------------------

function base64UrlEncode(input: string | Uint8Array): string {
  const bytes =
    typeof input === "string" ? new TextEncoder().encode(input) : input;
  let str = "";
  for (let i = 0; i < bytes.length; i++) str += String.fromCharCode(bytes[i]);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const cleaned = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const binary = atob(cleaned);
  const buffer = new ArrayBuffer(binary.length);
  const view = new Uint8Array(buffer);
  for (let i = 0; i < binary.length; i++) view[i] = binary.charCodeAt(i);
  return buffer;
}

async function getFcmAccessToken(serviceAccount: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT", kid: serviceAccount.private_key_id };
  const claim = {
    iss: serviceAccount.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    exp: now + 3600,
    iat: now,
  };

  const headerB64 = base64UrlEncode(JSON.stringify(header));
  const claimB64 = base64UrlEncode(JSON.stringify(claim));
  const message = `${headerB64}.${claimB64}`;

  const keyBuffer = pemToArrayBuffer(serviceAccount.private_key);
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    keyBuffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const signatureBuffer = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(message),
  );
  const signature = base64UrlEncode(new Uint8Array(signatureBuffer));
  const jwt = `${message}.${signature}`;

  const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  if (!tokenResponse.ok) {
    throw new Error(
      `OAuth token request failed: ${tokenResponse.status} ${await tokenResponse.text()}`,
    );
  }

  const tokenData = await tokenResponse.json();
  return tokenData.access_token as string;
}

// ----------------------------- Push payload --------------------------------

function buildPushPayload(
  notification: NotificationRecord,
  senderFirstName: string | null,
  airportIata: string | null,
): PushPayload {
  const sender = senderFirstName ?? "Someone";
  switch (notification.type) {
    case "connection_request_received":
      return {
        title: "New connection request",
        body: airportIata
          ? `${sender} wants to connect from your ${airportIata} trip`
          : `${sender} wants to connect`,
      };
    case "connection_accepted":
      return {
        title: "Connection accepted",
        body: `You're connected with ${sender}. Chat is open.`,
      };
    case "new_message":
      return {
        title: sender,
        body: `New message from ${sender}.`,
      };
    case "trip_starts_tomorrow":
      return {
        title: "Trip reminder",
        body: airportIata
          ? `Your trip to ${airportIata} starts tomorrow.`
          : "Your trip starts tomorrow.",
      };
    default:
      return { title: "Almost", body: "You have a new notification." };
  }
}

// ------------------------- Main HTTP handler --------------------------------

Deno.serve(async (req: Request) => {
  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
    const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const FIREBASE_SERVICE_ACCOUNT_JSON = Deno.env.get(
      "FIREBASE_SERVICE_ACCOUNT_JSON",
    );

    if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
      throw new Error("Missing Supabase environment variables");
    }
    if (!FIREBASE_SERVICE_ACCOUNT_JSON) {
      throw new Error("Missing FIREBASE_SERVICE_ACCOUNT_JSON secret");
    }

    const payload: WebhookPayload = await req.json();

    if (payload.type !== "INSERT" || payload.table !== "notifications") {
      return new Response(
        JSON.stringify({ skipped: "not a notifications INSERT" }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }

    const notification = payload.record;
    const serviceAccount: ServiceAccount = JSON.parse(
      FIREBASE_SERVICE_ACCOUNT_JSON,
    );
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // 1. Look up active devices for the recipient.
    const { data: devices, error: devicesError } = await supabase
      .from("user_devices")
      .select("id, fcm_token")
      .eq("user_id", notification.user_id)
      .is("deleted_at", null);

    if (devicesError) throw devicesError;
    if (!devices || devices.length === 0) {
      return new Response(
        JSON.stringify({ skipped: "no active devices for user" }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }

    // 2. Lookup sender first_name for personalization (if applicable).
    let senderFirstName: string | null = null;
    if (notification.related_user_id) {
      const { data: sender } = await supabase
        .from("profiles")
        .select("first_name")
        .eq("id", notification.related_user_id)
        .maybeSingle();
      senderFirstName = sender?.first_name ?? null;
    }

    // 3. Lookup trip airport IATA (departure for request_received,
    //    arrival for trip_starts_tomorrow).
    let airportIata: string | null = null;
    if (notification.related_trip_id) {
      const { data: trip } = await supabase
        .from("trips")
        .select("departure_airport_id, arrival_airport_id")
        .eq("id", notification.related_trip_id)
        .maybeSingle();
      if (trip) {
        const airportId =
          notification.type === "trip_starts_tomorrow"
            ? trip.arrival_airport_id
            : trip.departure_airport_id;
        if (airportId) {
          const { data: airport } = await supabase
            .from("airports")
            .select("iata_code")
            .eq("id", airportId)
            .maybeSingle();
          airportIata = airport?.iata_code ?? null;
        }
      }
    }

    const { title, body } = buildPushPayload(
      notification,
      senderFirstName,
      airportIata,
    );

    // 4. Mint an FCM access token from the service account.
    const accessToken = await getFcmAccessToken(serviceAccount);
    const fcmEndpoint =
      `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`;

    // 5. Send to each device. Soft-delete tokens FCM rejects as invalid.
    const sendResults = await Promise.allSettled(
      devices.map(async (device: { id: string; fcm_token: string }) => {
        const fcmResponse = await fetch(fcmEndpoint, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${accessToken}`,
          },
          body: JSON.stringify({
            message: {
              token: device.fcm_token,
              notification: { title, body },
              data: {
                notification_id: notification.id,
                type: notification.type,
                related_user_id: notification.related_user_id ?? "",
                related_chat_id: notification.related_chat_id ?? "",
                related_trip_id: notification.related_trip_id ?? "",
              },
            },
          }),
        });

        if (!fcmResponse.ok) {
          const errorBody = await fcmResponse.text();
          // Tokens FCM reports as invalid get soft-deleted so we don't keep
          // trying them. Any 4xx with UNREGISTERED / INVALID_ARGUMENT means
          // the device removed the app or the token rotated.
          const isInvalidToken =
            fcmResponse.status === 404 ||
            errorBody.includes("UNREGISTERED") ||
            errorBody.includes("INVALID_ARGUMENT") ||
            errorBody.includes("registration-token-not-registered");
          if (isInvalidToken) {
            await supabase
              .from("user_devices")
              .update({ deleted_at: new Date().toISOString() })
              .eq("id", device.id);
          }
          throw new Error(`FCM ${fcmResponse.status}: ${errorBody}`);
        }
        return device.fcm_token;
      }),
    );

    const sent = sendResults.filter((r) => r.status === "fulfilled").length;
    const failed = sendResults.filter((r) => r.status === "rejected").length;

    return new Response(
      JSON.stringify({ sent, failed, total: devices.length }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (error) {
    console.error("Push notification error:", error);
    return new Response(
      JSON.stringify({ error: (error as Error).message }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
