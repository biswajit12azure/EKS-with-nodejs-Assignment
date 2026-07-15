const request = require('supertest');
const app = require('../index');

describe('GET /', () => {
  it('returns Hello World message', async () => {
    const res = await request(app).get('/');
    expect(res.statusCode).toBe(200);
    expect(res.body.message).toBe('Hello World from EKS!');
  });
});

describe('GET /health', () => {
  it('returns healthy status', async () => {
    const res = await request(app).get('/health');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('healthy');
    expect(res.body).toHaveProperty('uptime');
    expect(res.body).toHaveProperty('timestamp');
  });
});

describe('GET /users', () => {
  it('returns list of users', async () => {
    const res = await request(app).get('/users');
    expect(res.statusCode).toBe(200);
    expect(Array.isArray(res.body.users)).toBe(true);
    expect(res.body.users.length).toBeGreaterThan(0);
  });
});

describe('GET /users/:id', () => {
  it('returns a single user', async () => {
    const res = await request(app).get('/users/1');
    expect(res.statusCode).toBe(200);
    expect(res.body.user.id).toBe(1);
  });

  it('returns 404 for unknown user', async () => {
    const res = await request(app).get('/users/999');
    expect(res.statusCode).toBe(404);
  });
});
