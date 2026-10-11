// UI labels only: retain the original PeerInfo address for connection identity.
function maskedIpv4(host: string): string {
  if (!/^\d{1,3}(?:\.\d{1,3}){3}$/.test(host)) return '';
  const octets = host.split('.');
  return octets.every((part: string) => Number(part) <= 255) ? '*.*.*.' + octets[3] : '';
}

function maskHost(host: string): string {
  const ipv4 = maskedIpv4(host);
  if (ipv4) return ipv4;
  // Strip local interface scope IDs. Expand :: before hiding the first 3 groups.
  let address = host.split('%')[0];
  let embeddedIpv4 = '';
  if (address.includes('.')) {
    const split = address.lastIndexOf(':');
    if (split < 0) return '***';
    embeddedIpv4 = maskedIpv4(address.slice(split + 1));
    if (!embeddedIpv4) return '***';
    address = address.slice(0, split + 1) + '0:0';
  }
  if (!/^[0-9a-fA-F:]+$/.test(address) || !address.includes(':')) return '***';
  const halves = address.split('::');
  if (halves.length > 2) return '***';
  const left: string[] = halves[0] ? halves[0].split(':') : [];
  const right: string[] = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
  const explicit = left.concat(right);
  if (!explicit.every((part: string) => /^[0-9a-fA-F]{1,4}$/.test(part))) return '***';
  if (halves.length === 1 && explicit.length !== 8) return '***';
  if (halves.length === 2 && explicit.length >= 8) return '***';
  const groups: string[] = left.slice();
  if (halves.length === 2) {
    for (let i = explicit.length; i < 8; i++) groups.push('0');
    for (const part of right) groups.push(part);
  }
  const tail = embeddedIpv4 ? groups.slice(3, 6).join(':') + ':' + embeddedIpv4 : groups.slice(3).join(':');
  return '*:*:*:' + tail;
}

export function maskPeerEndpoint(endpoint: string): string {
  const value = endpoint.trim();
  const ipv4 = maskedIpv4(value);
  if (ipv4) return ipv4;
  // Native bridge sends host + ':' + port, including unbracketed IPv6.
  // Also accept bracketed IPv6; unknown formats must not expose their raw text.
  const separator = value.lastIndexOf(':');
  if (separator <= 0) return '***';
  let host = value.slice(0, separator);
  const port = value.slice(separator + 1);
  if (!/^\d{1,5}$/.test(port) || Number(port) > 65535) return '***';
  if (host.startsWith('[') && host.endsWith(']')) host = host.slice(1, -1);
  const label = maskHost(host);
  return (host.includes(':') ? '[' + label + ']' : label) + ':' + port;
}
