'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} = require('@firebase/rules-unit-testing');
const {
  doc,
  collection,
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
  deleteDoc,
  query,
  where,
  writeBatch,
  serverTimestamp,
  Timestamp,
} = require('firebase/firestore');
// Register the modular Storage component used by context.storage(), including
// the test environment's clearStorage() cleanup hook.
require('firebase/storage');

const projectId = 'demo-tourism';
let testEnv;

const token = 'a'.repeat(64);
const now = () => Timestamp.now();
const privateId = (uid = 'alice') => ({
  uid,
  ownerName: 'Alice Traveller',
  token,
  status: 'active',
  createdAt: now(),
  updatedAt: now(),
  photoUrl: null,
  emergencyContactName: 'Private Contact',
  emergencyContactPhone: '+919999999999',
});
const publicId = (recordId = 'record-1') => ({
  token,
  recordId,
  ownerName: 'Alice Traveller',
  status: 'active',
  updatedAt: now(),
});

async function seed(pathName, data) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), pathName), data);
  });
}

test.before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId,
    firestore: {rules: fs.readFileSync(path.join(__dirname, '../../firestore.rules'), 'utf8')},
    storage: {rules: fs.readFileSync(path.join(__dirname, '../../storage.rules'), 'utf8')},
  });
});

test.after(async () => {
  await testEnv?.cleanup();
});

test.beforeEach(async () => {
  await testEnv.clearFirestore();
  await testEnv.clearStorage();
});

test('account owners cannot self-promote or read another profile', async () => {
  const alice = testEnv.authenticatedContext('alice').firestore();
  const bob = testEnv.authenticatedContext('bob').firestore();
  await assertSucceeds(setDoc(doc(alice, 'users/alice'), {
    role: 'user', displayName: 'Alice', email: 'alice@example.test', createdAt: now(),
  }));
  await assertFails(updateDoc(doc(alice, 'users/alice'), {role: 'admin'}));
  await seed('profiles/alice', {uid: 'alice', name: 'Alice'});
  await assertSucceeds(getDoc(doc(alice, 'profiles/alice')));
  await assertFails(getDoc(doc(bob, 'profiles/alice')));
  await assertSucceeds(setDoc(doc(bob, 'profiles/bob'), {
    emergencyContactName: 'Bob Contact', emergencyContactPhone: '+911234567890', updatedAt: now(),
  }));
});

test('incidents and SOS use nested coordinates and owner-only history', async () => {
  const alice = testEnv.authenticatedContext('alice').firestore();
  const bob = testEnv.authenticatedContext('bob').firestore();
  const incident = {
    uid: 'alice', reporterName: 'Alice', description: 'A verified incident description',
    category: 'theft', severity: 'high', status: 'reported',
    location: {lat: 26.4, lng: 80.3}, summary: null, recommendedAction: null,
    photoUrl: null, videoUrl: null, createdAt: now(), updatedAt: now(),
  };
  await assertSucceeds(setDoc(doc(alice, 'incidents/incident-1'), incident));
  await assertFails(setDoc(doc(alice, 'incidents/incident-2'), {...incident, lat: 26.4, lng: 80.3, location: undefined}));
  await assertSucceeds(getDocs(query(collection(alice, 'incidents'), where('uid', '==', 'alice'))));
  await assertFails(getDoc(doc(bob, 'incidents/incident-1')));
  await assertFails(getDocs(query(collection(bob, 'incidents'), where('uid', '==', 'alice'))));

  const event = {
    uid: 'alice', name: 'Alice', status: 'active', kind: 'sos',
    location: {lat: 26.4, lng: 80.3, accuracy: 12}, createdAt: now(),
  };
  await assertSucceeds(setDoc(doc(alice, 'emergencyEvents/event-1'), event));
  await assertSucceeds(updateDoc(doc(alice, 'emergencyEvents/event-1'), {
    location: {lat: 26.5, lng: 80.4, accuracy: 10}, updatedAt: now(), lastLocationAt: now(),
  }));
  await assertFails(getDoc(doc(bob, 'emergencyEvents/event-1')));
  await assertFails(setDoc(doc(bob, 'emergencyEvents/event-2'), {...event, kind: 'power_off'}));
});

test('Digital ID batch is minimal, token-only public, and atomically revocable', async () => {
  const alice = testEnv.authenticatedContext('alice').firestore();
  const bob = testEnv.authenticatedContext('bob').firestore();
  const anonymous = testEnv.unauthenticatedContext().firestore();

  // A private-only write cannot produce an unverifiable active QR token.
  await assertFails(setDoc(doc(alice, 'digitalIds/record-1'), privateId()));
  const batch = writeBatch(alice);
  batch.set(doc(alice, 'digitalIds/record-1'), privateId());
  batch.set(doc(alice, 'digitalIdPublic/' + token), publicId());
  await assertSucceeds(batch.commit());

  const publicSnapshot = await assertSucceeds(getDoc(doc(anonymous, 'digitalIdPublic/' + token)));
  assert.deepEqual(Object.keys(publicSnapshot.data()).sort(), ['ownerName', 'recordId', 'status', 'token', 'updatedAt']);
  assert.equal(publicSnapshot.data().status, 'active');
  await assertFails(getDocs(collection(anonymous, 'digitalIdPublic')));
  await assertFails(getDoc(doc(bob, 'digitalIds/record-1')));
  await assertFails(setDoc(doc(bob, 'digitalIdPublic/' + 'b'.repeat(64)), {
    ...publicId(), token: 'b'.repeat(64), ownerName: 'Stolen identity',
  }));

  const revoked = writeBatch(alice);
  revoked.update(doc(alice, 'digitalIds/record-1'), {status: 'revoked', updatedAt: serverTimestamp()});
  revoked.set(doc(alice, 'digitalIdPublic/' + token), {...publicId(), status: 'revoked', updatedAt: serverTimestamp()});
  await assertSucceeds(revoked.commit());
  const revokedSnapshot = await assertSucceeds(getDoc(doc(anonymous, 'digitalIdPublic/' + token)));
  assert.equal(revokedSnapshot.data().status, 'revoked');

  const privateOnly = writeBatch(alice);
  privateOnly.update(doc(alice, 'digitalIds/record-1'), {status: 'active', updatedAt: serverTimestamp()});
  await assertFails(privateOnly.commit());
  await assertFails(setDoc(doc(alice, 'digitalIdPublic/' + token), {
    ...publicId(), emergencyContactPhone: '+919999999999', uid: 'alice',
  }));
});

test('all journey operation kinds and saved places remain owner scoped', async () => {
  const alice = testEnv.authenticatedContext('alice').firestore();
  const bob = testEnv.authenticatedContext('bob').firestore();
  const kinds = [
    'medicine', 'luggage', 'taskBoard', 'contacts', 'connectivity', 'dietary',
    'accessibility', 'souvenirs', 'journal', 'checkpoints', 'homeReadiness',
    'localKnowledge', 'visaTracker', 'travelInsurance', 'bookingConfirmations',
    'flightBoarding', 'trainCoach', 'busBoarding', 'hotelStay', 'rentalInspection',
    'parkingLocator', 'tollsPermits', 'fuelStops', 'restBreaks', 'meetingPoints',
    'groupRoster', 'childTravel', 'seniorCare', 'petTravel', 'laundryPlan',
    'waterRefills', 'deviceCharging', 'workationSetup', 'localEvents',
    'weatherBackup', 'medicalFacilities', 'lostAndFound',
  ];
  for (const kind of kinds) {
    await assertSucceeds(setDoc(doc(alice, `users/alice/journeyOperations/${kind}`), {
      id: kind, userId: 'alice', kind, title: kind, detail: '', extra: '',
      completed: false, createdAt: 1, updatedAt: 1,
    }));
  }
  await assertFails(getDoc(doc(bob, 'users/alice/journeyOperations/medicine')));
  await assertSucceeds(setDoc(doc(alice, 'users/alice/savedPlaces/place-1'), {
    uid: 'alice', placeId: 'google-place-1', place: {name: 'A real place'},
    createdAt: now(), updatedAt: now(),
  }));
  await assertFails(getDoc(doc(bob, 'users/alice/savedPlaces/place-1')));
});

test('expense budgets, bookings and vault records enforce ownership', async () => {
  const alice = testEnv.authenticatedContext('alice').firestore();
  const bob = testEnv.authenticatedContext('bob').firestore();
  await assertSucceeds(setDoc(doc(alice, 'users/alice/expenseData/budget'), {
    daily: 1000, perTrip: {}, currency: 'INR', updatedAt: 1,
  }));
  await assertSucceeds(setDoc(doc(alice, 'users/alice/bookingRefs/booking-1'), {
    bookingId: 'booking-1', userId: 'alice', tripId: null, category: 'train',
    provider: 'IRCTC', serviceType: '', origin: null, destination: null,
    bookingDate: null, status: 'saved', externalReference: null, notes: null,
    createdAt: 1, updatedAt: 1,
  }));
  await assertSucceeds(setDoc(doc(alice, 'users/alice/travelDocuments/doc-1'), {
    documentId: 'doc-1', userId: 'alice', type: 'passport', title: 'Passport',
    uploadStatus: 'none', createdAt: 1, updatedAt: 1,
  }));
  await assertFails(getDoc(doc(bob, 'users/alice/bookingRefs/booking-1')));
  await assertFails(getDoc(doc(bob, 'users/alice/travelDocuments/doc-1')));
  await assertFails(deleteDoc(doc(bob, 'users/alice/expenseData/budget')));
});

test('Storage avatar and receipt access is owner-only with type limits', async () => {
  const alice = testEnv.authenticatedContext('alice').storage();
  const bob = testEnv.authenticatedContext('bob').storage();
  await assertSucceeds(alice.ref('avatars/alice/avatar.jpg').putString('image', {contentType: 'image/jpeg'}));
  await assertSucceeds(alice.ref('avatars/alice/avatar.jpg').getDownloadURL());
  await assertFails(bob.ref('avatars/alice/avatar.jpg').getDownloadURL());
  await assertFails(bob.ref('avatars/alice/stolen.jpg').putString('image', {contentType: 'image/jpeg'}));
  await assertFails(alice.ref('receipts/alice/receipt.exe').putString('not an image', {contentType: 'application/octet-stream'}));
  await assertSucceeds(alice.ref('receipts/alice/receipt.jpg').putString('image', {contentType: 'image/jpeg'}));
});
