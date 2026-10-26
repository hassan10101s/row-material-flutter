"use strict";
const {test} = require("node:test");
const assert = require("node:assert/strict");
const {deliverPush, pushData, buildNotifyRequestConsumer} = require("../push_delivery");

// In-memory Admin SDK seam. These tests never initialize Firebase or send FCM.
function fixture() {
  const rows = new Map();
  const snapshot = (path) => ({exists: rows.has(path), data: () => rows.get(path), ref: ref(path)});
  function ref(path) {
    return {path, get: async () => snapshot(path),
      set: async (data) => rows.set(path, data), delete: async () => rows.delete(path),
      collection: (name) => collection(`${path}/${name}`)};
  }
  function collection(path) {
    return {doc: (id) => ref(`${path}/${id}`), get: async () => ({
      docs: [...rows.keys()].filter((key) => key.startsWith(`${path}/`) && !key.substring(path.length + 1).includes("/"))
        .map((key) => snapshot(key)),
    })};
  }
  const db = {collection, getAll: async (...refs) => refs.map((r) => snapshot(r.path)),
    runTransaction: async (work) => work({get: async (r) => snapshot(r.path), set: (r, value) => rows.set(r.path, value)})};
  const messages = [];
  const messaging = {sendEachForMulticast: async (message) => {
    messages.push(message);
    return {responses: message.tokens.map(() => ({success: true}))};
  }};
  rows.set("organizations/org", {status: "active"});
  function device(id, {uid = id, status = "active", role = "viewer", organizationId = "org", token = id, revoked = false} = {}) {
    rows.set(`organizations/org/pushTokens/${id}`, {uid, deviceId: id, token});
    rows.set(`users/${uid}`, {organizationId, status, role});
    rows.set(`organizations/org/devices/${id}`, {uid, status: revoked ? "revoked" : "active"});
  }
  const event = {organizationId: "org", kind: "inspection", remoteId: "private-entry", sourceDeviceId: "writer"};
  return {rows, db, messaging, messages, device, event};
}

test("only generic text and hashed identity cross the FCM boundary", () => {
  const data = pushData({organizationId: "org", kind: "lab", remoteId: "private-entry",
    title: "sensitive sample", body: "sensitive result", entryCode: "private-entry", resultText: "private result"});
  const encoded = JSON.stringify(data);
  for (const forbidden of ["sensitive", "private-entry", "private result"]) assert(!encoded.includes(forbidden));
  assert.match(data.remoteId, /^[0-9a-f]{64}$/);
  assert(Object.values(data).every((value) => typeof value === "string"));
  assert(Buffer.byteLength(encoded) < 4096);
});

test("repeated Firestore events send one generic background alert", async () => {
  const f = fixture(); f.device("phone");
  await deliverPush(f.db, f.messaging, f.event);
  await deliverPush(f.db, f.messaging, f.event);
  assert.equal(f.messages.length, 1);
  assert.equal(f.messages[0].android.priority, "high");
  assert.equal(f.messages[0].notification, undefined);
  assert.deepEqual(f.messages[0].tokens, ["phone"]);
});

test("current profiles, devices and organization authorize every recipient", async () => {
  const f = fixture();
  f.device("phone"); f.device("disabled", {status: "disabled"});
  f.device("invited", {status: "invited"}); f.device("revoked", {revoked: true});
  f.device("foreign", {organizationId: "other"}); f.device("invalid-role", {role: "unknown"});
  f.device("writer");
  await deliverPush(f.db, f.messaging, f.event);
  assert.deepEqual(f.messages[0].tokens, ["phone"]);
});

test("a transient failure can retry; successful retries become quiet", async () => {
  const f = fixture(); f.device("phone");
  let attempts = 0;
  f.messaging.sendEachForMulticast = async () => {
    if (++attempts === 1) throw new Error("offline fixture");
    return {responses: [{success: true}]};
  };
  await assert.rejects(deliverPush(f.db, f.messaging, f.event));
  await deliverPush(f.db, f.messaging, f.event);
  await deliverPush(f.db, f.messaging, f.event);
  assert.equal(attempts, 2);
});

test("expired tokens are removed without retrying forever", async () => {
  const f = fixture(); f.device("phone");
  f.messaging.sendEachForMulticast = async () => ({responses: [{success: false,
    error: {code: "messaging/registration-token-not-registered"}}]});
  await deliverPush(f.db, f.messaging, f.event);
  assert(!f.rows.has("organizations/org/pushTokens/phone"));
});

test("history imports and tombstones produce no alert", async () => {
  const f = fixture(); f.device("phone");
  await deliverPush(f.db, f.messaging, {...f.event, createdAt: "2001-01-01"});
  await deliverPush(f.db, f.messaging, {...f.event, deletedAt: "2026-01-01"});
  assert.equal(f.messages.length, 0);
});

test("suspension is checked on the server even if tokens remain registered", async () => {
  const f = fixture(); f.device("phone");
  f.rows.set("organizations/org", {status: "suspended"});
  await deliverPush(f.db, f.messaging, f.event);
  assert.equal(f.messages.length, 0);
});

test("fan-out batches use at most 500 tokens and deduplicate registrations", async () => {
  const f = fixture();
  for (let i = 0; i < 501; i++) f.device(`phone-${i}`);
  f.device("duplicate", {token: "phone-0"});
  await deliverPush(f.db, f.messaging, f.event);
  assert.deepEqual(f.messages.map((m) => m.tokens.length), [500, 1]);
});

// ── Central notifyRequests consumer (blocking 4) ────────────────────────────
function notifyRequest(eventId, targets) {
  return {notifyTargets: targets, eventId, sourceDeviceId: "writer",
    // Recent, or the 24h anti-history guard would silently skip delivery.
    createdAt: new Date()};
}

test("one notifyRequest fans out per target and replays stay quiet", async () => {
  const f = fixture(); f.device("phone");
  const consume = buildNotifyRequestConsumer(f.db, f.messaging);
  const data = notifyRequest("event_7", [
    {kind: "inspection", entityType: "sample", entityId: "s-1"},
    {kind: "decision", entityType: "sample", entityId: "s-1"},
    {kind: "lab", entityType: "labResult", entityId: "l-1"},
  ]);
  assert.equal(await consume({orgId: "org", requestId: "notify_op-1", data}), 3);
  assert.equal(f.messages.length, 3);
  const bodies = f.messages.map((m) => m.data.body);
  assert(bodies.some((b) => b.includes("فحص جديد")));
  assert(bodies.some((b) => b.includes("قرار جودة")));
  assert(bodies.some((b) => b.includes("تحديث للمعمل")));
  // Replay of the same operation: same delivery keys, zero new alerts.
  assert.equal(await consume({orgId: "org", requestId: "notify_op-1", data}), 3);
  assert.equal(f.messages.length, 3);
});

test("a later decision on the same record is a separate legitimate alert", async () => {
  const f = fixture(); f.device("phone");
  const consume = buildNotifyRequestConsumer(f.db, f.messaging);
  await consume({orgId: "org", requestId: "notify_op-1",
    data: notifyRequest("event_7", [{kind: "decision", entityType: "sample", entityId: "s-1"}])});
  await consume({orgId: "org", requestId: "notify_op-2",
    data: notifyRequest("event_9", [{kind: "decision", entityType: "sample", entityId: "s-1"}])});
  assert.equal(f.messages.length, 2);
  // Per-event identity crosses the wire for the device-side dedupe.
  for (const [message, eventId] of [[f.messages[0], "event_7"], [f.messages[1], "event_9"]]) {
    assert.equal(message.data.eventId, eventId);
  }
});

test("a notifyRequest without targets sends nothing", async () => {
  const f = fixture(); f.device("phone");
  const consume = buildNotifyRequestConsumer(f.db, f.messaging);
  assert.equal(await consume({orgId: "org", requestId: "notify_op-1", data: {notifyTargets: []}}), 0);
  assert.equal(await consume({orgId: "org", requestId: "notify_op-2", data: {}}), 0);
  assert.equal(f.messages.length, 0);
});

test("malformed targets are skipped without failing the whole fan-out", async () => {
  const f = fixture(); f.device("phone");
  const consume = buildNotifyRequestConsumer(f.db, f.messaging);
  assert.equal(await consume({orgId: "org", requestId: "notify_op-1", data: notifyRequest("event_7", [
    null, "junk", {kind: "", entityId: "s-1"}, {kind: "inspection"},
    {kind: "decision", entityType: "sample", entityId: "s-1"},
  ])}), 1);
  assert.equal(f.messages.length, 1);
});
