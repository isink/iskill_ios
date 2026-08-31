function parseInteger(name: string, rawValue: string): number {
  const value = Number(rawValue);
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return value;
}

export function parsePositiveInteger(
  name: string,
  rawValue: string | undefined,
  fallback: number,
): number {
  return rawValue === undefined ? parseInteger(name, String(fallback)) : parseInteger(name, rawValue);
}

export function parseOptionalPositiveInteger(
  name: string,
  rawValue: string | undefined,
): number | undefined {
  return rawValue === undefined ? undefined : parseInteger(name, rawValue);
}
