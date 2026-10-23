/**
 * MaterialLab killed-app push (FCM).
 *
 * Listens for new Firestore documents written by the sync engine and fans out
 * one FCM message per document to the topic `org_<orgId>`, which every member
 * device subscribes to (see `FcmPushService.setOrganization`).
 *
 * Why Cloud Functions and not the app: FCM is delivered by Google Play
 * services, NOT by our process — it arrives even when the app is swiped away,
 * force-stopped, or never started after a reboot, where Workmanager polls and
 * foreground listeners cannot run.
 *
 * Bodies mirror the in-app NotificationService wording (bilingual AR • EN) and
 * carry the useful details: supplier • qty • verdict for inspections,
 * analysis = result • accepted-or-not for lab results.
 *
 * Collections (see `SyncCollection` in the Flutter app):
 *   organizations/{orgId}/samples/{entryCode}              -> inspection
 *   organizations/{orgId}/labResults/{lt_<id>}             -> lab result
 *   organizations/{orgId}/productBatchSamples/{remoteId}   -> product follow-up
 *
 * Payload deep-links (parsed by `NotificationService.routeForPayload`):
 *   inspection:<localId>  -> /inspections?highlight=<id>
 *   lab:<localId>         -> /lab?tab=0&highlight=<id>
 *
 * Deploy:
 *   cd functions && npm install
 *   firebase deploy --only functions
 *
 * Required: Blaze plan (FCM send itself is free; Functions need Blaze).
 */
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {onSchedule} = require("firebase-functions/v2/scheduler");
const {onCall, HttpsError} = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

admin.initializeApp();

const TOPIC = (orgId) => `org_${orgId}`;

function verdictLabel(status) {
  switch (status) {
    case "APPROVED":
      return "مطابق للمواصفات • Accepted";
    case "CONDITIONAL_APPROVAL":
      return "مقبول مشروط • Conditionally accepted";
    case "PARTIAL_REJECTION":
      return "مرفوض جزئياً • Partially rejected";
    case "FULL_REJECTION":
      return "مرفوض • Rejected";
    default:
      return "بانتظار القرار • Pending";
  }
}

function labDecisionLabel(status) {
  switch (status) {
    case "APPROVED":
    case "CONDITIONAL_APPROVAL":
      return "مقبول • Accepted";
    case "PARTIAL_REJECTION":
    case "FULL_REJECTION":
      return "مرفوض • Rejected";
    default:
      return "بانتظار القرار • Pending";
  }
}

async function sendToOrg(orgId, {title, body, payload}) {
  if (!orgId) return;
  const text = `${title} ${body}`;
  const color = /مرفوض|Rejected/.test(text)
    ? "#B91C1C"
    : /مطابق|مقبول|Accepted/.test(text)
      ? "#1D4ED8"
      : "#0F766E";
  await admin.messaging().send({
    topic: TOPIC(orgId),
    notification: {title, body},
    data: {
      title,
      body,
      payload: payload || "",
      click_action: "FLUTTER_NOTIFICATION_CLICK",
    },
    android: {
      priority: "high",
      notification: {
        channelId: "material_lab_new_items_v3",
        sound: "default",
        color,
        clickAction: "FLUTTER_NOTIFICATION_CLICK",
      },
    },
  });
  console.log(`[push] sent to ${TOPIC(orgId)}: ${title} | ${body}`);
}

// ── New inspection (raw material OR product batch) ──────────────────────────
exports.onSampleCreated = onDocumentCreated(
  "organizations/{orgId}/samples/{docId}",
  async (event) => {
    const orgId = event.params.orgId;
    const d = event.data && event.data.data ? event.data.data() : {};
    const kind = d.inspectionKind || d.inspection_kind || "raw";
    const localId = d.localId != null ? String(d.localId) : "";

    let title;
    let body;
    if (kind === "product") {
      const product = d.materialName || d.material_name || "";
      const batch = d.batchNumber || d.batch_number || "";
      const who = batch ? `${product} (${batch})` : product;
      title = `تحليل منتج جديد • New product analysis: ${who}`;
      const parts = [];
      if (d.entryCode || d.entry_code) parts.push(d.entryCode || d.entry_code);
      if (batch) parts.push(`التشغيلة: ${batch}`);
      if (d.formulaNumber || d.formula_number) {
        parts.push(`التركيبة: ${d.formulaNumber || d.formula_number}`);
      }
      parts.push(verdictLabel(d.decisionStatus || d.decision_status || ""));
      body = parts.join(" • ");
    } else {
      const material = d.materialName || d.material_name || "";
      title = `فحص خامة جديد • New material inspection: ${material}`;
      const parts = [];
      if (d.entryCode || d.entry_code) parts.push(d.entryCode || d.entry_code);
      if (d.supplier) parts.push(`المورد: ${d.supplier}`);
      if (d.quantity) parts.push(`الكمية: ${d.quantity}`);
      parts.push(verdictLabel(d.decisionStatus || d.decision_status || ""));
      const rejected = d.rejectedQuantity || d.rejected_quantity || "";
      if (rejected && rejected !== "0") parts.push(`مرفوض منها: ${rejected}`);
      body = parts.join(" • ");
    }
    await sendToOrg(orgId, {
      title,
      body,
      payload: localId ? `inspection:${localId}` : "",
    });
  },
);

// ── New chemistry lab result ────────────────────────────────────────────────
exports.onLabResultCreated = onDocumentCreated(
  "organizations/{orgId}/labResults/{docId}",
  async (event) => {
    const orgId = event.params.orgId;
    const d = event.data && event.data.data ? event.data.data() : {};
    const localId = d.localId != null ? String(d.localId) : "";
    const sourceType = d.sourceType || d.source_type || "";
    const sample = d.sampleName || d.sample_name || d.sourceName || "";
    const result = d.resultText || d.result_text || "";

    let title;
    if (sourceType === "product") {
      const product = d.sourceName || d.source_name || "";
      const who = product ? `${product} – ${sample}` : sample;
      title = `متابعة تحليل منتج • Product analysis follow-up: ${who}`;
    } else {
      title = `نتيجة معمل (كيمياء) • Lab result (Chemistry): ${sample}`;
    }
    const parts = [];
    if (d.entryCode || d.entry_code) parts.push(d.entryCode || d.entry_code);
    if (result) parts.push(`النتيجة: ${result}`);
    if (sourceType === "product") {
      if (d.sourceName || d.source_name) {
        parts.push(`النوع: ${d.sourceName || d.source_name}`);
      }
      // decisionStatus here is the parent sample verdict when present.
      const dec = d.decisionStatus || d.decision_status || "";
      if (dec) parts.push(labDecisionLabel(dec));
    }
    await sendToOrg(orgId, {
      title,
      body: parts.join(" • ") || title,
      payload: localId ? `lab:${localId}` : "",
    });
  },
);

// ── New product batch sample (decision / follow-up) ─────────────────────────
exports.onProductBatchSampleCreated = onDocumentCreated(
  "organizations/{orgId}/productBatchSamples/{docId}",
  async (event) => {
    const orgId = event.params.orgId;
    const d = event.data && event.data.data ? event.data.data() : {};
    const localId = d.localId != null ? String(d.localId) : "";
    const sample = d.sampleName || d.sample_name || "";
    const title = `متابعة تحليل منتج • Product analysis follow-up: ${sample}`;
    const parts = [];
    if (d.sampleNo || d.sample_no) parts.push(`العينة: ${d.sampleNo || d.sample_no}`);
    if (d.testedByName || d.tested_by_name) {
      parts.push(`أضافها: ${d.testedByName || d.tested_by_name}`);
    }
    parts.push(labDecisionLabel(d.decisionStatus || d.decision_status || ""));
    await sendToOrg(orgId, {
      title,
      body: parts.join(" • "),
      // Opens the lab tab; the batch-sample screen resolves from the sample.
      payload: localId ? `lab:${localId}` : "",
    });
  },
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
