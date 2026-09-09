import {
  Hono,
  type Context,
} from 'hono'

import type { ConfigurationSnapshot } from './config-client.js'
import type { OperationalMetrics } from './metrics.js'
import { isLoopbackHostname } from './transport.js'

export interface GatewayHandler {
  handle(
    request: Request,
    clientIp?: string,
  ): Promise<Response>
  acceptingRequests?(): boolean
}

export interface ConfigurationStatus {
  current(): ConfigurationSnapshot | undefined
}

export interface DependencyStatus {
  ready(): boolean
}

export type ClientIpResolver = (
  context: Context,
) => string | undefined

export interface ApplicationOptions {
  readonly gateway?: GatewayHandler
  readonly configuration?: ConfigurationStatus
  readonly resolveClientIp?: ClientIpResolver
  readonly secureTransport?: boolean
  readonly metrics?: OperationalMetrics
  readonly rateLimiter?: DependencyStatus
}

export function createApp(
  options: ApplicationOptions = {},
): Hono {
  const application = new Hono()

  application.use('*', async (context, next) => {
    await next()

    context.header('X-Content-Type-Options', 'nosniff')
    context.header('Referrer-Policy', 'no-referrer')

    if (options.secureTransport === true) {
      context.header(
        'Strict-Transport-Security',
        'max-age=31536000',
      )
    }
  })

  application.get('/healthz', (context) => {
    context.header('Cache-Control', 'no-store')

    return context.json({
      service: 'shieldward-edge',
      status: 'ok',
    })
  })

  application.get('/readyz', (context) => {
    const snapshot = options.configuration?.current()
    const rateLimiterReady = isDependencyReady(
      options.rateLimiter,
    )
    const gatewayReady = isGatewayAccepting(
      options.gateway,
    )

    context.header('Cache-Control', 'no-store')

    if (
      snapshot === undefined ||
      !rateLimiterReady ||
      !gatewayReady
    ) {
      return context.json(
        {
          service: 'shieldward-edge',
          status: 'not_ready',
        },
        503,
      )
    }

    return context.json({
      service: 'shieldward-edge',
      status: 'ready',
      policyVersion: snapshot.bundle.version,
    })
  })

  application.get('/metrics', (context) => {
    const clientIp = resolveClientIp(
      context,
      options.resolveClientIp,
    )

    if (
      options.metrics === undefined ||
      clientIp === undefined ||
      !isLoopbackHostname(clientIp)
    ) {
      return context.json(
        {
          error: 'route_not_found',
        },
        404,
      )
    }

    const snapshot = options.configuration?.current()
    const rateLimiterReady = isDependencyReady(
      options.rateLimiter,
    )
    const gatewayReady = isGatewayAccepting(
      options.gateway,
    )

    context.header('Cache-Control', 'no-store')
    context.header(
      'Content-Type',
      'text/plain; version=0.0.4; charset=utf-8',
    )

    return context.body(
      options.metrics.render({
        ready:
          snapshot !== undefined &&
          rateLimiterReady &&
          gatewayReady,
        rateLimiterReady,
        ...(snapshot === undefined
          ? {}
          : {
              policyLoadedAtMilliseconds:
                snapshot.loadedAt,
            }),
      }),
    )
  })

  application.all('*', async (context) => {
    if (options.gateway === undefined) {
      return context.json(
        {
          error: 'route_not_found',
        },
        404,
      )
    }

    const clientIp = resolveClientIp(
      context,
      options.resolveClientIp,
    )

    return options.gateway.handle(
      context.req.raw,
      clientIp,
    )
  })

  application.notFound((context) =>
    context.json(
      {
        error: 'route_not_found',
      },
      404,
    ),
  )

  application.onError((_error, context) => {
    context.header('Cache-Control', 'no-store')

    return context.json(
      {
        error: 'internal_server_error',
      },
      500,
    )
  })

  return application
}

export const app = createApp()

function resolveClientIp(
  context: Context,
  resolver: ClientIpResolver | undefined,
): string | undefined {
  try {
    return resolver?.(context)
  } catch {
    return undefined
  }
}

function isDependencyReady(
  dependency: DependencyStatus | undefined,
): boolean {
  try {
    return dependency?.ready() ?? true
  } catch {
    return false
  }
}

function isGatewayAccepting(
  gateway: GatewayHandler | undefined,
): boolean {
  try {
    return gateway?.acceptingRequests?.() ?? true
  } catch {
    return false
  }
}
