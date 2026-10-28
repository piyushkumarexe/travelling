'use strict';

const {HttpError, env, requiredEnv, fetchJson} = require('./http');

function aiConfig() {
  return {
    key: requiredEnv('NVIDIA_API_KEY'),
    baseUrl: env('NVIDIA_BASE_URL') || 'https://integrate.api.nvidia.com/v1',
    model: env('NVIDIA_MODEL') || 'meta/llama-3.1-70b-instruct',
  };
}

async function chatComplete(messages, options = {}) {
  const {key, baseUrl, model} = aiConfig();
  const data = await fetchJson(`${baseUrl}/chat/completions`, {
    method: 'POST',
    headers: {Authorization: `Bearer ${key}`, 'Content-Type': 'application/json'},
    body: JSON.stringify({
      model,
      messages,
      temperature: options.temperature ?? 0.2,
      max_tokens: options.maxTokens ?? 700,
      top_p: options.topP ?? 0.9,
    }),
  }, options.timeoutMs ?? 35000);
  const content = data.choices?.[0]?.message?.content;
  if (typeof content !== 'string' || !content.trim()) {
    throw new HttpError(502, 'The AI provider returned no usable response.', 'empty_ai_response');
  }
  return content.trim();
}

function extractJson(content) {
  const cleaned = content.replace(/```json\s*/gi, '').replace(/```/g, '').trim();
  const first = Math.min(...[cleaned.indexOf('{'), cleaned.indexOf('[')].filter((n) => n >= 0));
  if (!Number.isFinite(first)) {
    throw new HttpError(502, 'The AI response was not valid structured data.', 'invalid_ai_response');
  }
  const last = Math.max(cleaned.lastIndexOf('}'), cleaned.lastIndexOf(']'));
  if (last < first) {
    throw new HttpError(502, 'The AI response was incomplete.', 'invalid_ai_response');
  }
  try {
    return JSON.parse(cleaned.slice(first, last + 1));
  } catch (_) {
    throw new HttpError(502, 'The AI response could not be parsed. Please try again.', 'invalid_ai_response');
  }
}

async function chatJson(messages, options = {}) {
  return extractJson(await chatComplete(messages, options));
}

module.exports = {chatComplete, chatJson, extractJson};
