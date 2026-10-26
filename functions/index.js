/**
 * Generic background alerts, with private device authorization and durable
 * duplicate suppression. Actual inspection/lab contents stay in Firestore
 * and are read inside the app under the existing role permissions.
 */
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const {deliverPush, buildNotifyRequestConsumer} = require("./push_delivery");
const {createSubmitCommand} = require("./command_submit");
const {createCentralSync} = require("./central_sync");
admin.initializeApp();

// ── Central command protocol (SYNC_ARCHITECTURE_PLAN_2026-10-25 §6) ────────
// The ONLY approved write path for the new protocol: receipts, transactions,
// official counters. Client writes to commandReceipts/changeEvents/counters/
// notifyRequests are denied by firestore.rules (read-only or nothing).
exports.submitCommand = createSubmitCommand(admin);
exports.readCentralSync = createCentralSync(admin);

function recordCreated(kind) {
  return async (event) => {
    const data = event.data && event.data.data ? event.data.data() : {};
    // Organization transition (blocking 4): a document written through the
    // central command path already produced its own notifyRequest. The legacy
    // onCreate triggers must stay silent for it, or every central commit
    // would fan out twice - once per channel.
    if (data.protocol && data.protocol.operationId) return;
    const rawCreated = data.createdAt || data.created_at || "";
    const createdAt = rawCreated && typeof rawCreated.toDate === "function"
      ? rawCreated.toDate().toISOString() : rawCreated;
    await deliverPush(admin.firestore(), admin.messaging(), {
      organizationId: event.params.orgId,
      remoteId: data.remoteId || data.remote_id || event.params.docId,
      sourceDeviceId: data.deviceId || "",
      kind,
      createdAt,
      deletedAt: data.deletedAt || data.deleted_at || null,
    });
  };
}

/** Central notification consumer (blocking 4): the ONE path that turns a
 * committed central operation into generic push alerts. see
 * push_delivery.buildNotifyRequestConsumer.
 */
exports.onNotifyRequestCreated = onDocumentCreated(
  {document: "organizations/{orgId}/notifyRequests/{requestId}", retry: true},
  async (event) => {
    const data = event.data && event.data.data ? event.data.data() : {};
    await buildNotifyRequestConsumer(admin.firestore(), admin.messaging())({
      orgId: event.params.orgId,
      requestId: event.params.requestId,
      data,
    });
  },
);
exports.onSampleCreated = onDocumentCreated(
  {document: "organizations/{orgId}/samples/{docId}", retry: true},
  recordCreated("inspection"),
);
exports.onLabResultCreated = onDocumentCreated(
  {document: "organizations/{orgId}/labResults/{docId}", retry: true},
  recordCreated("lab"),
);
exports.onProductBatchSampleCreated = onDocumentCreated(
  {document: "organizations/{orgId}/productBatchSamples/{docId}", retry: true},
  recordCreated("productSample"),
);

// ── One-time 30-day trial expiry ────────────────────────────────────────────
//
// New companies start as `status: 'trial'` with `trialEndsAt = created + 30d`
// (see `AuthRemoteDataSourceImpl.createOrganization`). This cron runs daily and
// flips finished trials to `status: 'suspended'` with `trialConsumed: true.
//
// THE PERMANENCE GUARANTEE (do not weaken this condition):
//   suspend ONLY when status == 'trial' AND trialConsumed == false AND
//   manuallyActivated != true AND now >= trialEndsAt.
// A manually activated company has `status == 'active'` + `manuallyActivated
// == true` + `trialConsumed == true`, so it can never match again — even after
// 60, 90 or 365 days. The update is transactional and idempotent: a retry
// finds `trialConsumed == true` and skips.
//
// Legacy `trial` documents without `trialEndsAt` are backfilled from
// `createdAt + 30d` instead of being suspended blindly.
//
// Deploy note: scheduled functions need the Blaze plan + Cloud Scheduler API.
// Manual activation alternative (no function needed): in the Firebase console,
// set the org to status='active', manuallyActivated=true, trialConsumed=true.
const TRIAL_DAYS = 30;

function trialEndsAtOf(data) {
  const raw = data ? data.trialEndsAt : null;
  if (!raw) return null;
  if (typeof raw.toDate === "function") return raw.toDate();
  const parsed = new Date(raw);
  return isNaN(parsed.getTime()) ? null : parsed;
}

function createdAtOf(data) {
  const raw = data ? (data.createdAt || data.trialStartedAt) : null;
  if (!raw) return null;
  if (typeof raw.toDate === "function") return raw.toDate();
  const parsed = new Date(raw);
  return isNaN(parsed.getTime()) ? null : parsed;
}

exports.expireTrialsDaily = onSchedule(
  {
    schedule: "0 2 * * *",
    timeZone: "Africa/Cairo",
  },
  async () => {
    const db = admin.firestore();
    const now = new Date();
    const snapshot = await db
      .collection("organizations")
      .where("status", "==", "trial")
      .where("trialConsumed", "==", false)
      .limit(500)
      .get();
    if (snapshot.empty) {
      console.log("[trial] no candidate trials");
      return;
    }
    let suspended = 0;
    let backfilled = 0;
    for (const doc of snapshot.docs) {
      const data = doc.data() || {};
      if (data.manuallyActivated === true) continue; // permanent: never touch
      let endsAt = trialEndsAtOf(data);
      if (!endsAt) {
        // Legacy trial without dates: backfill from creation, then evaluate.
        const created = createdAtOf(data);
        const base = created || now;
        const start = data.trialStartedAt || base;
        endsAt = new Date(base.getTime() + TRIAL_DAYS * 24 * 60 * 60 * 1000);
        await doc.ref.set(
          {
            trialStartedAt: start,
            trialEndsAt: endsAt,
            trialConsumed: false,
            manuallyActivated: false,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          {merge: true},
        );
        backfilled++;
      }
      if (now < endsAt) continue; // still inside the 30-day window
      await db.runTransaction(async (tx) => {
        const fresh = await tx.get(doc.ref);
        const d = fresh.data() || {};
        if (d.status !== "trial") return;
        if (d.trialConsumed === true) return;
        if (d.manuallyActivated === true) return;
        const freshEndsAt = trialEndsAtOf(d);
        if (!freshEndsAt || now < freshEndsAt) return;
        tx.set(
          doc.ref,
          {
            status: "suspended",
            trialConsumed: true,
            suspendedAt: admin.firestore.FieldValue.serverTimestamp(),
            suspendedReason: "trial_expired",
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            version: admin.firestore.FieldValue.increment(1),
          },
          {merge: true},
        );
      });
      suspended++;
      console.log(`[trial] suspended ${doc.id} (30-day trial finished)`);
      try {
        const logId =
          `log_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
        await doc.ref.collection("auditLogs").doc(logId).set({
          userId: "system",
          userName: "system",
          organizationId: doc.id,
          action: "TRIAL_EXPIRED",
          entityType: "org",
          entityId: doc.id,
          deviceId: "cron",
          occurredAt: admin.firestore.FieldValue.serverTimestamp(),
          version: 1,
        });
      } catch (e) {
        console.warn(`[trial] audit skipped for ${doc.id}: ${e}`);
      }
    }
    console.log(
      `[trial] done: ${suspended} suspended, ${backfilled} backfilled`,
    );
  },
);

// ── Permanent manual activation (support only) ──────────────────────────────
//
// Callable by the support admin(s) listed in `SUPPORT_ADMIN_UIDS` (comma
// separated Firebase Auth uids) or by an account with the `admin: true` custom
// claim. Everyone else — including the organization's own owner — is rejected,
// so a trial owner can never self-activate a suspended company.
//
// Effect: status='active', manuallyActivated=true, trialConsumed=true.
// Idempotent: activating an already-active company is a no-op success.
// After this call the expiry cron can never suspend the org again.
exports.activateOrganizationPermanently = onCall(async (request) => {
  const callerUid = request.auth ? request.auth.uid : null;
  if (!callerUid) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }
  const allowList = (process.env.SUPPORT_ADMIN_UIDS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const isSupport =
    allowList.includes(callerUid) || request.auth.token.admin === true;
  if (!isSupport) {
    throw new HttpsError(
      "permission-denied",
      "Only support can activate organizations. " +
        "Set SUPPORT_ADMIN_UIDS or edit the org in the Firebase console " +
        "(status='active', manuallyActivated=true, trialConsumed=true).",
    );
  }
  const orgId = String(
    (request.data && request.data.orgId) || "",
  ).trim();
  if (!orgId) {
    throw new HttpsError("invalid-argument", "orgId is required.");
  }
  const db = admin.firestore();
  const ref = db.collection("organizations").doc(orgId);
  const result = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new HttpsError("not-found", "Organization not found.");
    }
    const d = snap.data() || {};
    if (d.status === "active" && d.manuallyActivated === true) {
      return {alreadyActive: true};
    }
    tx.set(
      ref,
      {
        status: "active",
        manuallyActivated: true,
        trialConsumed: true,
        manuallyActivatedAt: admin.firestore.FieldValue.serverTimestamp(),
        manuallyActivatedBy: callerUid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        version: admin.firestore.FieldValue.increment(1),
      },
      {merge: true},
    );
    return {alreadyActive: false};
  });
  try {
    const logId = `log_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    await ref.collection("auditLogs").doc(logId).set({
      userId: callerUid,
      userName: "",
      organizationId: orgId,
      action: "TRIAL_MANUALLY_ACTIVATED",
      entityType: "org",
      entityId: orgId,
      deviceId: "support-call",
      occurredAt: admin.firestore.FieldValue.serverTimestamp(),
      version: 1,
    });
  } catch (e) {
    console.warn(`[trial] activation audit skipped for ${orgId}: ${e}`);
  }
  console.log(
    `[trial] ${orgId} permanently activated by ${callerUid}` +
      (result.alreadyActive ? " (already active)" : ""),
  );
  return {orgId, active: true, alreadyActive: result.alreadyActive};
});
