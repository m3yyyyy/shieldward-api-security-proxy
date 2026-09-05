import { describe, expect, it } from 'vitest'

import { app } from '../src/app.js'

describe('ShieldWard edge application', () => {
  it('reports a healthy service', async () => {
    const response = await app.request('/healthz')

    expect(response.status).toBe(200)
    await expect(response.json()).resolves.toEqual({
      service: 'shieldward-edge',
      status: 'ok',
    })
  })

  it('returns a structured response for unknown routes', async () => {
    const response = await app.request('/unknown')

    expect(response.status).toBe(404)
    await expect(response.json()).resolves.toEqual({
      error: 'route_not_found',
    })
  })
})