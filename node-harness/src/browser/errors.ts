/** Model-facing browser failure: `code: message`. Messages are fixed text, never page or host content. */
export class BrowserError extends Error {
  constructor(readonly code: string, message: string) { super(`${code}: ${message}`); }
}
export const failure = (code: string, message: string): never => { throw new BrowserError(code, message); };
