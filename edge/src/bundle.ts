import { usesSecureTransport } from './transport.js'

export const BUNDLE_SCHEMA_VERSION =
  'shieldward.bundle/v1alpha1' as const

export const SIGNATURE_ALGORITHM = 'Ed25519' as const

export type DefaultDecision = 'allow' | 'deny'
export type RateLimitKey = 'client-ip' | 'jwt.sub'
export type WafTarget = 'path' | 'query' | 'headers' | 'body'
export type WafAction = 'block' | 'log'

export interface MethodMatcher {
  method: string
  regex: string
  routeIds: string[]
}

export interface RouteMatch {
  methods: string[]
  path: string
}

export interface JwtPolicy {
  required: true
  issuer: string
  audience: string[]
  jwksUrl: string
}

export interface RateLimitPolicy {
  requests: number
  window: string
  key: RateLimitKey
}

export interface WafRule {
  id: string
  target: WafTarget
  pattern: string
  flags?: 'i'
  action: WafAction
}

export interface CompiledRoute {
  id: string
  match: RouteMatch
  upstream: string
  jwt?: JwtPolicy
  rateLimit?: RateLimitPolicy
  waf?: WafRule[]
}

export interface Bundle {
  schemaVersion: typeof BUNDLE_SCHEMA_VERSION
  policyName: string
  defaultDecision: DefaultDecision
  matchers: MethodMatcher[]
  routes: CompiledRoute[]
  version: string
}

export interface SignedBundleEnvelope {
  algorithm: typeof SIGNATURE_ALGORITHM
  keyId: string
  bundle: Bundle
  signature: string
}

type JsonObject = Record<string, unknown>

export class BundleValidationError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'BundleValidationError'
  }
}

export function parseBundleEnvelope(
  value: unknown,
): SignedBundleEnvelope {
  const object = expectObject(value, 'envelope')

  assertExactKeys(
    object,
    ['algorithm', 'keyId', 'bundle', 'signature'],
    'envelope',
  )

  const algorithm = expectEnum(
    object.algorithm,
    [SIGNATURE_ALGORITHM],
    'envelope.algorithm',
  )

  const keyId = expectPattern(
    object.keyId,
    /^sha256:[0-9a-f]{64}$/,
    'envelope.keyId',
  )

  const signature = expectPattern(
    object.signature,
    /^[A-Za-z0-9_-]{86}$/,
    'envelope.signature',
  )

  return {
    algorithm,
    keyId,
    bundle: parseBundle(object.bundle),
    signature,
  }
}

function parseBundle(value: unknown): Bundle {
  const object = expectObject(value, 'envelope.bundle')

  assertExactKeys(
    object,
    [
      'schemaVersion',
      'policyName',
      'defaultDecision',
      'matchers',
      'routes',
      'version',
    ],
    'envelope.bundle',
  )

  const schemaVersion = expectEnum(
    object.schemaVersion,
    [BUNDLE_SCHEMA_VERSION],
    'envelope.bundle.schemaVersion',
  )

  const defaultDecision = expectEnum(
    object.defaultDecision,
    ['allow', 'deny'] as const,
    'envelope.bundle.defaultDecision',
  )

  const matchers = expectNonEmptyArray(
    object.matchers,
    'envelope.bundle.matchers',
  ).map((matcher, index) =>
    parseMatcher(
      matcher,
      `envelope.bundle.matchers[${index}]`,
    ),
  )

  const routes = expectNonEmptyArray(
    object.routes,
    'envelope.bundle.routes',
  ).map((route, index) =>
    parseRoute(route, `envelope.bundle.routes[${index}]`),
  )

  return {
    schemaVersion,
    policyName: expectNonEmptyString(
      object.policyName,
      'envelope.bundle.policyName',
    ),
    defaultDecision,
    matchers,
    routes,
    version: expectPattern(
      object.version,
      /^sha256:[0-9a-f]{64}$/,
      'envelope.bundle.version',
    ),
  }
}

function parseMatcher(
  value: unknown,
  path: string,
): MethodMatcher {
  const object = expectObject(value, path)

  assertExactKeys(
    object,
    ['method', 'regex', 'routeIds'],
    path,
  )

  const method = expectPattern(
    object.method,
    /^[A-Z]+$/,
    `${path}.method`,
  )

  const regex = expectNonEmptyString(
    object.regex,
    `${path}.regex`,
  )

  try {
    new RegExp(regex)
  } catch {
    fail(`${path}.regex`, 'must be a valid regular expression')
  }

  return {
    method,
    regex,
    routeIds: expectNonEmptyStringArray(
      object.routeIds,
      `${path}.routeIds`,
    ),
  }
}

function parseRoute(
  value: unknown,
  path: string,
): CompiledRoute {
  const object = expectObject(value, path)

  assertExactKeys(
    object,
    ['id', 'match', 'upstream', 'jwt', 'rateLimit', 'waf'],
    path,
  )

  const route: CompiledRoute = {
    id: expectNonEmptyString(object.id, `${path}.id`),
    match: parseRouteMatch(object.match, `${path}.match`),
    upstream: expectHttpUrl(
      object.upstream,
      `${path}.upstream`,
      false,
    ),
  }

  if (hasOwn(object, 'jwt')) {
    route.jwt = parseJwtPolicy(object.jwt, `${path}.jwt`)
  }

  if (hasOwn(object, 'rateLimit')) {
    route.rateLimit = parseRateLimit(
      object.rateLimit,
      `${path}.rateLimit`,
    )
  }

  if (hasOwn(object, 'waf')) {
    route.waf = expectArray(object.waf, `${path}.waf`).map(
      (rule, index) =>
        parseWafRule(rule, `${path}.waf[${index}]`),
    )
  }

  return route
}

function parseRouteMatch(
  value: unknown,
  path: string,
): RouteMatch {
  const object = expectObject(value, path)

  assertExactKeys(object, ['methods', 'path'], path)

  const routePath = expectNonEmptyString(
    object.path,
    `${path}.path`,
  )

  if (!routePath.startsWith('/')) {
    fail(`${path}.path`, 'must begin with "/"')
  }

  const methods = expectNonEmptyStringArray(
    object.methods,
    `${path}.methods`,
  )

  for (const [index, method] of methods.entries()) {
    if (!/^[A-Z]+$/.test(method)) {
      fail(
        `${path}.methods[${index}]`,
        'must be an uppercase HTTP method',
      )
    }
  }

  return {
    methods,
    path: routePath,
  }
}

function parseJwtPolicy(
  value: unknown,
  path: string,
): JwtPolicy {
  const object = expectObject(value, path)

  assertExactKeys(
    object,
    ['required', 'issuer', 'audience', 'jwksUrl'],
    path,
  )

  if (object.required !== true) {
    fail(`${path}.required`, 'must be true')
  }

  return {
    required: true,
    issuer: expectHttpUrl(
      object.issuer,
      `${path}.issuer`,
      true,
    ),
    audience: expectNonEmptyStringArray(
      object.audience,
      `${path}.audience`,
    ),
    jwksUrl: expectHttpUrl(
      object.jwksUrl,
      `${path}.jwksUrl`,
      true,
    ),
  }
}

function parseRateLimit(
  value: unknown,
  path: string,
): RateLimitPolicy {
  const object = expectObject(value, path)

  assertExactKeys(
    object,
    ['requests', 'window', 'key'],
    path,
  )

  return {
    requests: expectPositiveInteger(
      object.requests,
      `${path}.requests`,
    ),
    window: expectNonEmptyString(
      object.window,
      `${path}.window`,
    ),
    key: expectEnum(
      object.key,
      ['client-ip', 'jwt.sub'] as const,
      `${path}.key`,
    ),
  }
}

function parseWafRule(
  value: unknown,
  path: string,
): WafRule {
  const object = expectObject(value, path)

  assertExactKeys(
    object,
    ['id', 'target', 'pattern', 'flags', 'action'],
    path,
  )

  const rule: WafRule = {
    id: expectNonEmptyString(object.id, `${path}.id`),
    target: expectEnum(
      object.target,
      ['path', 'query', 'headers', 'body'] as const,
      `${path}.target`,
    ),
    pattern: expectNonEmptyString(
      object.pattern,
      `${path}.pattern`,
    ),
    action: expectEnum(
      object.action,
      ['block', 'log'] as const,
      `${path}.action`,
    ),
  }

  if (hasOwn(object, 'flags')) {
    rule.flags = expectEnum(
      object.flags,
      ['i'] as const,
      `${path}.flags`,
    )
  }

  return rule
}

function expectObject(
  value: unknown,
  path: string,
): JsonObject {
  if (
    typeof value !== 'object' ||
    value === null ||
    Array.isArray(value)
  ) {
    fail(path, 'must be an object')
  }

  return value as JsonObject
}

function expectArray(
  value: unknown,
  path: string,
): unknown[] {
  if (!Array.isArray(value)) {
    fail(path, 'must be an array')
  }

  return value
}

function expectNonEmptyArray(
  value: unknown,
  path: string,
): unknown[] {
  const array = expectArray(value, path)

  if (array.length === 0) {
    fail(path, 'must not be empty')
  }

  return array
}

function expectNonEmptyString(
  value: unknown,
  path: string,
): string {
  if (typeof value !== 'string' || value.trim() === '') {
    fail(path, 'must be a non-empty string')
  }

  return value
}

function expectNonEmptyStringArray(
  value: unknown,
  path: string,
): string[] {
  const array = expectNonEmptyArray(value, path)

  return array.map((item, index) =>
    expectNonEmptyString(item, `${path}[${index}]`),
  )
}

function expectPositiveInteger(
  value: unknown,
  path: string,
): number {
  if (
    typeof value !== 'number' ||
    !Number.isSafeInteger(value) ||
    value <= 0
  ) {
    fail(path, 'must be a positive integer')
  }

  return value
}

function expectPattern(
  value: unknown,
  pattern: RegExp,
  path: string,
): string {
  const text = expectNonEmptyString(value, path)

  if (!pattern.test(text)) {
    fail(path, 'has an invalid format')
  }

  return text
}

function expectEnum<const T extends string>(
  value: unknown,
  allowed: readonly T[],
  path: string,
): T {
  if (
    typeof value !== 'string' ||
    !allowed.includes(value as T)
  ) {
    fail(
      path,
      `must be one of: ${allowed.join(', ')}`,
    )
  }

  return value as T
}

function expectHttpUrl(
  value: unknown,
  path: string,
  requireHttps: boolean,
): string {
  const text = expectNonEmptyString(value, path)

  let url: URL

  try {
    url = new URL(text)
  } catch {
    fail(path, 'must be a valid URL')
  }

  if (
    url.protocol !== 'http:' &&
    url.protocol !== 'https:'
  ) {
    fail(path, 'must use HTTP or HTTPS')
  }

  if (url.username !== '' || url.password !== '') {
    fail(path, 'must not contain embedded credentials')
  }

  if (requireHttps && url.protocol !== 'https:') {
    fail(path, 'must use HTTPS')
  }

  if (!requireHttps && !usesSecureTransport(url)) {
    fail(
      path,
      'must use HTTPS unless it targets loopback',
    )
  }

  return text
}

function assertExactKeys(
  object: JsonObject,
  allowedKeys: readonly string[],
  path: string,
): void {
  const allowed = new Set(allowedKeys)

  for (const key of Object.keys(object)) {
    if (!allowed.has(key)) {
      fail(`${path}.${key}`, 'is not supported')
    }
  }
}

function hasOwn(
  object: JsonObject,
  key: string,
): boolean {
  return Object.prototype.hasOwnProperty.call(object, key)
}

function fail(path: string, message: string): never {
  throw new BundleValidationError(`${path} ${message}`)
}
