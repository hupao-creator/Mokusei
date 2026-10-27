// Native Console billing facts only. Authentication and OAuth refresh stay in OpenCode.
const pending = new Map();
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const nonempty = value => typeof value === 'string' && value.length > 0;
const identity = connection => connection?.type === 'credential' ? connection.id
  : connection?.type === 'env' ? 'env:' + connection.name : undefined;
const queue = async (integrationID, operation) => {
  const previous = pending.get(integrationID) || Promise.resolve();
  const current = previous.catch(() => {}).then(operation);
  pending.set(integrationID, current);
  try { return await current; }
  finally { if (pending.get(integrationID) === current) pending.delete(integrationID); }
};
const oauthLease = (value, allowExpired = false) => {
  if (!object(value) || value.type !== 'oauth' || !nonempty(value.methodID) || !nonempty(value.access) ||
      !Number.isSafeInteger(value.expires) || value.expires < 0 ||
      (!allowExpired && value.expires !== 0 && value.expires <= Date.now()) ||
      (value.metadata !== undefined && !object(value.metadata))) {
    throw new Error('Mokusei received invalid native Console OAuth facts');
  }
  // Do not spread value: its real refresh token stays inside this native OpenCode server.
  return { type: 'oauth', methodID: value.methodID, access: value.access, expires: value.expires,
    ...(value.metadata === undefined ? {} : { metadata: structuredClone(value.metadata) }) };
};
const pinned = async (ctx, integrationID, sourceCredentialID) => {
  const connection = await ctx.integration.connection.active(integrationID);
  if (!connection || identity(connection) !== sourceCredentialID) {
    throw new Error('Mokusei native account changed; reopen the session to select the account');
  }
  return connection;
};

// Return native account/model facts; Go applies Console attribution policy.
// Only this callback may resolve the native OAuth object, and strips its grant.
export async function readConsoleAccount(ctx, input) {
  if (!object(input) || !nonempty(input.providerID)) {
    throw new Error('Mokusei Console account identity is invalid');
  }
  return queue('opencode', async () => {
    const connection = await ctx.integration.connection.active('opencode');
    if (!connection || connection.type !== 'credential' || connection.method !== 'oauth') return {};
    if (input.sourceCredentialID) await pinned(ctx, 'opencode', input.sourceCredentialID);
    if (input.phase === 'describe') {
      const provider = (await ctx.provider.get({ providerID: input.providerID })).data;
      const model = (await ctx.model.list()).data.find(value => value.providerID === input.providerID && value.id === input.modelID);
      const variant = input.variant && input.variant !== 'default' ? model?.variants?.find(value => value.id === input.variant) : undefined;
      await pinned(ctx, 'opencode', connection.id);
      return { provider: provider || {}, model: model || {}, variant: variant || {},
        sourceCredentialID: connection.id };
    }
    if (input.phase !== 'lease') throw new Error('Mokusei Console fact request is invalid');
    await pinned(ctx, 'opencode', input.sourceCredentialID);
    if (connection.type !== 'credential' || connection.method !== 'oauth') return {};
    const value = await ctx.integration.connection.resolve(connection);
    await pinned(ctx, 'opencode', input.sourceCredentialID);
    const lease = oauthLease(value);
    return { lease, configuration: object(value.configuration) ? structuredClone(value.configuration) : {} };
  });
}
