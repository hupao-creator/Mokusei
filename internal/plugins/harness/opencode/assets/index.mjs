import { fileURLToPath } from 'node:url';
import { readFile } from 'node:fs/promises';
import { readConsoleAccount } from './credentials.mjs';
import { createHash } from 'node:crypto';
const contextHash = value => createHash('sha256').update(JSON.stringify(value, (_, item) =>
  item && typeof item === 'object' && !Array.isArray(item) ?
    Object.fromEntries(Object.entries(item).sort(([a], [b]) => a.localeCompare(b))) : item)).digest('hex');
const { endpoint, token, isolated } = JSON.parse(await readFile(new URL('./transport.json', import.meta.url), 'utf8'));

const RPC = { id: 'mokusei.harness', methods: {
  refresh: { input: { type: 'object', additionalProperties: false }, output: {
    type: 'object', properties: { revisions: { type: 'object' }, tools: { type: 'array', items: { type: 'string' } } },
    required: ['revisions', 'tools']
  } },
  credential: { input: { type: 'object', properties: { providerID: { type: 'string' },
    modelID: { type: 'string' }, variant: { type: 'string' } }, required: ['providerID'] },
    output: { type: 'object', properties: { baseUrl: { type: 'string' }, apiKey: { type: 'string' }, authentication: { type: 'string', enum: ['oauth'] } } } },
  consoleAccount: { input: { type: 'object', properties: { providerID: { type: 'string' },
    modelID: { type: 'string' }, variant: { type: 'string' }, sourceCredentialID: { type: 'string' },
    phase: { type: 'string', enum: ['describe', 'lease'] } },
    required: ['providerID', 'phase'] },
    output: { type: 'object', properties: { provider: { type: 'object' }, model: { type: 'object' },
      variant: { type: 'object' }, lease: { type: 'object' }, configuration: { type: 'object' },
      sourceCredentialID: { type: 'string' } } } }
}, events: {} };

export default {
  id: 'mokusei.harness',
  async setup(ctx) {
    const lifetime = new AbortController();
    const sourcePath = fileURLToPath(import.meta.url);
    let configurations = new Map();
    const assertPlugins = async () => {
      if (!isolated) return;
      const inventory = (await ctx.plugin.list()).data;
      const unsafe = inventory.some(plugin => plugin.state.status === 'active' &&
        plugin.source.type !== 'builtin' && !(plugin.id === 'mokusei.harness' &&
          plugin.source.type === 'local' && plugin.source.path === sourcePath));
      if (unsafe) throw new Error('Mokusei isolated session cannot load external native plugins');
    };
    const invoke = async (path, body, signal) => {
      const response = await fetch(endpoint + path, {
        method: 'POST', headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' },
        body: JSON.stringify(body), signal: signal ? AbortSignal.any([signal, lifetime.signal]) : lifetime.signal
      });
      if (!response.ok) {
        const detail = (await response.text().catch(() => '')).trim();
        throw new Error('Mokusei bridge rejected ' + path + ' (' + response.status + ')' + (detail ? ': ' + detail : ''));
      }
      return response.json();
    };
    const lookup = async (sessionID) => {
      await assertPlugins();
      const visited = new Set();
      let current = sessionID;
      while (current && !visited.has(current) && visited.size < 64) {
        visited.add(current);
        const config = configurations.get(current);
        if (config) return config;
        const session = await ctx.session.get({ sessionID: current });
        current = session.parentID;
      }
      throw new Error('Mokusei has not configured this native session');
    };
    const loadConfiguration = async () => {
      const data = await invoke('/configuration', {});
      configurations = new Map(data.sessions.map(config => [config.sessionID, config]));
      await ctx.tool.reload();
      const tools = (await ctx.tool.list()).map(tool => tool.id);
      const expected = data.sessions.flatMap(config => config.tools.map(tool => tool.id));
      if (expected.some(name => !tools.includes(name))) throw new Error('Mokusei native tool registration failed');
      return { revisions: Object.fromEntries(data.sessions.map(config => [config.sessionID, config.revision])), tools };
    };
    const refresh = async () => { await assertPlugins(); const result = await loadConfiguration(); return result; };
    await ctx.tool.transform(editor => {
      for (const config of configurations.values()) for (const tool of config.tools) {
        editor.add({
          name: tool.id, description: tool.description, input: tool.inputSchema, output: tool.outputSchema,
          options: { codemode: false },
          async execute(input, context) {
            const owner = await lookup(context.sessionID);
            if (owner.sessionID !== config.sessionID) throw new Error('Mokusei tool belongs to another session');
            const result = await invoke('/tool', {
              rootSessionID: config.sessionID, sessionID: context.sessionID, revision: config.revision,
              name: tool.name, callId: context.id, arguments: input
            }, context.signal);
            return { output: result.value };
          }
        });
      }
    });
    const credential = async input => {
      await assertPlugins();
      const provider = (await ctx.provider.get({ providerID: input.providerID })).data;
      const model = input.modelID ? (await ctx.model.list()).data.find(item => item.providerID === input.providerID && item.id === input.modelID) : undefined;
      if (input.modelID && !model) return {};
      const variant = input.variant && input.variant !== 'default' ? model?.variants?.find(item => item.id === input.variant) : undefined;
      if (input.variant && input.variant !== 'default' && !variant) return {};
      const connection = await ctx.integration.connection.active(provider.integrationID || input.providerID);
      const oauth = connection?.type === 'credential' && connection.method === 'oauth';
      const value = connection && !oauth ? await ctx.integration.connection.resolve(connection) : undefined;
      // OAuth contributes only effective routing metadata. Never return its
      // bearer or refresh token as an API-key account credential.
      if (value && value.type !== 'key' && value.type !== 'oauth') return {};
      const settings = { ...provider.settings, ...model?.settings, ...variant?.settings,
        ...value?.metadata, ...value?.configuration };
      const headers = { ...provider.headers, ...model?.headers, ...variant?.headers };
      if (Object.keys(headers).some(name => /^(authorization|x-api-key|api-key)$/i.test(name))) return {};
      const baseUrl = settings.baseURL;
      const apiKey = oauth ? undefined : value ? (value.type === 'key' ? value.key : undefined) : settings.apiKey;
      return { ...(typeof baseUrl === 'string' ? { baseUrl } : {}), ...(typeof apiKey === 'string' ? { apiKey } : {}),
        ...(oauth || value?.type === 'oauth' ? { authentication: 'oauth' } : {}) };
    };
    await ctx.rpc.register(RPC, { refresh, credential,
      consoleAccount: async input => { await assertPlugins(); return readConsoleAccount(ctx, input); }
    });
    await ctx.tool.hook('execute.before', async event => {
      const owner = await lookup(event.sessionID);
      await invoke('/before-tool', { rootSessionID: owner.sessionID, sessionID: event.sessionID, revision: owner.revision, name: event.tool });
    });
    const prepare = kind => async event => {
      const config = await lookup(event.sessionID);
      // A native fork folds current instructions into its initial system block.
      // Preserve the source's rendered instruction prefix for provider caching;
      // user/assistant/tool history and the read question remain native fork data.
      let readPrefix;
      if (kind === 'primary' && event.sessionID === config.sessionID) {
        const indices = new Set();
        const first = event.messages.findIndex(message => message.role !== 'system');
        if (first >= 0) indices.add(first);
        const messages = event.messages.flatMap((message, index) => {
          if (message.role !== 'system') return [];
          if (index > 0 && event.messages[index - 1].role !== 'system') indices.add(index - 1);
          return [{ index, message }];
        });
        const prefix = { system: event.system, messages,
          anchors: [...indices].map(index => ({ index, hash: contextHash(event.messages[index]) })) };
        if (JSON.stringify(prefix).length <= 1_000_000) readPrefix = prefix;
      }
      await invoke('/before-model', { rootSessionID: config.sessionID, sessionID: event.sessionID,
        revision: config.revision, kind, model: event.model, readPrefix });
      const prefix = config.readPrefix;
      if (kind === 'generate' && prefix && Array.isArray(prefix.system) &&
          Array.isArray(prefix.anchors) && prefix.anchors.length > 0 && prefix.anchors.every(item =>
            Number.isInteger(item.index) && item.index >= 0 && event.messages[item.index] &&
            contextHash(event.messages[item.index]) === item.hash) &&
          Array.isArray(prefix.messages) && prefix.messages.every(item =>
            Number.isInteger(item.index) && item.index >= 0 && item.message?.role === 'system' &&
            event.messages[item.index]?.role === 'system')) {
        event.system = structuredClone(prefix.system);
        for (const item of prefix.messages) event.messages[item.index] = structuredClone(item.message);
      }
      const advertised = Object.create(null);
      // Native generate reuses the source context without executing a tool loop.
      // Keep the same tool definitions for its provider prefix and cache reuse.
      if (config.mode !== 'exclusive') for (const [name, definition] of Object.entries(event.tools)) {
        if (!name.startsWith('mokusei_host_')) advertised[name] = definition;
      }
      for (const tool of config.tools) {
        const definition = event.tools[tool.id];
        if (!definition) throw new Error('Mokusei injected tool is unavailable: ' + tool.name);
        // Preserve object identity so OpenCode maps the public alias to the captured executor.
        advertised[tool.name] = definition;
      }
      event.tools = advertised;
      if (config.instructions) event.system.push({ type: 'text', text: config.instructions });
      if (config.seed.length) event.messages.unshift(...structuredClone(config.seed));
      Object.assign(event.options, config.modelOptions);
    };
    await ctx.session.hook('prompt', async event => { await lookup(event.sessionID); });
    await ctx.session.hook('context', prepare('primary'));
    await ctx.session.hook('compaction', prepare('compaction'));
    await ctx.session.hook('generate', prepare('generate'));
    await ctx.session.hook('model.request', async event => { await lookup(event.sessionID); });
    await ctx.session.hook('experimental.ws.handshake', async event => { await lookup(event.sessionID); });
    // Mokusei owns titles. This also prevents auxiliary unadmitted model requests.
    await ctx.session.hook('title', event => { event.result = 'Mokusei'; });
    await ctx.session.hook('http.request', async event => {
      const config = await lookup(event.sessionID);
      const response = await invoke('/http-request', { rootSessionID: config.sessionID, sessionID: event.sessionID, revision: config.revision, path: new URL(event.request.url).pathname });
      if (!response.responseFormat) return;
      const body = await event.request.clone().json();
      body.response_format = response.responseFormat;
      const headers = new Headers(event.request.headers);
      headers.delete('content-length');
      event.request = new Request(event.request, { headers, body: JSON.stringify(body) });
    });
    // Keep rejecting hooks installed even if an external plugin appears during a native location reload.
    // The caller's startup/refresh RPC verifies the inventory before it can admit any work.
    await loadConfiguration();
    return () => lifetime.abort();
  }
};
