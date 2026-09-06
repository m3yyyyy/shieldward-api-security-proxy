import { isIP } from 'node:net'

export function isLoopbackHostname(
  hostname: string,
): boolean {
  const normalized = hostname
    .trim()
    .toLowerCase()
    .replace(/^\[|\]$/g, '')
    .replace(/\.$/, '')

  if (normalized === 'localhost') {
    return true
  }

  const ipVersion = isIP(normalized)

  return (
    (ipVersion === 4 &&
      normalized.startsWith('127.')) ||
    (ipVersion === 6 && normalized === '::1')
  )
}

export function usesSecureTransport(
  url: URL,
): boolean {
  return (
    url.protocol === 'https:' ||
    (url.protocol === 'http:' &&
      isLoopbackHostname(url.hostname))
  )
}
