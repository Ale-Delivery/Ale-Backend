import '@supabase/functions-js/edge-runtime.d.ts'

type SendSmsHookPayload = {
  user?: {
    phone?: string
  }
  sms?: {
    otp?: string
  }
}

Deno.serve(async (req: Request) => {
  try {
    if (req.method !== 'POST') {
      return Response.json(
        { error: 'Method not allowed' },
        { status: 405 },
      )
    }

    const apiToken = Deno.env.get('TEXTLK_API_TOKEN')
    const senderId = Deno.env.get('TEXTLK_SENDER_ID')

    if (!apiToken || !senderId) {
      console.error('Text.lk secrets are missing')

      return Response.json(
        { error: 'SMS service is not configured' },
        { status: 500 },
      )
    }

    const payload =
      (await req.json()) as SendSmsHookPayload

    const phone = payload.user?.phone
    const otp = payload.sms?.otp

    if (!phone || !otp) {
      console.error('Invalid hook payload', payload)

      return Response.json(
        { error: 'Phone number and OTP are required' },
        { status: 400 },
      )
    }

    // Text.lk expects the number without the leading +
    // Example: +94701234567 -> 94701234567
    const recipient = phone.replace(/^\+/, '')

    const textLkResponse = await fetch(
      'https://app.text.lk/api/v3/sms/send',
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${apiToken}`,
          'Content-Type': 'application/json',
          Accept: 'application/json',
        },
        body: JSON.stringify({
          recipient,
          sender_id: senderId,
          type: 'plain',
          message:
            `Your Ale verification code is ${otp}. ` +
            'This code will expire shortly. Do not share it.',
        }),
      },
    )

    const responseText = await textLkResponse.text()

    let responseBody: unknown

    try {
      responseBody = JSON.parse(responseText)
    } catch {
      responseBody = responseText
    }

    if (!textLkResponse.ok) {
      console.error('Text.lk request failed', {
        status: textLkResponse.status,
        response: responseBody,
      })

      return Response.json(
        { error: 'Failed to send OTP message' },
        { status: 502 },
      )
    }

    const textLkResult = responseBody as {
      status?: string
      message?: string
    }

    if (textLkResult.status === 'error') {
      console.error('Text.lk returned an error', textLkResult)

      return Response.json(
        {
          error:
            textLkResult.message ??
            'SMS provider rejected the message',
        },
        { status: 502 },
      )
    }

    console.log('OTP SMS sent successfully', {
      recipient,
    })

    // Supabase considers an HTTP 200 response successful.
    return new Response('{}', {
  status: 200,
  headers: {
    'Content-Type': 'application/json',
  },
})
  } catch (error) {
    console.error('Send SMS hook error', error)

    return Response.json(
      {
        error:
          error instanceof Error
            ? error.message
            : 'Internal server error',
      },
      { status: 500 },
    )
  }
})