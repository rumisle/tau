import { describe, expect, it } from 'vitest';

import { cleanModelError, compactionError, modelErrorReason } from './modelErrors';

describe('model errors', () => {
  it('reads a provider\'s JSON body as its message, with its status', () => {
    expect(cleanModelError('529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'))
      .toBe('529: Overloaded');
    expect(cleanModelError('401 {"error":{"message":"invalid x-api-key"}}')).toBe('401: invalid x-api-key');
    expect(cleanModelError('{"message":"Bad"}')).toBe('Bad');
    expect(cleanModelError('plain words')).toBe('plain words');
    expect(cleanModelError('500 {not json')).toBe('500 {not json');
  });

  it('says what kind it is in a few words', () => {
    expect(modelErrorReason('529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'))
      .toBe('overloaded');
    expect(modelErrorReason('429 Too Many Requests')).toBe('rate limited');
    expect(modelErrorReason('fetch failed')).toBe('connection lost');
    expect(modelErrorReason('401 {"error":{"message":"invalid x-api-key"}}')).toBe('401: invalid x-api-key');
    expect(modelErrorReason('x'.repeat(50))).toBe(`${'x'.repeat(39)}…`);
  });
});

describe('compactionError', () => {
  it('reads a failed summary as the provider\'s words, without durable\'s prefix', () => {
    expect(compactionError('Summarization failed: 400 {"type":"error","error":{"type":"invalid_request_error",'
      + '"message":"prompt is too long"}}')).toBe('400: prompt is too long');
  });
});
