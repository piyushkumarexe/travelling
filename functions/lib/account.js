'use strict';

const {HttpError} = require('./http');

const ROOT_COLLECTIONS = [
  'profiles',
  'digitalIds',
  'emergencyContacts',
  'incidents',
  'sosEvents',
  'ecoScores',
];

async function deleteQuery(db, query) {
  let deleted = 0;
  // Pagination is based on deletion rather than startAfter so every matching
  // document is eventually removed, including documents with nested collections.
  for (;;) {
    const snapshot = await query.limit(500).get();
    if (snapshot.empty) return deleted;
    await Promise.all(snapshot.docs.map((doc) => db.recursiveDelete(doc.ref)));
    deleted += snapshot.size;
  }
}

async function deleteStoragePrefix(bucket, prefix) {
  const [files] = await bucket.getFiles({prefix, autoPaginate: true});
  for (let i = 0; i < files.length; i += 100) {
    await Promise.all(files.slice(i, i + 100).map((file) => file.delete({ignoreNotFound: true})));
  }
  return files.length;
}

function publicVerificationTokens(privateIds) {
  return [...new Set(privateIds.docs
    .map((doc) => doc.data().token)
    // Cleanup must include legacy tokens too, not only the newest 64-hex
    // format. Exclude values that cannot be a single public document ID.
    .filter((token) => typeof token === 'string' && token.length > 0 &&
      token.length <= 1024 && !token.includes('/')))];
}

async function deleteOwnedData(admin, uid) {
  const db = admin.firestore();
  const privateIds = await db.collection('digitalIds').where('uid', '==', uid).get();
  const tokens = publicVerificationTokens(privateIds);

  // recursiveDelete removes the user document and every current/future private
  // subcollection instead of relying on a brittle hard-coded subcollection list.
  await db.recursiveDelete(db.collection('users').doc(uid));
  for (const name of ROOT_COLLECTIONS) {
    await deleteQuery(db, db.collection(name).where('uid', '==', uid));
  }
  await deleteQuery(db, db.collection('emergencyEvents').where('uid', '==', uid));
  await deleteQuery(db, db.collection('rateLimits').where('uid', '==', uid));
  await Promise.all(tokens.map((token) =>
    db.recursiveDelete(db.collection('digitalIdPublic').doc(token))));

  const bucket = admin.storage().bucket();
  let fileCount = 0;
  for (const prefix of [`users/${uid}/`, `incidents/${uid}/`, `avatars/${uid}/`, `receipts/${uid}/`]) {
    fileCount += await deleteStoragePrefix(bucket, prefix);
  }
  return {privateDigitalIds: privateIds.size, files: fileCount};
}

async function deleteAccount(admin, uid) {
  const summary = await deleteOwnedData(admin, uid);
  try {
    await admin.auth().deleteUser(uid);
  } catch (error) {
    if (error?.code !== 'auth/user-not-found') {
      throw new HttpError(
        500,
        'Account data was removed, but sign-in cleanup needs administrator assistance.',
        'auth_cleanup_failed',
      );
    }
  }
  return summary;
}

module.exports = {
  deleteAccount,
  deleteOwnedData,
  deleteStoragePrefix,
  publicVerificationTokens,
  ROOT_COLLECTIONS,
};
