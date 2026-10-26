"use strict";

const {createHash} = require("node:crypto");
const {profileRoles, validRoleSet} = require('./commands');
const allowedRoles = new Set(["admin", "trial_owner", "quality_manager", "lab", "nutritionist", "viewer"]);
const hash = (value) => createHash("sha256").update(value).digest("hex");

// Only a generic alert and opaque routing metadata leave the server. Sample
// names, entry codes, suppliers, quantities and test results are never sent.
function pushData(event) {
  return {
    organizationId: String(event.organizationId),
    kind: event.kind,
    remoteId: hash(String(event.remoteId)),
    // Stable per-event identity: the device dedupes its display path against
    // `org/kind/remoteId/eventId` (absent eventId keeps the legacy key).
    eventId: String(event.eventId || ""),
    sourceDeviceId: String(event.sourceDeviceId || ""),
    title: "Material Lab • تحديث جديد",
    body: event.kind === "inspection"
      ? "يوجد فحص جديد متاح داخل التطبيق • Open the app to view a new inspection"
      : event.kind === "decision"
        ? "يوجد قرار جودة جديد داخل التطبيق • A new quality decision is available in the app"
        : "يوجد تحديث للمعمل داخل التطبيق • Open the app to view a lab update",
  };
}

/** Private, generic alerts only. The app authorizes access to the actual data.
 * Data-only messages avoid a second automatic OS notification, and wake the
 * registered high-priority handler without running the full sync bootstrap.
 * Android Settings > Force stop still requires reopening the app.
 *
 * `event.deliveryKey` (optional) makes the server-side dedupe receipt
 * per-event instead of per-record: the legacy creation path keeps
 * `kind/remoteId` (one alert per record), while the central path passes
 * `kind/remoteId/eventId` so a later decision on the same record is its own
 * delivery. Attempts and the last failure reason are kept on the receipt.
 */
async function deliverPush(db, messaging, event) {
  const orgId = event.organizationId;
  if (!orgId || !event.remoteId || event.deletedAt ||
      !["inspection", "lab", "productSample", "decision"].includes(event.kind)) return;
  const created = new Date(event.createdAt || Date.now()).getTime();
  if (Number.isFinite(created) && Date.now() - created > 86400000) return;
  const org = db.collection("organizations").doc(orgId);
  const identity = event.deliveryKey || `${event.kind}/${event.remoteId}`;
  const receipt = org.collection("notificationDeliveries").doc(hash(identity));
  const acquired = await db.runTransaction(async (tx) => {
    const previous = await tx.get(receipt);
    const data = previous.exists ? previous.data() : {};
    if (data.status === "sent" || data.status === "skipped") return false;
    if (data.status === "sending" && data.leaseUntil > Date.now()) {
      throw new Error("Push delivery is leased; retry after the current attempt");
    }
    tx.set(receipt, {status: "sending", leaseUntil: Date.now() + 60000,
      attempts: (data.attempts || 0) + 1}, {merge: true});
    return true;
  });
  if (!acquired) return;
  try {
    const organization = await org.get();
    if (!organization.exists || !["active", "trial"].includes(organization.data().status)) {
      await receipt.set({status: "skipped", reason: "organization-disabled"}, {merge: true});
      return;
    }
    const registrations = await org.collection("pushTokens").get();
    const candidates = registrations.docs.filter((doc) => {
      const value = doc.data();
      return value.token && value.uid && value.deviceId && value.deviceId !== event.sourceDeviceId;
    });
    const recipients = new Map();
    for (let offset = 0; offset < candidates.length; offset += 100) {
      const group = candidates.slice(offset, offset + 100);
      const profiles = await db.getAll(...group.map((d) => db.collection("users").doc(d.data().uid)));
      const devices = await db.getAll(...group.map((d) => org.collection("devices").doc(d.data().deviceId)));
      group.forEach((doc, i) => {
        const token = doc.data();
        const profile = profiles[i].exists ? profiles[i].data() : {};
        const device = devices[i].exists ? devices[i].data() : {};
        if (profile.organizationId !== orgId || profile.status !== "active" ||
            !validRoleSet(profileRoles(profile), profile.role) ||
            !allowedRoles.has(profile.role) || device.uid !== token.uid ||
            (device.status && device.status !== "active")) return;
        recipients.set(token.token, doc.ref);
      });
    }
    const tokens = [...recipients.keys()];
    for (let offset = 0; offset < tokens.length; offset += 500) {
      const batch = tokens.slice(offset, offset + 500);
      const result = await messaging.sendEachForMulticast({
        tokens: batch,
        data: pushData(event),
        android: {priority: "high", ttl: 86400000},
        apns: {headers: {"apns-push-type": "background", "apns-priority": "5"},
          payload: {aps: {contentAvailable: true}}},
      });
      let retry = false;
      for (let i = 0; i < result.responses.length; i++) {
        const response = result.responses[i];
        if (response.success) continue;
        const code = response.error && response.error.code;
        if (["messaging/registration-token-not-registered", "messaging/invalid-registration-token"].includes(code)) {
          await recipients.get(batch[i]).delete();
        } else { retry = true; }
      }
      if (retry) throw new Error("Transient FCM delivery failure");
    }
    await receipt.set({status: "sent", sentAt: new Date().toISOString(), recipients: tokens.length}, {merge: true});
  } catch (error) {
    await receipt.set({status: "retry", leaseUntil: 0,
      lastError: String((error && error.message) || error)}, {merge: true});
    throw error;
  }
}

/** Consumer core for one central notifyRequest document (see index.js).
 * `notifyTargets` - {kind, entityType, entityId} computed by the command
 * service from its validated write set - become generic push alerts. Each
 * target is one delivery keyed by `kind/entityId/requestId`, so a replay of
 * the same operation cannot alert twice, while a later decision on the same
 * record is a separate, legitimate alert. Returns the number of deliveries
 * attempted.
 */
function buildNotifyRequestConsumer(db, messaging) {
  return async ({orgId, requestId, data}) => {
    const targets = Array.isArray(data.notifyTargets) ? data.notifyTargets : [];
    if (!targets.length) return 0;
    const rawCreated = data.createdAt || "";
    const createdAt = rawCreated && typeof rawCreated.toDate === "function"
      ? rawCreated.toDate().toISOString() : rawCreated;
    let attempted = 0;
    for (const target of targets) {
      if (!target || typeof target !== "object") continue;
      const kind = String(target.kind || "");
      const entityId = String(target.entityId || "");
      if (!kind || !entityId) continue;
      await deliverPush(db, messaging, {
        organizationId: orgId,
        remoteId: entityId,
        // Per-event + per-recipient delivery identity (hash + lease doc).
        deliveryKey: `${kind}/${entityId}/${requestId}`,
        eventId: data.eventId || requestId,
        sourceDeviceId: data.sourceDeviceId || "",
        kind,
        createdAt,
      });
      attempted++;
    }
    return attempted;
  };
}

module.exports = {deliverPush, pushData, buildNotifyRequestConsumer};
