// Minimal installed-distribution fixture. Wire shapes captured from shuvcode
// v2.0.23-shuv.1; no installed binary, npm package or service is consulted.
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export function installPackage(binary, version = "2.0.23-shuv.1") {
  const dir = dirname(binary);
  mkdirSync(join(dir, "client/generated"), { recursive: true });
  writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "shuvcode", version, type: "module" }));
  writeFileSync(join(dir, "client/generated/types.d.ts"), ["session.inbox.enqueued", "session.execution.started", "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"].map(type => `type: "${type}";`).join("\n"));
  writeFileSync(join(dir, "client/index.js"), `
export const OpenCode = { make({baseUrl, fetch}) {
  function request(method, path, body, query = {}) {
    const url = new URL(path, baseUrl);
    for (const [key, value] of Object.entries(query)) url.searchParams.set(key, value);
    return fetch(url, {method, body: body === undefined ? undefined : JSON.stringify(body)});
  }
  const path = input => '/api/session/' + input.sessionID;
  const location = input => ({'location[directory]': input.location.directory});
  const client = {
    server: {info: () => request('GET', '/api/info')},
    config: {get: input => request('GET', '/api/config', undefined, location(input))},
    model: {
      list: input => request('GET', '/api/model', undefined, location(input)),
      default: input => request('GET', '/api/model/default', undefined, location(input)),
    },
    session: {
      create: ({location, model}) => request('POST', '/api/session', {location, model}),
      get: input => request('GET', path(input)),
      active: () => request('GET', '/api/session/active'),
      switchModel: input => request('POST', path(input) + '/model', {model: input.model}),
      update: input => request('PATCH', path(input), {metadata: input.metadata}),
      environment: input => request('PUT', path(input) + '/environment', {variables: input.variables}),
      prompt: input => request('POST', path(input) + '/prompt', {id: input.id, text: input.text, delivery: process.env.PROBE_DROP_DELIVERY ? undefined : input.delivery}),
      interrupt: input => request('POST', path(input) + '/interrupt', undefined, process.env.PROBE_DROP_RESUME ? {} : {resume: input.resume}),
    },
    message: {list: input => request('GET', path(input) + '/message', undefined, {order: input.order, limit: input.limit})},
  };
  if (process.env.PROBE_LEGACY_MESSAGE) {
    client.session.message = client.message;
    delete client.message;
  }
  if (process.env.PROBE_MISSING_API) {
    const keys = process.env.PROBE_MISSING_API.split('.');
    const key = keys.pop();
    delete keys.reduce((object, key) => object[key], client)[key];
  }
  return client;
} };
`);
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) installPackage(process.argv[2], process.argv[3]);
