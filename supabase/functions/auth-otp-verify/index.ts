import { serve } from 'https://deno.land/std@0.224.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.6'

serve(async (req) => {
  try {
    const { phone, token } = await req.json()

    if (!phone || !token) {
      return new Response(
        JSON.stringify({
          success: false,
          error: 'Phone number and OTP token are required',
        }),
        {
          status: 400,
          headers: {
            'Content-Type': 'application/json',
          },
        },
      )
    }

    const normalizedPhone = phone.trim()

    // Client used to verify the OTP
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
    )

    const { data, error } = await supabase.auth.verifyOtp({
      phone: normalizedPhone,
      token,
      type: 'sms',
    })

    if (error) {
      return new Response(
        JSON.stringify({
          success: false,
          error: error.message,
        }),
        {
          status: 401,
          headers: {
            'Content-Type': 'application/json',
          },
        },
      )
    }

    if (!data.user || !data.session) {
      return new Response(
        JSON.stringify({
          success: false,
          error: 'OTP verification failed',
        }),
        {
          status: 401,
          headers: {
            'Content-Type': 'application/json',
          },
        },
      )
    }

    // Authenticated client used to check the user's profile
    const authenticatedSupabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      {
        global: {
          headers: {
            Authorization: `Bearer ${data.session.access_token}`,
          },
        },
      },
    )

    // Check existing profile using verified phone number
    const verifiedPhone = data.user.phone ?? normalizedPhone

    const phoneWithPlus = verifiedPhone.startsWith('+')
  ? verifiedPhone
  : `+${verifiedPhone}`

    const { data: profile, error: profileError } =
  await authenticatedSupabase
    .from('Profiles')
    .select('id')
    .eq('phone', phoneWithPlus)
    .maybeSingle()

    if (profileError) {
      return new Response(
        JSON.stringify({
          success: false,
          error: profileError.message,
        }),
        {
          status: 500,
          headers: {
            'Content-Type': 'application/json',
          },
        },
      )
    }

    const profileExists = profile !== null

    console.log({
  verifiedPhone,
  profile,
  profileExists,
})

    return new Response(
      JSON.stringify({
        success: true,

        session: {
          access_token: data.session.access_token,
          refresh_token: data.session.refresh_token,
          expires_in: data.session.expires_in,
          expires_at: data.session.expires_at,
        },

        user: {
          id: data.user.id,
          phone: verifiedPhone,
          profile_exists: profileExists,
          profile_id: profile?.id ?? null,
        },

        next_step: profileExists
          ? 'sign_in'
          : 'complete_registration',
      }),
      {
        status: 200,
        headers: {
          'Content-Type': 'application/json',
        },
      },
    )
  } catch (error) {
    return new Response(
      JSON.stringify({
        success: false,
        error:
          error instanceof Error
            ? error.message
            : 'Internal server error',
      }),
      {
        status: 500,
        headers: {
          'Content-Type': 'application/json',
        },
      },
    )
  }
})