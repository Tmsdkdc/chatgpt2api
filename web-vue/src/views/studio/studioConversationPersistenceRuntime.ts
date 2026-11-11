import { ref, type Ref, watch } from 'vue'
import { getStringPreference, preferenceKeys } from '@/lib/preferences'
import type { StudioConversation, StudioConversationBadgeState } from '@/components/studio/types'
import { loadStudioConversationNotices, loadStudioConversations, normalizeStudioConversations, studioConversationSnapshot } from './studioConversationState'
import { readStudioConversationSnapshot, writeStudioConversationSnapshot } from './studioConversationStorage'

type StudioConversationPersistenceState = {
  schema: 1
  conversations: StudioConversation[]
  conversationNotices: Record<string, StudioConversationBadgeState>
  activeConversationId: string
}

export type StudioConversationPersistenceRuntimeInput = {
  conversations: Ref<StudioConversation[]>
  conversationNotices: Ref<Record<string, StudioConversationBadgeState>>
  activeConversationId: Ref<string>
  validConversationIds: { value: Set<string> }
}

export async function loadStudioConversationPersistenceState(): Promise<StudioConversationPersistenceState> {
  const saved = await readStudioConversationSnapshot()
  if (saved !== undefined) {
    const parsed = JSON.parse(saved) as Partial<StudioConversationPersistenceState> | null
    if (!parsed || parsed.schema !== 1 || !Array.isArray(parsed.conversations)
      || typeof parsed.activeConversationId !== 'string' || !parsed.conversationNotices
      || typeof parsed.conversationNotices !== 'object' || Array.isArray(parsed.conversationNotices)) {
      throw new Error('Invalid Studio history snapshot')
    }
    return { ...parsed, conversations: normalizeStudioConversations(parsed.conversations) } as StudioConversationPersistenceState
  }
  const legacy: StudioConversationPersistenceState = {
    schema: 1,
    activeConversationId: getStringPreference(preferenceKeys.studioActiveConversationId, ''),
    conversationNotices: loadStudioConversationNotices(),
    conversations: loadStudioConversations(),
  }
  // Commit migration before accepting edits. Keep localStorage untouched as a
  // legacy backup; failed migration must never replace the original records.
  await writeStudioConversationSnapshot(JSON.stringify(legacy))
  return legacy
}

export type StudioConversationPersistenceRuntime = ReturnType<typeof useStudioConversationPersistenceRuntime>

export function useStudioConversationPersistenceRuntime(input: StudioConversationPersistenceRuntimeInput) {
  const ready = ref(false)
  const loading = ref(false)
  const saving = ref(false)
  const error = ref('')
  let dirty = false
  let scheduled = false
  let pending: string | null = null
  let savingPromise: Promise<void> | null = null
  let loadingPromise: Promise<boolean> | null = null
  let disposed = false

  const stopConversationWatch = watch(input.conversations, scheduleSave, { flush: 'sync' })
  const stopNoticeWatch = watch(input.conversationNotices, scheduleSave, { flush: 'sync' })
  const stopActiveWatch = watch(input.activeConversationId, scheduleSave, { flush: 'sync' })

  function scheduleSave() {
    if (!ready.value || disposed) return
    dirty = true
    saving.value = true
    if (scheduled) return
    scheduled = true
    queueMicrotask(() => { scheduled = false; void flush() })
  }

  function snapshot() {
    return JSON.stringify({
      schema: 1,
      conversations: studioConversationSnapshot(input.conversations.value),
      conversationNotices: Object.fromEntries(Object.entries(input.conversationNotices.value).filter(
        ([id, state]) => input.validConversationIds.value.has(id) && (state === 'done' || state === 'error'),
      )),
      activeConversationId: input.activeConversationId.value,
    })
  }

  async function drain() {
    while (pending !== null) {
      const payload = pending
      pending = null
      try {
        await writeStudioConversationSnapshot(payload)
        error.value = ''
      } catch {
        // Preserve the newest queued snapshot for an explicit retry.
        if (pending === null) pending = payload
        error.value = '聊天记录保存失败，请保留此页面并重试。'
        break
      }
    }
    saving.value = dirty || pending !== null
    savingPromise = null
  }

  function flush(): Promise<void> {
    if (!ready.value) return Promise.resolve()
    if (dirty) {
      try { pending = snapshot(); dirty = false } catch {
        error.value = '聊天记录保存失败，请保留此页面并重试。'
        return Promise.resolve()
      }
    }
    if (savingPromise) return savingPromise
    if (pending === null) return Promise.resolve()
    saving.value = true
    savingPromise = drain()
    return savingPromise
  }

  function load(): Promise<boolean> {
    if (ready.value) return Promise.resolve(true)
    if (loadingPromise) return loadingPromise
    loading.value = true
    loadingPromise = (async () => {
      try {
        const state = await loadStudioConversationPersistenceState()
        if (disposed) return false
        input.conversations.value = state.conversations
        input.conversationNotices.value = state.conversationNotices
        input.activeConversationId.value = state.activeConversationId
        error.value = ''
        ready.value = true
        return true
      } catch {
        error.value = '聊天记录读取失败，原有数据已保留，请重试。'
        return false
      } finally { loading.value = false; loadingPromise = null }
    })()
    return loadingPromise
  }

  function beforeUnload(event: BeforeUnloadEvent) {
    void flush()
    if (dirty || pending !== null || savingPromise) {
      event.preventDefault()
      event.returnValue = ''
    }
  }
  const pageHide = () => { void flush() }
  window.addEventListener('beforeunload', beforeUnload)
  window.addEventListener('pagehide', pageHide)

  function dispose() {
    stopConversationWatch()
    stopNoticeWatch()
    stopActiveWatch()
    void flush()
    disposed = true
    window.removeEventListener('beforeunload', beforeUnload)
    window.removeEventListener('pagehide', pageHide)
  }

  return {
    ready, loading, saving, error, load, flush,
    scheduleConversationNotices: scheduleSave,
    scheduleConversations: scheduleSave,
    dispose,
  }
}
