// External intents only prefill a confirmation sheet; never dispatch native file operations.
export function incomingMagnet(uri: string): string {
  const value = uri.trim();
  if (value.length > 65536 || !/^magnet:\?/i.test(value) || /[\r\n\u0000]/.test(value)) return '';
  if (!/(?:\?|&)xt=urn(?::|%3a)bt(?:ih|mh)(?::|%3a)/i.test(value)) return '';
  return value.replace(/^magnet:/i, 'magnet:');
}
