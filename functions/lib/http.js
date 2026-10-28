'use strict';

const crypto = require('crypto');

class HttpError extends Error {
  constructor(status, message, code = 'request_failed') {
    super(message);
    this.name = 'HttpError';
    this.status = status;
    this.code = code;
  }
}

function env(name) {
  const value = process.env[name];
  return typeof value === 'string' ? value.trim() : '';
}

function requiredEnv(name) {
  const value = env(name);
  if (!value) {
    throw new HttpError(
      503,
      'This service is not configured yet. Please contact the app administrator.',
      `${name.toLowerCase()}_not_configured`,
    );
  }
  return value;
}

function parseJson(raw) {
  let value;
  try {
    value = JSON.parse(raw || '{}');
  } catch (_) {
    throw new HttpError(400, 'Malformed JSON request.', 'invalid_json');
  }
  if (!value || Array.isArray(value) || typeof value !== 'object') {
    throw new HttpError(400, 'The JSON body must be an object.', 'invalid_body');
  }
  return value;
}

async function readJsonBody(req, maxBytes = 65536) {
  if (Buffer.isBuffer(req.rawBody)) {
    if (req.rawBody.length > maxBytes) {
      throw new HttpError(413, 'Request body is too large.', 'body_too_large');
    }
    return parseJson(req.rawBody.toString('utf8'));
  }
  if (req.body && typeof req.body === 'object' && !Array.isArray(req.body)) {
    const size = Buffer.byteLength(JSON.stringify(req.body));
    if (size > maxBytes) {
      throw new HttpError(413, 'Request body is too large.', 'body_too_large');
    }
    return req.body;
  }
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > maxBytes) {
        reject(new HttpError(413, 'Request body is too large.', 'body_too_large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        resolve(parseJson(Buffer.concat(chunks).toString('utf8')));
      } catch (error) {
        reject(error);
      }
    });
    req.on('error', () => reject(new HttpError(400, 'Unable to read request body.')));
  });
}

function makeHandler(name, handler, options = {}) {
  const methods = options.methods || ['POST'];
  return async (req, res) => {
    const requestId = crypto.randomUUID();
    res.set('X-Content-Type-Options', 'nosniff');
    res.set('Cache-Control', 'no-store');
    res.set('Access-Control-Allow-Origin', '*');
    res.set('Access-Control-Allow-Methods', `${methods.join(', ')}, OPTIONS`);
    res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    res.set('Access-Control-Max-Age', '3600');
    if (req.method === 'OPTIONS') {
      res.status(204).send('');
      return;
    }
    if (!methods.includes(req.method)) {
      res.status(405).json({error: `Allowed methods: ${methods.join(', ')}.`, code: 'method_not_allowed'});
      return;
    }
    try {
      const body = req.method === 'POST' ? await readJsonBody(req) : {};
      await handler(req, res, body);
    } catch (error) {
      if (res.headersSent) {
        res.end();
        return;
      }
      const expected = error instanceof HttpError;
      const status = expected ? error.status : 500;
      const message = expected ? error.message : 'Internal server error.';
      const code = expected ? error.code : 'internal_error';
      // Never log request bodies, Authorization headers, provider responses or
      // arbitrary exception text: those channels can contain user/provider secrets.
      console.error(`[tourism:${name}] request=${requestId} status=${status} code=${code}`);
      res.status(status).json({error: message, code, requestId});
    }
  };
}

function requireUid(admin) {
  return async (req) => {
    const header = req.get('Authorization') || '';
    if (!header.startsWith('Bearer ')) {
      throw new HttpError(401, 'Sign in is required.', 'unauthenticated');
    }
    const token = header.slice(7).trim();
    if (!token || token.length > 8192) {
      throw new HttpError(401, 'A valid sign-in session is required.', 'unauthenticated');
    }
    try {
      const decoded = await admin.auth().verifyIdToken(token, true);
      if (!decoded.uid) throw new Error('missing uid');
      return decoded.uid;
    } catch (_) {
      throw new HttpError(401, 'Your session expired. Please sign in again.', 'unauthenticated');
    }
  };
}

async function fetchJson(url, options = {}, timeoutMs = 25000) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {...options, signal: controller.signal});
    const text = await response.text();
    let data;
    try {
      data = text ? JSON.parse(text) : {};
    } catch (_) {
      data = null;
    }
    if (!response.ok || data === null || typeof data !== 'object' || Array.isArray(data)) {
      throw new HttpError(
        502,
        `An upstream service is unavailable (HTTP ${response.status}). Please try again.`,
        'upstream_error',
      );
    }
    return data;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    if (error && error.name === 'AbortError') {
      throw new HttpError(504, 'The upstream service timed out. Please try again.', 'upstream_timeout');
    }
    throw new HttpError(502, 'Unable to reach an upstream service. Please try again.', 'upstream_unavailable');
  } finally {
    clearTimeout(timeout);
  }
}

module.exports = {
  HttpError,
  env,
  requiredEnv,
  readJsonBody,
  parseJson,
  makeHandler,
  requireUid,
  fetchJson,
};
