// composables/useBooking.ts
// =============================================================
// 預約系統前端對接 — 包裝 0001 / 0002 的三個 Supabase RPC：
//   getAvailableSlots  → get_available_slots
//   createBooking      → create_booking       (指定設計師)
//   createBookingAny   → create_booking_any   (不指定設計師)
//
// 需求：專案已安裝 @nuxtjs/supabase，useSupabaseClient() 可用。
//   npm i @nuxtjs/supabase
//   nuxt.config: modules: ['@nuxtjs/supabase']
// =============================================================

import { ref } from 'vue'

// ---------- 型別 ----------
export interface BookingInput {
  tenantId: string
  serviceId: string
  /** ISO 8601，建議帶時區，例如 '2026-06-01T14:00:00+08:00' */
  startAt: string
  customerName: string
  customerPhone: string
  customerEmail?: string | null
  note?: string | null
  /** 指定設計師時必填；不指定設計師時留空走 createBookingAny */
  staffId?: string
}

export interface CreateBookingResult {
  bookingId: string
  /** 不指定設計師時，回傳系統實際指派到的設計師 */
  staffId: string | null
}

// Postgres errcode / RAISE message → 使用者看得懂的中文
const ERROR_MESSAGES: Record<string, string> = {
  slot_taken: '這個時段剛被預約走了，請換一個時間。',
  slot_unavailable: '這個時段目前無法預約，請選擇其他時段。',
  staff_cannot_serve: '這位設計師沒有提供此服務，請重新選擇。',
  no_staff_available: '這個時段已無可預約的設計師，請換一個時間。',
  service_not_found: '找不到此服務，請重新整理頁面後再試。',
  // 故意不洩漏「黑名單」字眼，讓客人去問店家，不傷顏面也不引爆爭執
  member_blacklisted: '預約無法建立，請直接聯絡店家確認。',
}

/** 從 Supabase RPC 錯誤物件解析出我們在 SQL 裡 raise 的代碼字串 */
function parseRpcError(error: unknown): { code: string; message: string } {
  // supabase-js 的 PostgrestError：{ message, code, details, hint }
  const e = error as { message?: string; code?: string } | null
  const raw = e?.message ?? ''
  // 我們的 raise 訊息本身就是代碼(如 'slot_taken')，可能被包在前綴文字裡
  const known = Object.keys(ERROR_MESSAGES).find((k) => raw.includes(k))
  if (known) return { code: known, message: ERROR_MESSAGES[known] }
  return { code: e?.code ?? 'unknown', message: '預約失敗，請稍後再試。' }
}

export function useBooking() {
  const supabase = useSupabaseClient()
  const loading = ref(false)
  const error = ref<string | null>(null)

  /**
   * 查詢某設計師、某日、某服務的可預約起始時間。
   * @returns ISO 字串陣列；失敗回空陣列並設定 error
   */
  async function getAvailableSlots(params: {
    staffId: string
    serviceId: string
    /** 'YYYY-MM-DD' */
    date: string
    slotMinutes?: number
  }): Promise<string[]> {
    loading.value = true
    error.value = null
    try {
      const { data, error: rpcError } = await supabase.rpc('get_available_slots', {
        p_staff_id: params.staffId,
        p_service_id: params.serviceId,
        p_date: params.date,
        p_slot_minutes: params.slotMinutes ?? 15,
      })
      if (rpcError) throw rpcError
      // RPC 回傳 setof timestamptz → string[]
      return (data ?? []) as string[]
    } catch (e) {
      error.value = parseRpcError(e).message
      return []
    } finally {
      loading.value = false
    }
  }

  /**
   * 建立預約。
   * - 有帶 staffId → 走 create_booking
   * - 沒帶 staffId → 走 create_booking_any(系統指派)
   * 搶位失敗(slot_taken)會自動重試指定次數，因為高峰時多人搶同格很常見。
   */
  async function createBooking(
    input: BookingInput,
    options: { retries?: number } = {},
  ): Promise<CreateBookingResult | null> {
    const maxRetries = options.retries ?? 2
    loading.value = true
    error.value = null

    try {
      let attempt = 0
      // eslint-disable-next-line no-constant-condition
      while (true) {
        const { result, err } = input.staffId
          ? await callCreateBooking(input)
          : await callCreateBookingAny(input)

        if (!err) return result

        const { code, message } = parseRpcError(err)
        // 只有「剛好被搶」值得重試；其餘錯誤直接回報
        if (code === 'slot_taken' && attempt < maxRetries) {
          attempt++
          // 小幅退避，降低再次正面對撞的機率
          await new Promise((r) => setTimeout(r, 120 * attempt))
          continue
        }
        error.value = message
        return null
      }
    } finally {
      loading.value = false
    }
  }

  // ---------- 內部：實際 RPC 呼叫 ----------
  async function callCreateBooking(input: BookingInput) {
    const { data, error: err } = await supabase.rpc('create_booking', {
      p_tenant_id: input.tenantId,
      p_staff_id: input.staffId,
      p_service_id: input.serviceId,
      p_start_at: input.startAt,
      p_customer_name: input.customerName,
      p_customer_phone: input.customerPhone,
      p_customer_email: input.customerEmail ?? null,
      p_note: input.note ?? null,
    })
    return {
      err,
      result: err ? null : ({ bookingId: data as string, staffId: input.staffId! } as CreateBookingResult),
    }
  }

  async function callCreateBookingAny(input: BookingInput) {
    // create_booking_any 回傳 (booking_id, staff_id) → 單列物件
    const { data, error: err } = await supabase.rpc('create_booking_any', {
      p_tenant_id: input.tenantId,
      p_service_id: input.serviceId,
      p_start_at: input.startAt,
      p_customer_name: input.customerName,
      p_customer_phone: input.customerPhone,
      p_customer_email: input.customerEmail ?? null,
      p_note: input.note ?? null,
    })
    const row = Array.isArray(data) ? data[0] : data
    return {
      err,
      result:
        err || !row
          ? null
          : ({ bookingId: row.booking_id as string, staffId: row.staff_id as string } as CreateBookingResult),
    }
  }

  return {
    loading,
    error,
    getAvailableSlots,
    createBooking,
  }
}
