'use strict';

const {HttpError} = require('./http');

function invalid(message) {
  throw new HttpError(400, message, 'invalid_argument');
}

function text(value, field, max, options = {}) {
  const {required = true, min = required ? 1 : 0} = options;
  if (value === undefined || value === null) {
    if (!required) return '';
    invalid(`${field} is required.`);
  }
  if (typeof value !== 'string') invalid(`${field} must be text.`);
  const clean = value.trim();
  if (clean.length < min || clean.length > max) {
    invalid(`${field} must be between ${min} and ${max} characters.`);
  }
  if (/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(clean)) {
    invalid(`${field} contains unsupported control characters.`);
  }
  return clean;
}

function optionalText(value, field, max) {
  return text(value, field, max, {required: false});
}

function finiteNumber(value, field, min, max) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) {
    invalid(`${field} must be a number between ${min} and ${max}.`);
  }
  return value;
}

function integer(value, field, min, max) {
  finiteNumber(value, field, min, max);
  if (!Number.isInteger(value)) invalid(`${field} must be a whole number.`);
  return value;
}

function coordinates(body) {
  return {
    lat: finiteNumber(body.lat, 'lat', -90, 90),
    lng: finiteNumber(body.lng, 'lng', -180, 180),
  };
}

function oneOf(value, field, allowed) {
  const clean = text(value, field, 40);
  if (!allowed.includes(clean)) invalid(`${field} has an unsupported value.`);
  return clean;
}

function stringList(value, field, maxItems, maxLength, options = {}) {
  const {required = true} = options;
  if (value === undefined || value === null) {
    if (!required) return [];
    invalid(`${field} must be a list.`);
  }
  if (!Array.isArray(value) || value.length > maxItems) {
    invalid(`${field} must contain at most ${maxItems} items.`);
  }
  return value.map((entry, index) => text(entry, `${field}[${index}]`, maxLength));
}

function chatMessages(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 24) {
    invalid('messages must contain between 1 and 24 entries.');
  }
  let total = 0;
  const messages = value.map((entry, index) => {
    if (!entry || Array.isArray(entry) || typeof entry !== 'object') {
      invalid(`messages[${index}] must be an object.`);
    }
    const role = oneOf(entry.role, `messages[${index}].role`, ['user', 'assistant']);
    const content = text(entry.content, `messages[${index}].content`, 4000);
    total += content.length;
    return {role, content};
  });
  if (total > 16000) invalid('The conversation is too long. Start a new chat and try again.');
  if (messages[messages.length - 1].role !== 'user') {
    invalid('The final message must be a user message.');
  }
  return messages;
}

function routePoints(value) {
  if (!Array.isArray(value) || value.length < 2 || value.length > 25) {
    invalid('points must contain between 2 and 25 coordinates.');
  }
  return value.map((point, index) => {
    if (!point || Array.isArray(point) || typeof point !== 'object') {
      invalid(`points[${index}] must be an object.`);
    }
    return coordinates(point);
  });
}

function bool(value, field) {
  if (typeof value !== 'boolean') invalid(`${field} must be true or false.`);
  return value;
}

module.exports = {
  text,
  optionalText,
  finiteNumber,
  integer,
  coordinates,
  oneOf,
  stringList,
  chatMessages,
  routePoints,
  bool,
};
