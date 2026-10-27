import type { JsonObject } from '@mokusei/contracts'
import { defineValueContract, type QueryKey } from '@mokusei/application-contracts'
import { z } from 'zod'

const scope = z.enum(['unstaged', 'staged', 'untracked', 'conflicts'])
export type GitDiffScope = z.infer<typeof scope>
const file = z.strictObject({ path: z.string(), oldPath: z.string().nullable(),
  status: z.string(), scope, submodule: z.boolean() })
export type GitChangedFile = z.infer<typeof file>
const selection = z.strictObject({ activityId: z.string().min(1).max(256), scope,
  path: z.string().min(1).max(32_768).refine(value => !value.includes('\0')) })
export type GitDiffSelection = z.infer<typeof selection>
const content = z.strictObject({ patch: z.string(), notice: z.enum(['binary', 'empty', 'too-large', 'conflict', 'submodule']).nullable() })
export type GitDiffContent = z.infer<typeof content>
function query<I, O>(id: string, input: z.ZodType<I>, output: z.ZodType<O>): QueryKey<I, O> {
  const contract = <T>(name: string, schema: z.ZodType<T>) => defineValueContract(name,
    value => schema.parse(value), z.toJSONSchema(schema, { io: 'input' }) as JsonObject)
  return { id, kind: 'query', ownerPluginId: 'git', input: contract(`${id}.input`, input), output: contract(`${id}.output`, output) }
}
export const gitDiffContracts = {
  files: query('git.files', z.strictObject({ activityId: z.string().min(1).max(256) }),
    z.strictObject({ files: z.array(file), readAt: z.number() })),
  diff: query('git.diff', selection, content)
}
