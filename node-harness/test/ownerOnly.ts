import assert from "node:assert/strict";
import { statSync } from "node:fs";

/**
 * Asserts POSIX permission bits (owner-only files 0o600, directories 0o700). A no-op on
 * Windows, where Node reports only the write bit (a 0o600 file stats as 0o666).
 */
export function assertOwnerOnly(path: string, expected: number): void {
  if (process.platform === "win32") return;
  assert.equal(statSync(path).mode & 0o777, expected, path);
}
