import type {
  Bundle,
  CompiledRoute,
  DefaultDecision,
} from './bundle.js'

export type RouteResolution =
  | {
      readonly kind: 'matched'
      readonly route: Readonly<CompiledRoute>
    }
  | {
      readonly kind: 'default'
      readonly decision: DefaultDecision
    }

interface RuntimeMatcher {
  readonly regex: RegExp
  readonly routeIds: readonly string[]
}

export class RouteMatcherError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'RouteMatcherError'
  }
}

export class RouteMatcher {
  readonly #defaultDecision: DefaultDecision
  readonly #routesById = new Map<
    string,
    Readonly<CompiledRoute>
  >()
  readonly #matchersByMethod = new Map<
    string,
    RuntimeMatcher
  >()

  constructor(bundle: Readonly<Bundle>) {
    this.#defaultDecision = bundle.defaultDecision

    for (const route of bundle.routes) {
      if (this.#routesById.has(route.id)) {
        throw new RouteMatcherError(
          `duplicate route ID: ${route.id}`,
        )
      }

      this.#routesById.set(route.id, route)
    }

    for (const matcher of bundle.matchers) {
      if (this.#matchersByMethod.has(matcher.method)) {
        throw new RouteMatcherError(
          `duplicate matcher method: ${matcher.method}`,
        )
      }

      if (
        !matcher.regex.startsWith('^') ||
        !matcher.regex.endsWith('$')
      ) {
        throw new RouteMatcherError(
          `matcher for ${matcher.method} must be anchored`,
        )
      }

      for (const routeId of matcher.routeIds) {
        if (!this.#routesById.has(routeId)) {
          throw new RouteMatcherError(
            `matcher references unknown route: ${routeId}`,
          )
        }
      }

      this.#matchersByMethod.set(matcher.method, {
        regex: new RegExp(matcher.regex),
        routeIds: matcher.routeIds,
      })
    }
  }

  resolve(method: string, path: string): RouteResolution {
    const normalizedMethod = method.toUpperCase()
    const matcher =
      this.#matchersByMethod.get(normalizedMethod)

    if (matcher === undefined) {
      return this.#defaultResolution()
    }

    const match = matcher.regex.exec(path)

    if (match === null) {
      return this.#defaultResolution()
    }

    for (
      let index = 0;
      index < matcher.routeIds.length;
      index += 1
    ) {
      if (match[index + 1] === undefined) {
        continue
      }

      const routeId = matcher.routeIds[index]!
      const route = this.#routesById.get(routeId)

      if (route === undefined) {
        throw new RouteMatcherError(
          `matched route is unavailable: ${routeId}`,
        )
      }

      return {
        kind: 'matched',
        route,
      }
    }

    throw new RouteMatcherError(
      `matcher for ${normalizedMethod} matched without identifying a route`,
    )
  }

  #defaultResolution(): RouteResolution {
    return {
      kind: 'default',
      decision: this.#defaultDecision,
    }
  }
}