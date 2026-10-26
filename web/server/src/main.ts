import { buildApp, defaultDeps } from './app.js';
import { PORT } from './auth.js';

const app = await buildApp(defaultDeps());
await app.listen({ host: '127.0.0.1', port: PORT });
