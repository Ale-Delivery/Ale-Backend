import { serve } from 'https://deno.land/std@0.224.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.6'

interface SignupPayload {
  email: string
  password: string
  full_name: string
  phone?: string
}

serve(async (req) => {
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  )

  try {
    const { email, password, full_name, phone }: SignupPayload = await req.json()

    if (!email || !password || !full_name) {
      return new Response(
        JSON.stringify({ error: 'email, password, and full_name are required' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    if (password.length < 6) {
      return new Response(
        JSON.stringify({ error: 'Password must be at least 6 characters' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const { data: authUser, error: signUpError } = await supabase.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        full_name,
        phone,
      },
    })

    if (signUpError) {
      return new Response(
        JSON.stringify({ error: signUpError.message }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    if (!authUser?.user) {
      return new Response(
        JSON.stringify({ error: 'User creation failed' }),
        { status: 500, headers: { 'Content-Type': 'application/json' } }
      )
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Account created successfully',
        user: {
          id: authUser.user.id,
          email: authUser.user.email,
        },
      }),
      {
        status: 200,
        headers: {
          'Content-Type': 'application/json',
        },
      }
    )
  } catch (err) {
    return new Response(
      JSON.stringify({
        error: err instanceof Error ? err.message : 'Internal error',
      }),
      {
        status: 500,
        headers: {
          'Content-Type': 'application/json',
        },
      }
    )
  }
})