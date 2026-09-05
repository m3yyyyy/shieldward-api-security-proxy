import { Hono } from 'hono'

export const app = new Hono()

app.get('/healthz', (context) =>
  context.json({
    service: 'shieldward-edge',
    status: 'ok',
  }),
)

app.notFound((context) =>
  context.json(
    {
      error: 'route_not_found',
    },
    404,
  ),
)