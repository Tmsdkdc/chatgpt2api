// Studio history remains browser-local; server task/asset storage is independent.
const DATABASE_NAME = 'chatgpt2api-studio'
const STORE_NAME = 'state'
const SNAPSHOT_KEY = 'snapshot'
let connection: Promise<IDBDatabase> | null = null

function openDatabase(): Promise<IDBDatabase> {
  if (connection) return connection
  const opening = new Promise<IDBDatabase>((resolve, reject) => {
    const request = window.indexedDB.open(DATABASE_NAME, 1)
    let blocked = false
    request.onupgradeneeded = () => { request.result.createObjectStore(STORE_NAME) }
    request.onblocked = () => {
      blocked = true
      reject(new Error('Studio history database is blocked'))
    }
    request.onerror = () => reject(request.error)
    request.onsuccess = () => {
      const database = request.result
      if (blocked) { database.close(); return }
      database.onversionchange = () => { database.close(); connection = null }
      resolve(database)
    }
  })
  connection = opening
  void opening.catch(() => { if (connection === opening) connection = null })
  return opening
}

export async function readStudioConversationSnapshot(): Promise<string | undefined> {
  const database = await openDatabase()
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(STORE_NAME, 'readonly')
    const request = transaction.objectStore(STORE_NAME).get(SNAPSHOT_KEY)
    transaction.oncomplete = () => {
      if (request.result !== undefined && typeof request.result !== 'string') {
        reject(new Error('Invalid Studio history snapshot'))
      } else { resolve(request.result) }
    }
    transaction.onabort = () => reject(transaction.error || new Error('Studio history read aborted'))
    transaction.onerror = () => { /* onabort owns failure completion */ }
  })
}

export async function writeStudioConversationSnapshot(payload: string): Promise<void> {
  const database = await openDatabase()
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(STORE_NAME, 'readwrite')
    transaction.objectStore(STORE_NAME).put(payload, SNAPSHOT_KEY)
    // A successful put request is not a committed transaction.
    transaction.oncomplete = () => resolve()
    transaction.onabort = () => reject(transaction.error || new Error('Studio history save aborted'))
    transaction.onerror = () => { /* onabort owns failure completion */ }
  })
}
