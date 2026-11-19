import { describe, expect, it } from 'vitest';

import type { SetupStatus } from './api';
import { isBackendStarting } from './setupStatus';

function status(overrides: Partial<SetupStatus> = {}): SetupStatus {
  return {
    phase: 'starting',
    detail: 'Initializing...',
    ollama_ready: false,
    server_ready: false,
    model_ready: false,
    error: null,
    source: 'ollama',
    requires_source: false,
    ...overrides,
  };
}

describe('isBackendStarting', () => {
  it('treats pre-ready phases as starting, not offline', () => {
    expect(isBackendStarting(status({ phase: 'starting' }))).toBe(true);
    expect(isBackendStarting(status({ phase: 'installing_dependencies' }))).toBe(true);
    expect(isBackendStarting(status({ phase: 'starting_server' }))).toBe(true);
  });

  it('is false once the backend reports ready', () => {
    expect(isBackendStarting(status({ phase: 'ready' }))).toBe(false);
  });

  it('does not mask a real startup error', () => {
    expect(isBackendStarting(status({ error: 'server exited' }))).toBe(false);
  });

  it('is false when no setup status is available', () => {
    expect(isBackendStarting(null)).toBe(false);
    expect(isBackendStarting(undefined)).toBe(false);
  });
});
