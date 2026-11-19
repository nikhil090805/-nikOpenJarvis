import type { SetupStatus } from './api';

/**
 * Distinguish "the backend is still starting" from "the backend is offline".
 *
 * The Tauri setup wizard walks through phases (dependency sync, Ollama,
 * server startup) before `/health` is reachable. A failed health probe during
 * that window is expected and must not be rendered as "Unhealthy"/offline.
 * A real startup error (`status.error`) is still reported as a failure.
 */
export function isBackendStarting(status: SetupStatus | null | undefined): boolean {
  if (!status) return false;
  if (status.error) return false;
  return status.phase !== 'ready';
}
