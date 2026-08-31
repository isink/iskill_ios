export function assertNoBatchFailures(scope: string, failures: number): void {
  if (!Number.isInteger(failures) || failures < 0) {
    throw new Error(`Invalid failure count: ${failures}`);
  }
  if (failures > 0) {
    throw new Error(`${failures} ${scope} operation(s) failed`);
  }
}
