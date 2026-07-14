// the server puts exp in the jwt header rather than the payload claims, see shared/jwt.rb
export function expiry(token: string): Date | null {
  const segments = token.split(".");
  if (segments.length !== 3) return null;

  const json = base64URLDecode(segments[0]);
  if (json === null) return null;

  try {
    const header = JSON.parse(json);
    if (typeof header?.exp !== "number") return null;
    return new Date(header.exp * 1000);
  } catch {
    return null;
  }
}

// anything we can't parse is treated as unexpired: the server is the judge of a
// token's validity, we'd rather refresh in the background than lock the user out
export function isExpired(token: string, now: Date = new Date()): boolean {
  const expires = expiry(token);
  if (expires === null) return false;
  return expires.getTime() <= now.getTime();
}

function base64URLDecode(segment: string): string | null {
  let base64 = segment.replace(/-/g, "+").replace(/_/g, "/");
  // base64url drops the padding, put it back
  const remainder = base64.length % 4;
  if (remainder > 0) base64 += "=".repeat(4 - remainder);

  try {
    return atob(base64);
  } catch {
    return null;
  }
}
