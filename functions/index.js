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
