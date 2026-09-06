import {
  Hono,
  type Context,
} from 'hono'

import type { ConfigurationSnapshot } from './config-client.js'

export interface GatewayHandler {
  handle(
    request: Request,
    clientIp?: string,
  ): Promise<Response>
}

export interface ConfigurationStatus {
  current(): ConfigurationSnapshot | undefined
}

export type ClientIpResolver = (
  context: Context,
) => string | undefined

export interface ApplicationOptions {
  readonly gateway?: GatewayHandler
  readonly configuration?: ConfigurationStatus
  readonly resolveClientIp?: ClientIpResolver
  readonly secureTransport?: boolean
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

  application.get('/healthz', (context) =>
    context.json({
      service: 'shieldward-edge',
      status: 'ok',
    }),
  )

  application.get('/readyz', (context) => {
    const snapshot = options.configuration?.current()

    context.header('Cache-Control', 'no-store')

    if (snapshot === undefined) {
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

  application.all('*', async (context) => {
    if (options.gateway === undefined) {
      return context.json(
        {
          error: 'route_not_found',
        },
        404,
      )
    }

    let clientIp: string | undefined

    try {
      clientIp =
        options.resolveClientIp?.(context)
    } catch {
      clientIp = undefined
    }

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
