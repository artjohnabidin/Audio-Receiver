import { app } from '@azure/functions';
import { createStreamControlNegotiateHandler } from '../stream-control-negotiate-handler.js';

app.http('streamControlNegotiate', {
  route: 'stream-control/negotiate',
  methods: ['GET', 'OPTIONS'],
  authLevel: 'anonymous',
  handler: (request, context) =>
    createStreamControlNegotiateHandler({ log: context })(request),
});
