// 上傳 / 取 URL / 刪除 portfolio bucket 的圖片
const BUCKET = 'portfolio'

export function usePortfolio() {
  const supabase = useSupabaseClient()

  function publicUrl(path: string | null | undefined) {
    if (!path) return null
    return supabase.storage.from(BUCKET).getPublicUrl(path).data.publicUrl
  }

  /**
   * 上傳檔案到指定 path。upsert=true 允許覆蓋同名 (服務代表圖用)。
   * @returns 完整 storage path,失敗回 null + error
   */
  async function upload(path: string, file: File, opts: { upsert?: boolean } = {}) {
    const { error } = await supabase.storage.from(BUCKET).upload(path, file, {
      upsert: opts.upsert ?? false,
      contentType: file.type,
      cacheControl: '3600',
    })
    if (error) return { error: error.message, path: null }
    return { error: null, path }
  }

  async function remove(path: string) {
    const { error } = await supabase.storage.from(BUCKET).remove([path])
    return error ? error.message : null
  }

  function buildExt(file: File) {
    return (file.name.split('.').pop() || 'jpg').toLowerCase()
  }

  function randomName() {
    return crypto.randomUUID().replace(/-/g, '').slice(0, 16)
  }

  return { publicUrl, upload, remove, buildExt, randomName }
}
